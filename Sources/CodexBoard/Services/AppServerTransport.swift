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

    weak var delegate: (any AppServerTransportDelegate)?

    private let executableURL: URL
    private let maximumLineBytes: Int
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
    private var didExit = false
    private var stdoutReachedEOF = false
    private var terminationStatus: Int32?

    init(executableURL: URL, maximumLineBytes: Int = 64 * 1_024 * 1_024) {
        self.executableURL = executableURL
        self.maximumLineBytes = maximumLineBytes
    }

    func start() throws {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        // CodexBoard owns the approval UI for this private app-server process.
        // Force the default connector policy to prompt so an App write cannot
        // silently inherit a permissive global default.
        process.arguments = Self.launchArguments
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
        terminationStatus = nil
        buffer.removeAll(keepingCapacity: true)
        scannedByteCount = 0
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
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        process.terminationHandler = { [weak self] process in
            self?.recordTermination(status: process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
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

    private func recordTermination(status: Int32) {
        stateLock.lock()
        terminationStatus = status
        let readyStatus = readyExitStatusLocked()
        stateLock.unlock()
        if let readyStatus { enqueueExit(status: readyStatus) }
    }

    private func readyExitStatusLocked() -> Int32? {
        guard !didExit, stdoutReachedEOF, let terminationStatus else { return nil }
        didExit = true
        return terminationStatus
    }

    private func enqueueExit(status: Int32) {
        delegateQueue.async { [weak self] in
            self?.delegate?.transportDidExit(status: status)
        }
    }

}
