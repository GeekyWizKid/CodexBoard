import Foundation
import XCTest
@testable import CodexBoard

final class AppServerTransportTests: XCTestCase {
    func testDeliversAllStdoutLinesBeforeExit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppServerTransportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("burst-jsonl")
        let lineCount = 2_000
        let script = """
        #!/bin/sh
        i=1
        while [ "$i" -le 2000 ]; do
          printf '{"id":%s,"result":{"ok":true}}\\n' "$i"
          i=$((i + 1))
        done
        exit 23
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )

        let exitExpectation = expectation(description: "transport exit")
        let delegate = RecordingTransportDelegate(exitExpectation: exitExpectation)
        let transport = AppServerTransport(executableURL: executable)
        transport.delegate = delegate
        try transport.start()

        await fulfillment(of: [exitExpectation], timeout: 5)
        transport.stop()

        let events = delegate.recordedEvents
        XCTAssertEqual(events.count, lineCount + 1)
        XCTAssertEqual(events.last, .exit(23))
        XCTAssertEqual(events.dropLast().filter { $0 == .line }.count, lineCount)
    }
}

private final class RecordingTransportDelegate: AppServerTransportDelegate, @unchecked Sendable {
    enum Event: Equatable {
        case line
        case exit(Int32)
    }

    private let lock = NSLock()
    private var events: [Event] = []
    private let exitExpectation: XCTestExpectation

    init(exitExpectation: XCTestExpectation) {
        self.exitExpectation = exitExpectation
    }

    var recordedEvents: [Event] {
        lock.withLock { events }
    }

    func transportDidReceive(_ data: Data) {
        lock.withLock { events.append(.line) }
    }

    func transportDidExit(status: Int32) {
        lock.withLock { events.append(.exit(status)) }
        exitExpectation.fulfill()
    }
}
