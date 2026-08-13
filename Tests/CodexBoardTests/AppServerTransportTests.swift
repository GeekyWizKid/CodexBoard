import Foundation
import XCTest
@testable import CodexBoard

final class AppServerTransportTests: XCTestCase {
    func testPrivateAppServerDefaultsConnectorToolsToUserApproval() {
        XCTAssertEqual(AppServerTransport.launchArguments, [
            "app-server",
            "-c", "apps._default.default_tools_approval_mode=\"prompt\"",
            "-c", "apps._default.approvals_reviewer=\"user\"",
            "--stdio"
        ])
    }

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

    func testDeliversChunkedTwentyThreeMegabyteLineAndDoesNotStarveNextResponse() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppServerTransportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("chunked-large-jsonl")
        let chunkByteCount = 32 * 1_024
        let chunkCount = 23 * 32
        let payloadByteCount = chunkByteCount * chunkCount
        let largePrefix = "{\"id\":1,\"result\":{\"payload\":\""
        let largeSuffix = "\"}}"
        let smallResponse = "{\"id\":2,\"result\":{\"ok\":true}}"
        let script = """
        #!/bin/sh
        chunk=$(/usr/bin/awk 'BEGIN { for (i = 0; i < \(chunkByteCount); i++) printf "x" }')
        printf '%s' '\(largePrefix)'
        i=0
        while [ "$i" -lt \(chunkCount) ]; do
          printf '%s' "$chunk"
          i=$((i + 1))
        done
        printf '%s\\n' '\(largeSuffix)'
        printf '%s\\n' '\(smallResponse)'
        exit 0
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )

        let exitExpectation = expectation(description: "transport exit after large JSONL response")
        let delegate = RecordingTransportDelegate(exitExpectation: exitExpectation)
        let transport = AppServerTransport(executableURL: executable)
        transport.delegate = delegate
        try transport.start()

        await fulfillment(of: [exitExpectation], timeout: 15)
        transport.stop()

        let lines = delegate.recordedLines
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.first?.count, largePrefix.utf8.count + payloadByteCount + largeSuffix.utf8.count)
        XCTAssertTrue(lines.first?.starts(with: Data(largePrefix.utf8)) == true)
        XCTAssertEqual(lines.first.map { Data($0.suffix(largeSuffix.utf8.count)) }, Data(largeSuffix.utf8))
        XCTAssertEqual(lines.last, Data(smallResponse.utf8))
        XCTAssertEqual(delegate.recordedEvents.last, .exit(0))
    }

    func testOversizedLineFailsFastWithoutDispatchingPartialPayload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppServerTransportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("oversized-jsonl")
        let chunkByteCount = 32 * 1_024
        let script = """
        #!/bin/sh
        chunk=$(/usr/bin/awk 'BEGIN { for (i = 0; i < \(chunkByteCount); i++) printf "x" }')
        printf '%s' '{"id":99,"result":{"payload":"'
        printf '%s' "$chunk"
        printf '%s' "$chunk"
        printf '%s' "$chunk"
        /bin/sleep 10
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )

        let exitExpectation = expectation(description: "oversized line rejection")
        let delegate = RecordingTransportDelegate(exitExpectation: exitExpectation)
        let transport = AppServerTransport(
            executableURL: executable,
            maximumLineBytes: 64 * 1_024
        )
        transport.delegate = delegate
        try transport.start()

        await fulfillment(of: [exitExpectation], timeout: 2)
        transport.stop()

        XCTAssertTrue(delegate.recordedLines.isEmpty)
        XCTAssertEqual(delegate.recordedEvents, [.exit(-1)])
    }
}

private final class RecordingTransportDelegate: AppServerTransportDelegate, @unchecked Sendable {
    enum Event: Equatable {
        case line
        case exit(Int32)
    }

    private let lock = NSLock()
    private var events: [Event] = []
    private var lines: [Data] = []
    private let exitExpectation: XCTestExpectation

    init(exitExpectation: XCTestExpectation) {
        self.exitExpectation = exitExpectation
    }

    var recordedEvents: [Event] {
        lock.withLock { events }
    }

    var recordedLines: [Data] {
        lock.withLock { lines }
    }

    func transportDidReceive(_ data: Data) {
        lock.withLock {
            lines.append(data)
            events.append(.line)
        }
    }

    func transportDidExit(status: Int32) {
        lock.withLock { events.append(.exit(status)) }
        exitExpectation.fulfill()
    }
}
