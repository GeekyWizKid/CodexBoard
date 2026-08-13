import XCTest
@testable import CodexBoard

@MainActor
final class BoardStoreWorkflowTests: XCTestCase {
    func testManualPlanCompletionWaitsForConfirmation() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try XCTUnwrap(fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Manual",
            sourceKind: .issue,
            sourceText: "Do the thing",
            autoRun: false
        ))

        try await eventually { fixture.client.planningTurnCount == 1 }
        fixture.client.send(.planFinal(threadID: "thread-1", turnID: "plan-1", text: "1. Inspect\n2. Fix"))
        fixture.client.send(.turnCompleted(threadID: "thread-1", turnID: "plan-1", status: "completed", error: nil))
        try await eventually { fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .awaitingApproval }

        XCTAssertEqual(fixture.client.executionTurnCount, 0)
        fixture.store.confirmPlan(taskID: taskID)
        try await eventually { fixture.client.executionTurnCount == 1 }
        XCTAssertEqual(fixture.store.tasks.first(where: { $0.id == taskID })?.stage, .executing)
    }

    func testAutoRunSkipsConfirmationButKeepsPlanning() async throws {
        let fixture = try Fixture(autoRunDefault: true)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try XCTUnwrap(fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Auto",
            sourceKind: .developmentPlan,
            sourceText: "Ship milestone",
            autoRun: true
        ))

        try await eventually { fixture.client.planningTurnCount == 1 }
        fixture.client.send(.planFinal(threadID: "thread-1", turnID: "plan-1", text: "Approved plan"))
        fixture.client.send(.turnCompleted(threadID: "thread-1", turnID: "plan-1", status: "completed", error: nil))

        try await eventually { fixture.client.executionTurnCount == 1 }
        XCTAssertEqual(fixture.store.tasks.first(where: { $0.id == taskID })?.stage, .executing)
    }

    func testInterruptedPersistedTaskBecomesNeedsAttention() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = BoardPersistence(fileURL: directory.appendingPathComponent("board.json"))
        let task = BoardTask(
            projectID: directory.path,
            title: "Was running",
            sourceKind: .issue,
            sourceText: "Continue safely",
            stage: .executing,
            autoRun: false,
            executionApproved: true,
            planText: "Plan",
            threadID: "thread-old",
            sessionID: "session-old",
            executionTurnID: "turn-old"
        )
        try await persistence.save(BoardSnapshot(
            version: 1,
            tasks: [task],
            manualProjectPaths: [directory.path],
            preferences: BoardPreferences()
        ))
        let client = MockCodexTaskClient(projectPath: directory.path)
        let store = BoardStore(client: client, persistence: persistence)
        store.start()
        try await eventually { store.tasks.first?.stage == .needsAttention }
        XCTAssertTrue(store.tasks.first?.lastError?.contains("避免重复副作用") == false)
        XCTAssertEqual(client.executionTurnCount, 0)
    }

    func testExecutionQueueSerializesWritesToTheSameProject() async throws {
        let fixture = try Fixture(autoRunDefault: true)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let firstID = try XCTUnwrap(fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "First",
            sourceKind: .issue,
            sourceText: "First change",
            autoRun: true
        ))
        let secondID = try XCTUnwrap(fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Second",
            sourceKind: .issue,
            sourceText: "Second change",
            autoRun: true
        ))
        try await eventually { fixture.client.planningTurnCount == 2 }

        fixture.client.send(.planFinal(threadID: "thread-1", turnID: "plan-1", text: "First plan"))
        fixture.client.send(.turnCompleted(threadID: "thread-1", turnID: "plan-1", status: "completed", error: nil))
        fixture.client.send(.planFinal(threadID: "thread-2", turnID: "plan-2", text: "Second plan"))
        fixture.client.send(.turnCompleted(threadID: "thread-2", turnID: "plan-2", status: "completed", error: nil))

        try await eventually { fixture.client.executionTurnCount == 1 }
        XCTAssertEqual(fixture.store.tasks.first(where: { $0.id == firstID })?.stage, .executing)
        XCTAssertEqual(fixture.store.tasks.first(where: { $0.id == secondID })?.stage, .awaitingApproval)

        fixture.client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "execute-1",
            status: "completed",
            error: nil
        ))
        try await eventually { fixture.client.executionTurnCount == 2 }
        XCTAssertEqual(fixture.store.tasks.first(where: { $0.id == secondID })?.stage, .executing)
    }

    func testChangingProjectClearsTaskSelectionFromPreviousProject() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try XCTUnwrap(fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Selected",
            sourceKind: .issue,
            sourceText: "Inspect selection",
            autoRun: false
        ))
        fixture.store.selectedTaskID = taskID

        let secondProject = fixture.directory.appendingPathComponent("SecondProject", isDirectory: true)
        try FileManager.default.createDirectory(at: secondProject, withIntermediateDirectories: true)
        fixture.store.addManualProject(path: secondProject.path)
        try await eventually { fixture.store.projects.contains(where: { $0.id == secondProject.path }) }

        fixture.store.selectedProjectID = secondProject.path
        XCTAssertNil(fixture.store.selectedTaskID)
    }

    func testPartialPlanCannotBypassFinalPlanGate() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try XCTUnwrap(fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Partial",
            sourceKind: .issue,
            sourceText: "Do not execute partial output",
            autoRun: false
        ))
        try await eventually { fixture.client.planningTurnCount == 1 }
        fixture.client.send(.agentDelta(threadID: "thread-1", turnID: "plan-1", delta: "Unfinished draft"))
        fixture.client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "plan-1",
            status: "failed",
            error: "Planning failed"
        ))
        try await eventually { fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .needsAttention }

        fixture.store.continueExecution(taskID: taskID)
        XCTAssertFalse(fixture.store.moveTask(taskID: taskID, to: .awaitingApproval))
        XCTAssertEqual(fixture.client.executionTurnCount, 0)
    }

    func testConnectionLossReleasesActiveTasksToNeedsAttention() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try XCTUnwrap(fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Disconnect",
            sourceKind: .issue,
            sourceText: "Handle transport failure",
            autoRun: false
        ))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .planning
        }

        fixture.client.send(.connectionLost(message: "app-server exited"))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .needsAttention
        }
        XCTAssertTrue(
            fixture.store.tasks.first(where: { $0.id == taskID })?.lastError?.contains("连接已断开") == true
        )
    }

    func testRunningTasksPrioritizeExecutionAndCanBeFocused() async throws {
        let fixture = try Fixture(autoRunDefault: true)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }

        let executingID = try XCTUnwrap(fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Executing task",
            sourceKind: .issue,
            sourceText: "Execute this task",
            autoRun: true
        ))
        try await eventually { fixture.client.planningTurnCount == 1 }
        fixture.client.send(.planFinal(
            threadID: "thread-1",
            turnID: "plan-1",
            text: "Execution plan"
        ))
        fixture.client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "plan-1",
            status: "completed",
            error: nil
        ))
        try await eventually { fixture.client.executionTurnCount == 1 }

        let planningID = try XCTUnwrap(fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Planning task",
            sourceKind: .developmentPlan,
            sourceText: "Plan this task",
            autoRun: false
        ))
        try await eventually { fixture.client.planningTurnCount == 2 }

        XCTAssertEqual(fixture.store.runningTaskCount, 2)
        XCTAssertEqual(fixture.store.runningTasks.map(\.id), [executingID, planningID])
        XCTAssertEqual(fixture.store.projectName(for: fixture.store.runningTasks[0]), fixture.directory.lastPathComponent)

        fixture.store.focusTask(executingID)
        XCTAssertEqual(fixture.store.selectedProjectID, fixture.projectPath)
        XCTAssertEqual(fixture.store.selectedTaskID, executingID)
    }

    private func eventually(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Condition was not met before timeout")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@MainActor
private final class MockCodexTaskClient: CodexTaskClient {
    var connectionState: CodexConnectionState = .connected
    private let continuation: AsyncStream<CodexEvent>.Continuation
    let events: AsyncStream<CodexEvent>
    let projectPath: String
    var planningTurnCount = 0
    var executionTurnCount = 0
    var threadStartCount = 0

    init(projectPath: String) {
        self.projectPath = projectPath
        var captured: AsyncStream<CodexEvent>.Continuation!
        events = AsyncStream { captured = $0 }
        continuation = captured
    }

    func send(_ event: CodexEvent) { continuation.yield(event) }
    func connect() async throws {}
    func verifyAccount() async throws -> Bool { true }
    func listThreads(cursor: String?, archived: Bool) async throws -> CodexThreadPage {
        CodexThreadPage(
            threads: [CodexThreadSummary(
                id: "history",
                sessionID: "history-session",
                cwd: projectPath,
                name: "Fixture",
                createdAt: Date(),
                updatedAt: Date(),
                isPinned: false,
                statusType: "idle",
                sourceKind: "appServer"
            )],
            nextCursor: nil
        )
    }
    func startThread(cwd: String, model: String?) async throws -> CodexStartedThread {
        threadStartCount += 1
        return CodexStartedThread(
            threadID: "thread-\(threadStartCount)",
            sessionID: "session-\(threadStartCount)",
            model: model ?? "test-model",
            cwd: cwd
        )
    }
    func resumeThread(threadID: String, cwd: String) async throws -> CodexStartedThread {
        CodexStartedThread(threadID: threadID, sessionID: "session-1", model: "test-model", cwd: cwd)
    }
    func setThreadName(threadID: String, name: String) async throws {}
    func startPlanningTurn(threadID: String, cwd: String, prompt: String, model: String, effort: ReasoningEffort) async throws -> CodexStartedTurn {
        planningTurnCount += 1
        return CodexStartedTurn(turnID: "plan-\(planningTurnCount)", status: "inProgress")
    }
    func startExecutionTurn(threadID: String, cwd: String, prompt: String, model: String, effort: ReasoningEffort, allowNetwork: Bool) async throws -> CodexStartedTurn {
        executionTurnCount += 1
        return CodexStartedTurn(turnID: "execute-\(executionTurnCount)", status: "inProgress")
    }
    func interrupt(threadID: String, turnID: String) async throws {}
}

@MainActor
private struct Fixture {
    let directory: URL
    let projectPath: String
    let client: MockCodexTaskClient
    let store: BoardStore

    init(autoRunDefault: Bool) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        projectPath = directory.path
        client = MockCodexTaskClient(projectPath: projectPath)
        let persistence = BoardPersistence(fileURL: directory.appendingPathComponent("board.json"))
        store = BoardStore(client: client, persistence: persistence)
        store.start()
        store.updatePreferences { $0.defaultAutoRun = autoRunDefault }
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
