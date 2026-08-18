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

    func testInjectableArgumentsArePassedWithoutShellInterpretation() async throws {
        let fixture = try TemporaryExecutable(script: """
        #!/bin/sh
        printf '%s\\n' "$#"
        printf '%s\\n' "$1"
        printf '%s\\n' "$2"
        """)
        defer { fixture.remove() }

        let exitExpectation = expectation(description: "transport exit")
        let delegate = DataRecordingTransportDelegate(exitExpectation: exitExpectation)
        let transport = AppServerTransport(
            executableURL: fixture.url,
            arguments: ["value with spaces", "literal;$HOME"]
        )
        transport.delegate = delegate
        try transport.start()

        await fulfillment(of: [exitExpectation], timeout: 5)
        transport.stop()

        XCTAssertEqual(delegate.lines.map { String(decoding: $0, as: UTF8.self) }, [
            "2",
            "value with spaces",
            "literal;$HOME"
        ])
        XCTAssertEqual(delegate.exitStatus, 0)
    }

    func testDefaultInitializerKeepsLocalCodexArguments() async throws {
        let fixture = try TemporaryExecutable(script: """
        #!/bin/sh
        printf '%s\\n' "$1"
        printf '%s\\n' "$2"
        """)
        defer { fixture.remove() }

        let exitExpectation = expectation(description: "transport exit")
        let delegate = DataRecordingTransportDelegate(exitExpectation: exitExpectation)
        let transport = AppServerTransport(executableURL: fixture.url)
        transport.delegate = delegate
        try transport.start()

        await fulfillment(of: [exitExpectation], timeout: 5)
        transport.stop()

        XCTAssertEqual(delegate.lines.map { String(decoding: $0, as: UTF8.self) }, [
            "app-server",
            "--stdio"
        ])
    }

    func testSSHArgumentsAreFixedAndAliasIsASeparateArgument() throws {
        XCTAssertEqual(try AppServerTransport.sshArguments(for: "build_01.example"), [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ClearAllForwardings=yes",
            "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "--",
            "build_01.example",
            "exec codex app-server --stdio"
        ])
    }

    func testRejectsUnsafeSSHHostAliases() {
        for alias in ["", "-oProxyCommand=bad", "user@host", "host name", "host;command", "主机"] {
            XCTAssertThrowsError(try AppServerTransport.sshArguments(for: alias)) { error in
                XCTAssertEqual(error as? CodexClientError, .invalidSSHHostAlias)
            }
        }
    }

    func testCapturesOnlyBoundedTailOfStderrBeforeExit() async throws {
        let fixture = try TemporaryExecutable(script: """
        #!/bin/sh
        printf '0123456789abcdefgh' >&2
        exit 7
        """)
        defer { fixture.remove() }

        let exitExpectation = expectation(description: "transport exit")
        let delegate = DataRecordingTransportDelegate(exitExpectation: exitExpectation)
        let transport = AppServerTransport(
            executableURL: fixture.url,
            arguments: [],
            maximumStderrBytes: 8
        )
        transport.delegate = delegate
        try transport.start()

        await fulfillment(of: [exitExpectation], timeout: 5)
        XCTAssertEqual(delegate.exitStatus, 7)
        XCTAssertEqual(transport.stderrDiagnostics, "…\nabcdefgh")
        XCTAssertEqual(
            CodexClientError.processExited(7, stderr: transport.stderrDiagnostics).localizedDescription,
            "Codex app-server 已退出（状态 7）：…\nabcdefgh"
        )
        transport.stop()
    }

    func testRejectsOversizedCompleteStdoutLineBeforeDelivery() async throws {
        let fixture = try TemporaryExecutable(script: """
        #!/bin/sh
        printf '0123456789abcdef\n'
        /bin/sleep 1
        """)
        defer { fixture.remove() }

        let exitExpectation = expectation(description: "transport rejects oversized line")
        let delegate = DataRecordingTransportDelegate(exitExpectation: exitExpectation)
        let transport = AppServerTransport(
            executableURL: fixture.url,
            arguments: [],
            maximumLineBytes: 8
        )
        transport.delegate = delegate
        try transport.start()

        await fulfillment(of: [exitExpectation], timeout: 5)
        XCTAssertEqual(delegate.lines, [])
        XCTAssertEqual(delegate.exitStatus, -1)
        transport.stop()
    }

    func testRejectsOversizedFragmentedStdoutLineBeforeDelivery() async throws {
        let fixture = try TemporaryExecutable(script: """
        #!/bin/sh
        printf '0123'
        /bin/sleep 0.2
        printf '456789'
        /bin/sleep 1
        """)
        defer { fixture.remove() }

        let exitExpectation = expectation(description: "transport rejects fragmented oversized line")
        let delegate = DataRecordingTransportDelegate(exitExpectation: exitExpectation)
        let transport = AppServerTransport(
            executableURL: fixture.url,
            arguments: [],
            maximumLineBytes: 8
        )
        transport.delegate = delegate
        try transport.start()

        await fulfillment(of: [exitExpectation], timeout: 5)
        XCTAssertEqual(delegate.lines, [])
        XCTAssertEqual(delegate.exitStatus, -1)
        transport.stop()
    }
}

private struct TemporaryExecutable {
    let directory: URL
    let url: URL

    init(script: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppServerTransportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("fixture")
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
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

private final class DataRecordingTransportDelegate: AppServerTransportDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var receivedLines: [Data] = []
    private var receivedExitStatus: Int32?
    private let exitExpectation: XCTestExpectation

    init(exitExpectation: XCTestExpectation) {
        self.exitExpectation = exitExpectation
    }

    var lines: [Data] {
        lock.withLock { receivedLines }
    }

    var exitStatus: Int32? {
        lock.withLock { receivedExitStatus }
    }

    func transportDidReceive(_ data: Data) {
        lock.withLock { receivedLines.append(data) }
    }

    func transportDidExit(status: Int32) {
        lock.withLock { receivedExitStatus = status }
        exitExpectation.fulfill()
    }
}
