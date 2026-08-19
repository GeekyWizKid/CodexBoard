import Darwin
import Foundation
import XCTest
@testable import CodexBoard

final class ManagedProcessSupervisorTests: XCTestCase {
    func testLaunchCreatesIndependentProcessGroupAndStdinEOFIsFirstClassShutdown() throws {
        let fixture = try SupervisorFixture(script: """
        #!/bin/sh
        trap '' TERM
        printf 'ready' > "$1"
        IFS= read -r ignored
        exit 19
        """)
        defer { fixture.remove() }

        let readyURL = fixture.directory.appendingPathComponent("ready")
        let recorder = SupervisorExitRecorder()
        let supervisor = ManagedProcessSupervisor(
            scope: .local,
            gracefulTerminationTimeout: 0.3,
            forcedTerminationTimeout: 0.3,
            exitHandler: recorder.record
        )
        _ = try supervisor.launch(
            executableURL: fixture.executableURL,
            arguments: [readyURL.path],
            environment: ProcessInfo.processInfo.environment
        )

        let pid = try XCTUnwrap(supervisor.processIdentifier)
        XCTAssertEqual(supervisor.processGroupIdentifier, pid)
        XCTAssertEqual(getpgid(pid), pid)
        XCTAssertNotEqual(pid, getpgrp())
        XCTAssertTrue(waitUntil { FileManager.default.fileExists(atPath: readyURL.path) })

        let result = supervisor.stop()
        guard case let .exited(event) = result else {
            return XCTFail("Expected a reaped exit, got \(result)")
        }
        XCTAssertEqual(event.reason, .exited)
        XCTAssertEqual(event.status, 19)
        XCTAssertEqual(event.certainty, .localProcessGroupDrained)
        XCTAssertTrue(event.stopWasRequested)
        XCTAssertFalse(event.escalatedToSIGKILL)

        XCTAssertEqual(supervisor.stop(), .exited(event))
        XCTAssertTrue(waitUntil { recorder.events == [event] })
    }

    func testStopEscalatesToKillAndDrainsIgnoringDescendantGroup() throws {
        let fixture = try SupervisorFixture(script: """
        #!/bin/sh
        trap '' TERM
        /bin/sh -c 'trap "" TERM; while :; do /bin/sleep 1; done' &
        child=$!
        printf '%s' "$child" > "$1"
        while :; do /bin/sleep 1; done
        """)
        defer { fixture.remove() }

        let childPIDURL = fixture.directory.appendingPathComponent("child-pid")
        let recorder = SupervisorExitRecorder()
        let supervisor = ManagedProcessSupervisor(
            scope: .local,
            gracefulTerminationTimeout: 0.15,
            forcedTerminationTimeout: 0.5,
            pollInterval: 0.005,
            exitHandler: recorder.record
        )
        _ = try supervisor.launch(
            executableURL: fixture.executableURL,
            arguments: [childPIDURL.path],
            environment: ProcessInfo.processInfo.environment
        )
        let processGroup = try XCTUnwrap(supervisor.processGroupIdentifier)
        XCTAssertTrue(waitUntil { FileManager.default.fileExists(atPath: childPIDURL.path) })
        let childPIDText = try String(contentsOf: childPIDURL, encoding: .utf8)
        let childPID = try XCTUnwrap(pid_t(childPIDText))
        XCTAssertEqual(getpgid(childPID), processGroup)

        let result = supervisor.stop()
        guard case let .exited(event) = result else {
            return XCTFail("Expected a reaped exit, got \(result)")
        }
        XCTAssertEqual(event.reason, .uncaughtSignal)
        XCTAssertEqual(event.status, SIGKILL)
        XCTAssertEqual(event.certainty, .localProcessGroupDrained)
        XCTAssertTrue(event.escalatedToSIGKILL)
        XCTAssertTrue(waitUntil(timeout: 1) {
            errno = 0
            return kill(-processGroup, 0) == -1 && errno == ESRCH
        })
        XCTAssertTrue(waitUntil { recorder.events == [event] })
    }

    func testSSHCertaintyDistinguishesCleanRemoteExitFromManagedDisconnect() throws {
        let cleanRecorder = SupervisorExitRecorder()
        let cleanSupervisor = ManagedProcessSupervisor(
            scope: .ssh,
            exitHandler: cleanRecorder.record
        )
        _ = try cleanSupervisor.launch(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 0"],
            environment: ProcessInfo.processInfo.environment
        )
        let cleanEvent = try XCTUnwrap(cleanSupervisor.waitForExit(timeout: 2))
        XCTAssertEqual(cleanEvent.certainty, .remoteExitConfirmed)
        XCTAssertFalse(cleanEvent.stopWasRequested)
        XCTAssertTrue(waitUntil { cleanRecorder.events == [cleanEvent] })

        let stoppedRecorder = SupervisorExitRecorder()
        let stoppedSupervisor = ManagedProcessSupervisor(
            scope: .ssh,
            gracefulTerminationTimeout: 0.2,
            forcedTerminationTimeout: 0.2,
            exitHandler: stoppedRecorder.record
        )
        _ = try stoppedSupervisor.launch(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"],
            environment: ProcessInfo.processInfo.environment
        )
        let stoppedResult = stoppedSupervisor.stop()
        guard case let .exited(stoppedEvent) = stoppedResult else {
            return XCTFail("Expected a reaped SSH exit, got \(stoppedResult)")
        }
        XCTAssertEqual(stoppedEvent.certainty, .remoteUnknown)
        XCTAssertTrue(stoppedEvent.stopWasRequested)
        XCTAssertTrue(waitUntil { stoppedRecorder.events == [stoppedEvent] })
    }
}

private final class SupervisorExitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [ManagedProcessSupervisor.ExitEvent] = []

    var events: [ManagedProcessSupervisor.ExitEvent] {
        lock.withLock { recordedEvents }
    }

    func record(_ event: ManagedProcessSupervisor.ExitEvent) {
        lock.withLock { recordedEvents.append(event) }
    }
}

private struct SupervisorFixture {
    let directory: URL
    let executableURL: URL

    init(script: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedProcessSupervisorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executableURL = directory.appendingPathComponent("fixture")
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func waitUntil(
    timeout: TimeInterval = 2,
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
