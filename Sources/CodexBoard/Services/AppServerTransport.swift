import Foundation

protocol AppServerTransportDelegate: AnyObject, Sendable {
    func transportDidReceive(_ data: Data)
    func transportDidExit(status: Int32)
}

final class AppServerTransport: @unchecked Sendable {
    static let launchArguments = [
        "app-server",
        "-c", "apps._default.default_tools_approval_mode=\"prompt\"",
        "-c", "apps._default.approvals_reviewer=\"user\"",
        "--stdio"
    ]
    static let remoteAppServerCommand = "exec codex app-server --stdio"
    private static let excludedInheritedEnvironmentKeys: Set<String> = ["OPENAI_API_KEY"]

    weak var delegate: (any AppServerTransportDelegate)?

    private let executableURL: URL
    private let arguments: [String]
    private var environmentOverrides: [String: String]
    private let maximumLineBytes: Int
    private let maximumStderrBytes: Int
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    // A single FIFO queue preserves JSONL ordering. It targets the main queue so
    // the @MainActor client can consume callbacks without spawning reorderable
    // unstructured Tasks.
    private let delegateQueue = DispatchQueue(
        label: "com.local.CodexBoard.app-server.events",
        target: .main
    )
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var buffer = Data()
    // Number of bytes in `buffer` that were already checked for a newline.
    // Keeping this cursor is important for large JSONL messages: rescanning an
    // incomplete line from byte zero for every pipe chunk becomes O(n²).
    private var scannedByteCount = 0
    private var stderrBuffer = Data()
    private var stderrWasTruncated = false
    private var didExit = false
    private var stdoutReachedEOF = false
    private var stderrReachedEOF = false
    private var terminationStatus: Int32?

    init(
        executableURL: URL,
        maximumLineBytes: Int = 64 * 1_024 * 1_024,
        maximumStderrBytes: Int = 32 * 1_024
    ) {
        self.executableURL = executableURL
        arguments = Self.launchArguments
        environmentOverrides = [:]
        self.maximumLineBytes = max(1, maximumLineBytes)
        self.maximumStderrBytes = max(0, maximumStderrBytes)
    }

    init(
        executableURL: URL,
        arguments: [String],
        environmentOverrides: [String: String] = [:],
        maximumLineBytes: Int = 64 * 1_024 * 1_024,
        maximumStderrBytes: Int = 32 * 1_024
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environmentOverrides = environmentOverrides
        self.maximumLineBytes = max(1, maximumLineBytes)
        self.maximumStderrBytes = max(0, maximumStderrBytes)
    }

    convenience init(
        sshHostAlias: String,
        maximumLineBytes: Int = 64 * 1_024 * 1_024,
        maximumStderrBytes: Int = 32 * 1_024
    ) throws {
        self.init(
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: try Self.sshArguments(for: sshHostAlias),
            maximumLineBytes: maximumLineBytes,
            maximumStderrBytes: maximumStderrBytes
        )
    }

    var stderrDiagnostics: String? {
        stateLock.withLock { stderrDiagnosticsLocked() }
    }

    static func validateSSHHostAlias(_ alias: String) throws {
        guard !alias.isEmpty,
              alias.utf8.count <= 253,
              let first = alias.utf8.first,
              isASCIIAlphaNumeric(first),
              alias.utf8.allSatisfy({ byte in
                  isASCIIAlphaNumeric(byte) || byte == 0x2D || byte == 0x2E || byte == 0x5F
              })
        else {
            throw CodexClientError.invalidSSHHostAlias
        }
    }

    static func sshArguments(for hostAlias: String) throws -> [String] {
        try validateSSHHostAlias(hostAlias)
        return [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ClearAllForwardings=yes",
            "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "--",
            hostAlias,
            remoteAppServerCommand
        ]
    }

    static func childEnvironment(
        inheriting parent: [String: String],
        overrides: [String: String]
    ) -> [String: String] {
        var environment = parent
        for key in excludedInheritedEnvironmentKeys {
            environment.removeValue(forKey: key)
        }
        environment.merge(overrides, uniquingKeysWith: { _, override in override })
        return environment
    }

    func start() throws {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        // API credentials are opt-in for the dedicated Realtime launch only.
        // Ordinary local and SSH transports must never inherit a caller's key.
        process.environment = Self.childEnvironment(
            inheriting: ProcessInfo.processInfo.environment,
            overrides: environmentOverrides
        )
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        stateLock.lock()
        guard self.process == nil else {
            stateLock.unlock()
            return
        }
        self.process = process
        inputHandle = inputPipe.fileHandleForWriting
        outputHandle = outputPipe.fileHandleForReading
        errorHandle = errorPipe.fileHandleForReading
        didExit = false
        stdoutReachedEOF = false
        stderrReachedEOF = false
        terminationStatus = nil
        buffer.removeAll(keepingCapacity: true)
        scannedByteCount = 0
        stderrBuffer.removeAll(keepingCapacity: true)
        stderrWasTruncated = false
        stateLock.unlock()

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty {
                handle.readabilityHandler = nil
                self?.recordStdoutEOF()
            } else {
                self?.consume(bytes)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty {
                handle.readabilityHandler = nil
                self?.recordStderrEOF()
            } else {
                self?.consumeStderr(bytes)
            }
        }
        process.terminationHandler = { [weak self] process in
            self?.recordTermination(status: process.terminationStatus)
        }

        do {
            try process.run()
            // Foundation snapshots the child environment during launch and
            // rejects mutations afterwards. Drop our additional credential
            // copy while the running Process retains only its launch state.
            environmentOverrides.removeAll(keepingCapacity: false)
        } catch {
            environmentOverrides.removeAll(keepingCapacity: false)
            stop()
            throw CodexClientError.processLaunchFailed
        }
    }

    func send(_ data: Data) throws {
        var framed = data
        if framed.last != 0x0A { framed.append(0x0A) }
        writeLock.lock()
        defer { writeLock.unlock() }
        stateLock.lock()
        let handle = inputHandle
        let isRunning = process?.isRunning == true
        stateLock.unlock()
        guard isRunning, let handle else { throw CodexClientError.disconnected }
        do {
            try handle.write(contentsOf: framed)
        } catch {
            throw CodexClientError.transportWriteFailed
        }
    }

    func stop() {
        stateLock.lock()
        let process = process
        self.process = nil
        let input = inputHandle
        let output = outputHandle
        let error = errorHandle
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        output?.readabilityHandler = nil
        error?.readabilityHandler = nil
        stateLock.unlock()
        try? input?.close()
        try? output?.close()
        try? error?.close()
        if process?.isRunning == true { process?.terminate() }
    }

    private func consume(_ bytes: Data) {
        var lines: [Data] = []
        var exceededLimit = false
        var oversizedProcess: Process?
        stateLock.lock()
        guard !didExit else {
            stateLock.unlock()
            return
        }
        buffer.append(bytes)

        var lineStart = buffer.startIndex
        var searchStart = buffer.index(
            buffer.startIndex,
            offsetBy: min(scannedByteCount, buffer.count)
        )
        while searchStart < buffer.endIndex,
              let newline = buffer[searchStart...].firstIndex(of: 0x0A) {
            let lineByteCount = buffer.distance(from: lineStart, to: newline)
            guard lineByteCount <= maximumLineBytes else {
                exceededLimit = true
                break
            }
            var line = Data(buffer[lineStart..<newline])
            if line.last == 0x0D { line.removeLast() }
            if line.count > maximumLineBytes {
                buffer.removeAll()
                exceededLimit = true
                break
            }
            if !line.isEmpty { lines.append(line) }
            lineStart = buffer.index(after: newline)
            searchStart = lineStart
        }
        if !exceededLimit,
           buffer.distance(from: lineStart, to: buffer.endIndex) > maximumLineBytes {
            exceededLimit = true
        }
        if exceededLimit {
            buffer.removeAll()
            scannedByteCount = 0
            lines.removeAll()
            // Mark the transport failed while still holding the lock so a
            // second readability callback cannot consume bytes in between the
            // limit check and process termination.
            didExit = true
            oversizedProcess = process
            outputHandle?.readabilityHandler = nil
        } else {
            // Everything after the final complete line has now been scanned.
            // Remove completed lines once, rather than repeatedly deleting the
            // front of Data for every line in the chunk.
            scannedByteCount = buffer.distance(from: lineStart, to: buffer.endIndex)
            if lineStart != buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<lineStart)
            }
        }
        stateLock.unlock()
        for line in lines {
            delegateQueue.async { [weak self] in
                self?.delegate?.transportDidReceive(line)
            }
        }
        if exceededLimit {
            enqueueExit(status: -1)
            if oversizedProcess?.isRunning == true { oversizedProcess?.terminate() }
        }
    }

    private func recordStdoutEOF() {
        stateLock.lock()
        stdoutReachedEOF = true
        let status = readyExitStatusLocked()
        stateLock.unlock()
        if let status { enqueueExit(status: status) }
    }

    private func consumeStderr(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        stateLock.lock()
        if maximumStderrBytes == 0 {
            stderrWasTruncated = true
        } else if bytes.count >= maximumStderrBytes {
            stderrBuffer = Data(bytes.suffix(maximumStderrBytes))
            stderrWasTruncated = true
        } else {
            let overflow = stderrBuffer.count + bytes.count - maximumStderrBytes
            if overflow > 0 {
                stderrBuffer.removeFirst(overflow)
                stderrWasTruncated = true
            }
            stderrBuffer.append(bytes)
        }
        stateLock.unlock()
    }

    private func recordStderrEOF() {
        stateLock.lock()
        stderrReachedEOF = true
        let status = readyExitStatusLocked()
        stateLock.unlock()
        if let status { enqueueExit(status: status) }
    }

    private func recordTermination(status: Int32) {
        stateLock.lock()
        terminationStatus = status
        let readyStatus = readyExitStatusLocked()
        stateLock.unlock()
        if let readyStatus { enqueueExit(status: readyStatus) }
    }

    private func readyExitStatusLocked() -> Int32? {
        guard !didExit, stdoutReachedEOF, stderrReachedEOF, let terminationStatus else { return nil }
        didExit = true
        return terminationStatus
    }

    private func enqueueExit(status: Int32) {
        delegateQueue.async { [weak self] in
            self?.delegate?.transportDidExit(status: status)
        }
    }

    private func stderrDiagnosticsLocked() -> String? {
        var diagnostics = String(decoding: stderrBuffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stderrWasTruncated {
            diagnostics = diagnostics.isEmpty ? "[stderr 已截断]" : "…\n\(diagnostics)"
        }
        return diagnostics.isEmpty ? nil : diagnostics
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
            || (0x41...0x5A).contains(byte)
            || (0x61...0x7A).contains(byte)
    }
}
