import Darwin
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
        printf '%s\\n' "$#"
        for argument in "$@"; do
          printf '%s\\n' "$argument"
        done
        """)
        defer { fixture.remove() }

        let exitExpectation = expectation(description: "transport exit")
        let delegate = DataRecordingTransportDelegate(exitExpectation: exitExpectation)
        let transport = AppServerTransport(executableURL: fixture.url)
        transport.delegate = delegate
        try transport.start()

        await fulfillment(of: [exitExpectation], timeout: 5)
        transport.stop()

        XCTAssertEqual(
            delegate.lines.map { String(decoding: $0, as: UTF8.self) },
            [String(AppServerTransport.launchArguments.count)] + AppServerTransport.launchArguments
        )
    }

    func testOrdinaryLaunchDropsInheritedAPIKeyAndRealtimeOverrideIsExplicit() {
        let parent = [
            "PATH": "/usr/bin:/bin",
            "OPENAI_API_KEY": "parent-secret"
        ]

        XCTAssertEqual(
            AppServerTransport.childEnvironment(inheriting: parent, overrides: [:]),
            ["PATH": "/usr/bin:/bin"]
        )
        XCTAssertEqual(
            AppServerTransport.childEnvironment(
                inheriting: parent,
                overrides: ["OPENAI_API_KEY": "realtime-session-secret"]
            ),
            [
                "PATH": "/usr/bin:/bin",
                "OPENAI_API_KEY": "realtime-session-secret"
            ]
        )
    }

    func testEnvironmentOverridesAreScopedToChildProcess() async throws {
        let fixture = try TemporaryExecutable(script: """
        #!/bin/sh
        printf '%s\n' "$CODEX_HOME"
        """)
        defer { fixture.remove() }

        let isolatedHome = "/tmp/CodexBoard Live Home"
        let exitExpectation = expectation(description: "transport exit")
        let delegate = DataRecordingTransportDelegate(exitExpectation: exitExpectation)
        let transport = AppServerTransport(
            executableURL: fixture.url,
            arguments: [],
            environmentOverrides: ["CODEX_HOME": isolatedHome]
        )
        transport.delegate = delegate
        try transport.start()

        await fulfillment(of: [exitExpectation], timeout: 5)
        transport.stop()

        XCTAssertEqual(
            delegate.lines.map { String(decoding: $0, as: UTF8.self) },
            [isolatedHome]
        )
        XCTAssertNotEqual(ProcessInfo.processInfo.environment["CODEX_HOME"], isolatedHome)
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

    func testStopTerminatesIgnoringDescendantProcessGroup() throws {
        let fixture = try TemporaryExecutable(script: """
        #!/bin/sh
        trap '' TERM
        /bin/sh -c 'trap "" TERM; printf "%s" "$$" > "$1"; while :; do /bin/sleep 1; done' child "$1" &
        while :; do /bin/sleep 1; done
        """)
        defer { fixture.remove() }

        let childPIDURL = fixture.directory.appendingPathComponent("child-pid")
        let transport = AppServerTransport(
            executableURL: fixture.url,
            arguments: [childPIDURL.path]
        )
        try transport.start()
        XCTAssertTrue(waitForTransportCondition {
            FileManager.default.fileExists(atPath: childPIDURL.path)
        })

        let childPIDText = try String(contentsOf: childPIDURL, encoding: .utf8)
        let childPID = try XCTUnwrap(pid_t(childPIDText))
        let processGroup = getpgid(childPID)
        XCTAssertGreaterThan(processGroup, 1)
        XCTAssertNotEqual(processGroup, getpgrp())

        transport.stop()

        XCTAssertTrue(waitForTransportCondition {
            errno = 0
            return kill(-processGroup, 0) == -1 && errno == ESRCH
        })
        XCTAssertEqual(transport.lastTerminationCertainty, .localProcessGroupDrained)
    }

    func testSSHScopedManagedStopExposesRemoteUnknown() throws {
        let fixture = try TemporaryExecutable(script: """
        #!/bin/sh
        trap '' TERM
        printf 'ready' > "$1"
        IFS= read -r ignored
        exit 0
        """)
        defer { fixture.remove() }

        let readyURL = fixture.directory.appendingPathComponent("ready")
        let transport = AppServerTransport(
            executableURL: fixture.url,
            arguments: [readyURL.path],
            launchScope: .ssh
        )
        try transport.start()
        XCTAssertTrue(waitForTransportCondition {
            FileManager.default.fileExists(atPath: readyURL.path)
        })

        transport.stop()

        XCTAssertEqual(transport.lastTerminationCertainty, .remoteUnknown)
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

private func waitForTransportCondition(
    timeout: TimeInterval = 3,
    pollInterval: TimeInterval = 0.01,
    _ predicate: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: pollInterval)
    } while Date() < deadline
    return predicate()
}
