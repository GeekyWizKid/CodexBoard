import Foundation

protocol AppServerTransportDelegate: AnyObject, Sendable {
    func transportDidReceive(_ data: Data)
    func transportDidExit(status: Int32)
}

final class AppServerTransport: @unchecked Sendable {
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
    private var didExit = false
    private var stdoutReachedEOF = false
    private var terminationStatus: Int32?

    init(executableURL: URL, maximumLineBytes: Int = 8 * 1_024 * 1_024) {
        self.executableURL = executableURL
        self.maximumLineBytes = maximumLineBytes
    }

    func start() throws {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
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
        stateLock.lock()
        buffer.append(bytes)
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }
            if !line.isEmpty { lines.append(line) }
        }
        if buffer.count > maximumLineBytes {
            buffer.removeAll()
            exceededLimit = true
        }
        stateLock.unlock()
        for line in lines {
            delegateQueue.async { [weak self] in
                self?.delegate?.transportDidReceive(line)
            }
        }
        if exceededLimit { failForOversizedLine() }
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

    private func failForOversizedLine() {
        stateLock.lock()
        guard !didExit else {
            stateLock.unlock()
            return
        }
        didExit = true
        let process = process
        outputHandle?.readabilityHandler = nil
        stateLock.unlock()
        enqueueExit(status: -1)
        if process?.isRunning == true { process?.terminate() }
    }
}
