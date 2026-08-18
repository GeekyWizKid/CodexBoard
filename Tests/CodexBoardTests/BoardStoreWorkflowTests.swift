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

    func testTaskRPCFailureDoesNotMarkConnectedHostOffline() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        fixture.client.planningTurnError = CodexClientError.rpc(
            code: -32_602,
            message: "model unavailable"
        )

        let taskID = try XCTUnwrap(fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Task-level failure",
            sourceKind: .issue,
            sourceText: "Keep the host healthy",
            autoRun: false
        ))

        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .needsAttention
        }
        XCTAssertEqual(
            fixture.store.hostConnectionState(for: CodexHost.localID),
            .connected
        )
        XCTAssertEqual(fixture.client.connectionState, .connected)
    }

    func testFilesystemRootCannotBeUsedAsTaskWorkspace() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = BoardPersistence(fileURL: directory.appendingPathComponent("board.json"))
        try await persistence.save(BoardSnapshot(
            tasks: [],
            hosts: [.local],
            manualProjects: [ManualProjectReference(path: "/")],
            preferences: BoardPreferences()
        ))
        let client = MockCodexTaskClient(projectPath: "/")
        let store = BoardStore(client: client, persistence: persistence)
        store.start()

        try await eventually { store.projects.contains(where: { $0.path == "/" }) }
        let rootProject = try XCTUnwrap(store.projects.first(where: { $0.path == "/" }))
        XCTAssertFalse(store.isProjectRunnable(rootProject))
        XCTAssertNil(store.createTask(
            projectID: rootProject.id,
            title: "Unsafe root",
            sourceKind: .issue,
            sourceText: "Do not run here",
            autoRun: false
        ))
        XCTAssertEqual(client.threadStartCount, 0)
    }

    func testPersistenceFailurePreventsStartingRemoteWork() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dataURL = directory.appendingPathComponent("board.json")
        try Data("{corrupt".utf8).write(to: dataURL)
        let client = MockCodexTaskClient(projectPath: directory.path)
        let store = BoardStore(
            client: client,
            persistence: BoardPersistence(fileURL: dataURL)
        )
        store.start()

        try await eventually { store.projects.contains(where: { $0.path == directory.path }) }
        let project = try XCTUnwrap(store.projects.first(where: { $0.path == directory.path }))
        let taskID = try XCTUnwrap(store.createTask(
            projectID: project.id,
            title: "Do not start",
            sourceKind: .issue,
            sourceText: "Persistence is unavailable",
            autoRun: false
        ))

        try await eventually {
            store.tasks.first(where: { $0.id == taskID })?.stage == .needsAttention
        }
        XCTAssertEqual(client.threadStartCount, 0)
        XCTAssertEqual(client.planningTurnCount, 0)
        XCTAssertEqual(try Data(contentsOf: dataURL), Data("{corrupt".utf8))
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

    func testStartupReconcilesCompletedPersistedTurnWithoutDuplicateExecution() async throws {
        let fixture = try await persistedExecutionFixture(
            status: "completed",
            finalText: "Recovered after relaunch"
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        fixture.store.start()

        try await eventually {
            fixture.store.tasks.first(where: { $0.id == fixture.taskID })?.stage == .completed
        }
        XCTAssertEqual(fixture.client.readThreadCount, 1)
        XCTAssertEqual(fixture.client.resumeThreadCount, 0)
        XCTAssertEqual(fixture.client.executionTurnCount, 0)
        XCTAssertEqual(
            fixture.store.tasks.first(where: { $0.id == fixture.taskID })?.resultText,
            "Recovered after relaunch"
        )
    }

    func testStartupReattachesInProgressPersistedTurnWithoutDuplicateExecution() async throws {
        let fixture = try await persistedExecutionFixture(status: "inProgress")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        fixture.store.start()

        try await eventually { fixture.client.resumeThreadCount == 1 }
        let task = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == fixture.taskID }))
        XCTAssertEqual(fixture.client.readThreadCount, 1)
        XCTAssertEqual(fixture.client.executionTurnCount, 0)
        XCTAssertEqual(task.stage, .executing)
        XCTAssertEqual(task.executionTurnID, "turn-persisted")
        XCTAssertNil(task.lastError)
        XCTAssertTrue(task.liveMessage.contains("恢复"))
    }

    func testStartupFailsClosedForInterruptedPersistedTurn() async throws {
        let fixture = try await persistedExecutionFixture(status: "interrupted")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        fixture.store.start()

        try await eventually {
            fixture.store.tasks.first(where: { $0.id == fixture.taskID })?.stage == .needsAttention
        }
        let task = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == fixture.taskID }))
        XCTAssertEqual(fixture.client.readThreadCount, 1)
        XCTAssertEqual(fixture.client.resumeThreadCount, 0)
        XCTAssertEqual(fixture.client.executionTurnCount, 0)
        XCTAssertEqual(task.executionTurnID, "turn-persisted")
        XCTAssertTrue(task.lastError?.contains("interrupted") == true)
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

    func testSamePathOnTwoHostsRoutesTasksToIndependentClients() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remoteHost = CodexHost(
            id: "ssh:buildbox",
            name: "Build Box",
            kind: .ssh,
            sshAlias: "buildbox",
            maxConcurrentExecutions: 1
        )
        let persistence = BoardPersistence(fileURL: directory.appendingPathComponent("board.json"))
        try await persistence.save(BoardSnapshot(
            tasks: [],
            hosts: [.local, remoteHost],
            manualProjects: [
                ManualProjectReference(path: directory.path),
                ManualProjectReference(hostID: remoteHost.id, path: directory.path)
            ],
            preferences: BoardPreferences()
        ))
        let localClient = MockCodexTaskClient(projectPath: directory.path)
        let remoteClient = MockCodexTaskClient(projectPath: directory.path)
        let store = BoardStore(
            client: localClient,
            persistence: persistence,
            clientFactory: { host in
                host.id == remoteHost.id ? remoteClient : localClient
            }
        )
        store.start()

        try await eventually { store.projects.count == 2 && store.connectedHostCount == 2 }
        let localProject = try XCTUnwrap(store.projects.first { $0.hostID == CodexHost.localID })
        let remoteProject = try XCTUnwrap(store.projects.first { $0.hostID == remoteHost.id })
        XCTAssertEqual(localProject.path, remoteProject.path)
        XCTAssertNotEqual(localProject.id, remoteProject.id)

        let remoteTaskID = try XCTUnwrap(store.createTask(
            projectID: remoteProject.id,
            title: "Remote only",
            sourceKind: .issue,
            sourceText: "Run this on the build box",
            autoRun: false
        ))
        try await eventually { remoteClient.planningTurnCount == 1 }
        XCTAssertEqual(localClient.planningTurnCount, 0)
        XCTAssertEqual(store.tasks.first(where: { $0.id == remoteTaskID })?.hostID, remoteHost.id)
    }

    func testRemoteConnectionLossDoesNotFailLocalTaskWithSameThreadID() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remoteHost = CodexHost(
            id: "ssh:worker",
            name: "Worker",
            kind: .ssh,
            sshAlias: "worker",
            maxConcurrentExecutions: 1
        )
        let persistence = BoardPersistence(fileURL: directory.appendingPathComponent("board.json"))
        try await persistence.save(BoardSnapshot(
            tasks: [],
            hosts: [.local, remoteHost],
            manualProjects: [
                ManualProjectReference(path: directory.path),
                ManualProjectReference(hostID: remoteHost.id, path: directory.path)
            ],
            preferences: BoardPreferences()
        ))
        let localClient = MockCodexTaskClient(projectPath: directory.path)
        let remoteClient = MockCodexTaskClient(projectPath: directory.path)
        let store = BoardStore(
            client: localClient,
            persistence: persistence,
            clientFactory: { host in
                host.id == remoteHost.id ? remoteClient : localClient
            }
        )
        store.start()
        try await eventually { store.projects.count == 2 }
        let localProject = try XCTUnwrap(store.projects.first { $0.hostID == CodexHost.localID })
        let remoteProject = try XCTUnwrap(store.projects.first { $0.hostID == remoteHost.id })

        let localTaskID = try XCTUnwrap(store.createTask(
            projectID: localProject.id,
            title: "Local",
            sourceKind: .issue,
            sourceText: "Stay active",
            autoRun: false
        ))
        let remoteTaskID = try XCTUnwrap(store.createTask(
            projectID: remoteProject.id,
            title: "Remote",
            sourceKind: .issue,
            sourceText: "Lose this connection",
            autoRun: false
        ))
        try await eventually {
            localClient.planningTurnCount == 1 && remoteClient.planningTurnCount == 1
        }
        XCTAssertEqual(
            store.tasks.first(where: { $0.id == localTaskID })?.threadID,
            store.tasks.first(where: { $0.id == remoteTaskID })?.threadID,
            "Both app-servers intentionally return thread-1 to exercise host namespacing"
        )

        remoteClient.send(.connectionLost(message: "ssh exited"))
        try await eventually {
            store.tasks.first(where: { $0.id == remoteTaskID })?.stage == .needsAttention
        }
        XCTAssertEqual(store.tasks.first(where: { $0.id == localTaskID })?.stage, .planning)
        XCTAssertEqual(store.hostConnectionState(for: remoteHost.id), .failed("ssh exited"))
        XCTAssertEqual(store.hostConnectionState(for: CodexHost.localID), .connected)
    }

    func testPerHostConcurrencyCapsDifferentProjectsOnTheSameWorker() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var localHost = CodexHost.local
        localHost.isEnabled = false
        let remoteHost = CodexHost(
            id: "ssh:serial-worker",
            name: "Serial Worker",
            kind: .ssh,
            sshAlias: "serial-worker",
            maxConcurrentExecutions: 1
        )
        let persistence = BoardPersistence(fileURL: directory.appendingPathComponent("board.json"))
        var preferences = BoardPreferences()
        preferences.maxConcurrentExecutions = 4
        try await persistence.save(BoardSnapshot(
            tasks: [],
            hosts: [localHost, remoteHost],
            manualProjects: [
                ManualProjectReference(hostID: remoteHost.id, path: "/srv/one"),
                ManualProjectReference(hostID: remoteHost.id, path: "/srv/two")
            ],
            preferences: preferences
        ))
        let localClient = MockCodexTaskClient(projectPath: directory.path)
        let remoteClient = MockCodexTaskClient(projectPath: "/srv/one")
        let store = BoardStore(
            client: localClient,
            persistence: persistence,
            clientFactory: { host in
                host.id == remoteHost.id ? remoteClient : localClient
            }
        )
        store.start()
        try await eventually { store.projects.filter { $0.hostID == remoteHost.id }.count == 2 }
        let remoteProjects = store.projects
            .filter { $0.hostID == remoteHost.id }
            .sorted { $0.path < $1.path }

        let firstID = try XCTUnwrap(store.createTask(
            projectID: remoteProjects[0].id,
            title: "First remote project",
            sourceKind: .issue,
            sourceText: "First change",
            autoRun: true
        ))
        let secondID = try XCTUnwrap(store.createTask(
            projectID: remoteProjects[1].id,
            title: "Second remote project",
            sourceKind: .issue,
            sourceText: "Second change",
            autoRun: true
        ))
        try await eventually { remoteClient.planningTurnCount == 2 }
        remoteClient.send(.planFinal(threadID: "thread-1", turnID: "plan-1", text: "First plan"))
        remoteClient.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "plan-1",
            status: "completed",
            error: nil
        ))
        remoteClient.send(.planFinal(threadID: "thread-2", turnID: "plan-2", text: "Second plan"))
        remoteClient.send(.turnCompleted(
            threadID: "thread-2",
            turnID: "plan-2",
            status: "completed",
            error: nil
        ))

        try await eventually { remoteClient.executionTurnCount == 1 }
        XCTAssertEqual(store.tasks.count(where: { $0.stage == .executing }), 1)
        XCTAssertEqual(store.tasks.count(where: { $0.stage == .awaitingApproval }), 1)

        remoteClient.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "execute-1",
            status: "completed",
            error: nil
        ))
        try await eventually { remoteClient.executionTurnCount == 2 }
        XCTAssertEqual(store.tasks.first(where: { $0.id == firstID })?.stage, .completed)
        XCTAssertEqual(store.tasks.first(where: { $0.id == secondID })?.stage, .executing)
    }

    func testDisablingIdleHostClosesOnlyItsTransport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remoteHost = CodexHost(
            id: "ssh:idle-worker",
            name: "Idle Worker",
            kind: .ssh,
            sshAlias: "idle-worker"
        )
        let persistence = BoardPersistence(fileURL: directory.appendingPathComponent("board.json"))
        try await persistence.save(BoardSnapshot(
            tasks: [],
            hosts: [.local, remoteHost],
            manualProjects: [],
            preferences: BoardPreferences()
        ))
        let localClient = MockCodexTaskClient(projectPath: directory.path)
        let remoteClient = MockCodexTaskClient(projectPath: "/srv/idle")
        let store = BoardStore(
            client: localClient,
            persistence: persistence,
            clientFactory: { host in
                host.id == remoteHost.id ? remoteClient : localClient
            }
        )
        store.start()
        try await eventually { store.connectedHostCount == 2 }

        store.setHostEnabled(id: remoteHost.id, enabled: false)
        try await eventually { remoteClient.disconnectCount == 1 }
        XCTAssertEqual(localClient.disconnectCount, 0)
        XCTAssertEqual(store.hostConnectionState(for: remoteHost.id), .disconnected)
        XCTAssertTrue(store.host(for: CodexHost.localID)?.isEnabled == true)
    }

    func testRemovingHostDuringRefreshDoesNotRestoreGhostProjects() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remoteHost = CodexHost(
            id: "ssh:slow-worker",
            name: "Slow Worker",
            kind: .ssh,
            sshAlias: "slow-worker"
        )
        let persistence = BoardPersistence(fileURL: directory.appendingPathComponent("board.json"))
        try await persistence.save(BoardSnapshot(
            tasks: [],
            hosts: [.local, remoteHost],
            manualProjects: [],
            preferences: BoardPreferences()
        ))
        let localClient = MockCodexTaskClient(projectPath: directory.path)
        let remoteClient = MockCodexTaskClient(projectPath: "/srv/ghost-project")
        let remoteListGate = AsyncGate()
        remoteClient.listThreadsGate = remoteListGate
        let store = BoardStore(
            client: localClient,
            persistence: persistence,
            clientFactory: { host in
                host.id == remoteHost.id ? remoteClient : localClient
            }
        )
        store.start()
        try await eventually { remoteClient.listThreadsCallCount > 0 }

        XCTAssertTrue(store.removeHost(id: remoteHost.id))
        await remoteListGate.open()

        try await eventually(timeout: 3) {
            !store.isRefreshingProjects
                && store.projects.contains(where: { $0.hostID == CodexHost.localID })
                && !store.projects.contains(where: { $0.hostID == remoteHost.id })
        }
        XCTAssertNil(store.host(for: remoteHost.id))
        XCTAssertEqual(remoteClient.disconnectCount, 1)
    }

    func testContinueReconcilesCompletedTurnWithoutDuplicateExecution() async throws {
        let fixture = try Fixture(autoRunDefault: true)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try XCTUnwrap(fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Recover completed",
            sourceKind: .issue,
            sourceText: "Do not duplicate this change",
            autoRun: true
        ))
        try await eventually { fixture.client.planningTurnCount == 1 }
        fixture.client.send(.planFinal(
            threadID: "thread-1",
            turnID: "plan-1",
            text: "Safe plan"
        ))
        fixture.client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "plan-1",
            status: "completed",
            error: nil
        ))
        try await eventually { fixture.client.executionTurnCount == 1 }
        fixture.client.threadDetails["thread-1"] = makeThreadDetail(
            cwd: fixture.projectPath,
            turnID: "execute-1",
            status: "completed",
            finalText: "Recovered final result"
        )
        fixture.client.send(.connectionLost(message: "temporary disconnect"))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .needsAttention
        }

        fixture.store.continueExecution(taskID: taskID)
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .completed
        }
        XCTAssertEqual(fixture.client.executionTurnCount, 1)
        XCTAssertEqual(
            fixture.store.tasks.first(where: { $0.id == taskID })?.resultText,
            "Recovered final result"
        )
    }

    func testContinueReattachesInProgressTurnWithoutDuplicateExecution() async throws {
        let fixture = try Fixture(autoRunDefault: true)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try XCTUnwrap(fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Recover running",
            sourceKind: .issue,
            sourceText: "Keep following the existing turn",
            autoRun: true
        ))
        try await eventually { fixture.client.planningTurnCount == 1 }
        fixture.client.send(.planFinal(
            threadID: "thread-1",
            turnID: "plan-1",
            text: "Safe plan"
        ))
        fixture.client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "plan-1",
            status: "completed",
            error: nil
        ))
        try await eventually { fixture.client.executionTurnCount == 1 }
        fixture.client.threadDetails["thread-1"] = makeThreadDetail(
            cwd: fixture.projectPath,
            turnID: "execute-1",
            status: "inProgress"
        )
        fixture.client.send(.connectionLost(message: "temporary disconnect"))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .needsAttention
        }

        fixture.store.continueExecution(taskID: taskID)
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .executing
                && fixture.store.tasks.first(where: { $0.id == taskID })?.liveMessage.contains("重新连接") == true
        }
        XCTAssertEqual(fixture.client.executionTurnCount, 1)
        XCTAssertEqual(
            fixture.store.tasks.first(where: { $0.id == taskID })?.executionTurnID,
            "execute-1"
        )
    }

    private func makeThreadDetail(
        cwd: String,
        threadID: String = "thread-1",
        turnID: String,
        status: String,
        finalText: String? = nil
    ) -> CodexThreadDetail {
        CodexThreadDetail(
            summary: CodexThreadSummary(
                id: threadID,
                sessionID: "session-1",
                cwd: cwd,
                name: "Fixture",
                createdAt: Date(),
                updatedAt: Date(),
                isPinned: false,
                statusType: "active",
                sourceKind: "appServer"
            ),
            turns: [CodexThreadTurn(
                id: turnID,
                status: status,
                items: finalText.map {
                    [CodexThreadItem(id: "agent-final", type: "agentMessage", text: $0, status: nil)]
                } ?? [],
                error: nil,
                startedAt: nil,
                completedAt: nil,
                durationMilliseconds: nil
            )]
        )
    }

    private func persistedExecutionFixture(
        status: String,
        finalText: String? = nil
    ) async throws -> (
        directory: URL,
        taskID: UUID,
        client: MockCodexTaskClient,
        store: BoardStore
    ) {
        let directory = try temporaryDirectory()
        let threadID = "thread-persisted"
        let turnID = "turn-persisted"
        let task = BoardTask(
            projectID: directory.path,
            title: "Persisted execution",
            sourceKind: .issue,
            sourceText: "Recover this turn safely",
            stage: .executing,
            autoRun: true,
            executionApproved: true,
            planText: "Persisted plan",
            hasFinalPlan: true,
            threadID: threadID,
            sessionID: "session-before-relaunch",
            executionTurnID: turnID
        )
        let persistence = BoardPersistence(fileURL: directory.appendingPathComponent("board.json"))
        try await persistence.save(BoardSnapshot(
            tasks: [task],
            hosts: [.local],
            manualProjects: [ManualProjectReference(path: directory.path)],
            preferences: BoardPreferences()
        ))
        let client = MockCodexTaskClient(projectPath: directory.path)
        client.threadDetails[threadID] = makeThreadDetail(
            cwd: directory.path,
            threadID: threadID,
            turnID: turnID,
            status: status,
            finalText: finalText
        )
        return (
            directory: directory,
            taskID: task.id,
            client: client,
            store: BoardStore(client: client, persistence: persistence)
        )
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
    var disconnectCount = 0
    var listThreadsCallCount = 0
    var readThreadCount = 0
    var resumeThreadCount = 0
    var planningTurnError: Error?
    var listThreadsGate: AsyncGate?
    var threadDetails: [String: CodexThreadDetail] = [:]

    init(projectPath: String) {
        self.projectPath = projectPath
        var captured: AsyncStream<CodexEvent>.Continuation!
        events = AsyncStream { captured = $0 }
        continuation = captured
    }

    func send(_ event: CodexEvent) { continuation.yield(event) }
    func connect() async throws {}
    func disconnect() {
        disconnectCount += 1
        connectionState = .disconnected
    }
    func verifyAccount() async throws -> Bool { true }
    func listThreads(cursor: String?, archived: Bool) async throws -> CodexThreadPage {
        listThreadsCallCount += 1
        if let listThreadsGate {
            await listThreadsGate.wait()
        }
        return CodexThreadPage(
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
    func readThread(threadID: String, includeTurns: Bool) async throws -> CodexThreadDetail {
        readThreadCount += 1
        guard let detail = threadDetails[threadID] else {
            throw CodexClientError.invalidResponse("Missing mock thread detail")
        }
        return detail
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
        resumeThreadCount += 1
        return CodexStartedThread(
            threadID: threadID,
            sessionID: "session-1",
            model: "test-model",
            cwd: cwd
        )
    }
    func setThreadName(threadID: String, name: String) async throws {}
    func startPlanningTurn(threadID: String, cwd: String, prompt: String, model: String, effort: ReasoningEffort) async throws -> CodexStartedTurn {
        planningTurnCount += 1
        if let planningTurnError { throw planningTurnError }
        return CodexStartedTurn(turnID: "plan-\(planningTurnCount)", status: "inProgress")
    }
    func startExecutionTurn(threadID: String, cwd: String, prompt: String, model: String, effort: ReasoningEffort, allowNetwork: Bool) async throws -> CodexStartedTurn {
        executionTurnCount += 1
        return CodexStartedTurn(turnID: "execute-\(executionTurnCount)", status: "inProgress")
    }
    func interrupt(threadID: String, turnID: String) async throws {}
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
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
