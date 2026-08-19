import XCTest
@testable import CodexBoard

@MainActor
final class BoardStoreWorkflowTests: XCTestCase {
    func testDeliveryArtifactResolutionStaysInsideTaskWorkspace() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let artifactDirectory = fixture.directory.appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        let reportURL = artifactDirectory.appendingPathComponent("delivery.pdf")
        try Data("report".utf8).write(to: reportURL)
        let outsideURL = fixture.directory
            .deletingLastPathComponent()
            .appendingPathComponent("codexboard-outside-\(UUID().uuidString).txt")
        try Data("outside".utf8).write(to: outsideURL)
        defer { try? FileManager.default.removeItem(at: outsideURL) }

        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Artifact safety",
            sourceKind: .issue,
            sourceText: "Produce a report",
            autoRun: false
        )
        let task = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))

        XCTAssertEqual(
            fixture.store.deliveryArtifactURL(
                TaskDeliveryArtifact(path: "reports/delivery.pdf"),
                for: task
            ),
            reportURL.standardizedFileURL
        )
        XCTAssertNil(fixture.store.deliveryArtifactURL(
            TaskDeliveryArtifact(path: "../\(outsideURL.lastPathComponent)"),
            for: task
        ))
        XCTAssertNil(fixture.store.deliveryArtifactURL(
            TaskDeliveryArtifact(path: outsideURL.path),
            for: task
        ))
    }

    func testAutoRunTaskWaitsForAcceptedDependencyAndReceivesHandoff() async throws {
        let fixture = try Fixture(autoRunDefault: true)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }

        let parentID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Upstream API",
            sourceKind: .issue,
            sourceText: "Add the API",
            autoRun: true
        )
        try await eventually { fixture.client.planningTurnCount == 1 }

        let childID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Downstream UI",
            sourceKind: .issue,
            sourceText: "Use the API",
            autoRun: true,
            dependencyIDs: [parentID]
        )
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.client.planningTurnCount, 1)
        XCTAssertEqual(fixture.store.tasks.first(where: { $0.id == childID })?.stage, .inbox)
        XCTAssertEqual(
            fixture.store.taskCards.first(where: { $0.id == childID })?.blockingDependencyCount,
            1
        )

        fixture.client.send(.planFinal(
            threadID: "thread-1",
            turnID: "plan-1",
            text: "Implement and test the upstream API"
        ))
        fixture.client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "plan-1",
            status: "completed",
            error: nil
        ))
        try await eventually { fixture.client.executionTurnCount == 1 }
        fixture.client.send(.agentFinal(
            threadID: "thread-1",
            turnID: "execute-1",
            text: "Upstream implementation completed and verified."
        ))
        fixture.client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "execute-1",
            status: "completed",
            error: nil
        ))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == parentID })?.stage == .review
        }
        fixture.store.acceptReview(taskID: parentID)

        try await eventually { fixture.client.planningTurnCount == 2 }
        XCTAssertEqual(
            fixture.store.taskCards.first(where: { $0.id == childID })?.blockingDependencyCount,
            0
        )
        guard case let .text(prompt) = fixture.client.planningInputs[1][0] else {
            return XCTFail("Expected planning text input")
        }
        XCTAssertTrue(prompt.contains("已验收的前置任务交接信息"))
        XCTAssertTrue(prompt.contains("Upstream API"))
        XCTAssertTrue(prompt.contains("Upstream implementation completed"))
    }

    func testAuthenticationFailureOpensCircuitWithoutAutomaticRetry() async throws {
        let fixture = try Fixture(autoRunDefault: true)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        fixture.client.planningFailures = [.authentication]

        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Requires login",
            sourceKind: .issue,
            sourceText: "Plan this",
            autoRun: true
        )
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .needsAttention
        }
        try await Task.sleep(for: .milliseconds(1_100))

        let task = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(fixture.client.planningTurnCount, 1)
        XCTAssertEqual(task.failureState?.kind, .authentication)
        XCTAssertEqual(task.failureState?.automaticRetryCount, 0)
        XCTAssertEqual(task.failureState?.circuitOpen, true)
        let failedRun = try XCTUnwrap(task.runs.last)
        let runFailure = try XCTUnwrap(failedRun.failure)
        XCTAssertEqual(runFailure.kind, .authentication)
        XCTAssertEqual(runFailure.recoveryDisposition, .manualInterventionRequired)
        XCTAssertEqual(runFailure.occurredAt, task.failureState?.occurredAt)
        XCTAssertEqual(failedRun.endedAt, runFailure.occurredAt)
        XCTAssertEqual(task.attention?.kind, .failure)
        XCTAssertEqual(task.attention?.runID, failedRun.id)
        XCTAssertTrue(fixture.store.attentionNotices.contains(where: {
            $0.id == task.attention?.id && $0.kind == .failure
        }))
    }

    func testTransientPlanningStartupFailureRetriesOnce() async throws {
        let fixture = try Fixture(autoRunDefault: true)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        fixture.client.planningFailures = [.startup]

        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Retry startup",
            sourceKind: .issue,
            sourceText: "Plan this",
            autoRun: true
        )
        try await Task.sleep(for: .milliseconds(1_500))
        let diagnostic = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(
            fixture.client.planningTurnCount,
            2,
            "stage=\(diagnostic.stage.rawValue), failure=\(String(describing: diagnostic.failureState)), logs=\(diagnostic.logs.map(\.message))"
        )

        let retrying = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(retrying.stage, .planning)
        XCTAssertEqual(retrying.failureState?.automaticRetryCount, 1)
        XCTAssertEqual(retrying.failureState?.circuitOpen, false)
        let planningRuns = retrying.runs.filter { $0.phase == .planning }
        XCTAssertEqual(planningRuns.count, 2)
        XCTAssertEqual(planningRuns[0].failure?.recoveryDisposition, .automaticRetryScheduled)
        XCTAssertEqual(planningRuns[0].failure?.automaticRetryCount, 1)
        XCTAssertNotNil(planningRuns[0].failure?.nextRetryAt)
        XCTAssertEqual(planningRuns[1].continuation?.mode, .reusedThread)
        XCTAssertEqual(planningRuns[1].continuation?.sourceRunID, planningRuns[0].id)
        XCTAssertNil(retrying.attention)
        let retryThreadID = try XCTUnwrap(retrying.threadID)
        let retryTurnID = try XCTUnwrap(retrying.planningTurnID)

        fixture.client.send(.planFinal(
            threadID: retryThreadID,
            turnID: retryTurnID,
            text: "Recovered plan"
        ))
        fixture.client.send(.turnCompleted(
            threadID: retryThreadID,
            turnID: retryTurnID,
            status: "completed",
            error: nil
        ))
        try await Task.sleep(for: .milliseconds(250))
        let recovered = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(
            recovered.stage,
            .executing,
            "plan=\(recovered.planText), final=\(recovered.hasFinalPlan), logs=\(recovered.logs.map(\.message))"
        )
        XCTAssertEqual(fixture.client.executionTurnCount, 1)
        XCTAssertNil(recovered.failureState)
        XCTAssertNil(recovered.attention)
    }

    func testCancelDuringPendingPlanningStartupFailureSuppressesAutomaticRetry() async throws {
        let fixture = try Fixture(autoRunDefault: true)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        fixture.client.planningTurnDelayMilliseconds = 250
        fixture.client.planningFailures = [.startup]

        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Cancel pending planning startup",
            sourceKind: .issue,
            sourceText: "Do not retry after the user stops this task",
            autoRun: true
        )
        try await eventually {
            fixture.client.planningTurnCount == 1
                && fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .planning
        }

        await fixture.store.cancel(taskID: taskID)
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .needsAttention
        }

        let interrupted = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(interrupted.failureState?.kind, .interrupted)
        XCTAssertEqual(interrupted.runs.last?.outcome, .interrupted)
        XCTAssertEqual(interrupted.failureState?.automaticRetryCount, 0)
        XCTAssertTrue(interrupted.failureState?.circuitOpen == true)
        XCTAssertNil(interrupted.failureState?.nextRetryAt)
        XCTAssertEqual(
            interrupted.runs.last?.failure?.recoveryDisposition,
            TaskRunRecoveryDisposition.none
        )
        XCTAssertNil(interrupted.attention)
        XCTAssertFalse(fixture.store.attentionNotices.contains(where: {
            $0.taskID == taskID && $0.kind == .failure
        }))

        try await Task.sleep(for: .milliseconds(1_200))
        let settled = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(fixture.client.planningTurnCount, 1)
        XCTAssertEqual(settled.stage, .needsAttention)
        XCTAssertEqual(settled.failureState?.kind, .interrupted)
        XCTAssertNil(settled.failureState?.nextRetryAt)
    }

    func testImageTaskThreadStartTimeoutDoesNotCreateAutomaticRetry() async throws {
        let fixture = try Fixture(autoRunDefault: true)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        fixture.client.threadStartFailures = [.requestTimedOut("thread/start")]
        let pngData = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z4i0AAAAASUVORK5CYII="
        ))

        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Image startup timeout",
            sourceKind: .issue,
            sourceText: "Inspect this screenshot",
            attachmentDrafts: [TaskAttachmentDraft(
                displayName: "Screenshot.png",
                byteCount: Int64(pngData.count),
                source: .pastedImage(pngData)
            )],
            autoRun: true
        )
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .needsAttention
        }
        try await Task.sleep(for: .milliseconds(1_200))

        let task = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(fixture.client.threadStartCount, 1)
        XCTAssertEqual(fixture.client.planningTurnCount, 0)
        XCTAssertTrue(fixture.client.planningInputs.isEmpty)
        XCTAssertEqual(task.attachments.count, 1)
        XCTAssertEqual(task.failureState?.automaticRetryCount, 0)
        XCTAssertEqual(task.failureState?.circuitOpen, true)
        XCTAssertEqual(task.runs.last?.failure?.recoveryDisposition, .reconcileBeforeRetry)
        XCTAssertEqual(task.attention?.kind, .failure)
        XCTAssertEqual(task.attention?.runID, task.runs.last?.id)
        XCTAssertEqual(task.liveMessage, "请求状态不确定，已暂停以避免重复执行")
        XCTAssertTrue(task.logs.contains { $0.message.contains("未自动重试") })
    }

    func testExecutionUsesPreparedWorktreeAndCleanupClearsOnlyManagedCheckout() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectURL = directory.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try runGit(["-C", projectURL.path, "init", "-b", "main"])
        try runGit(["-C", projectURL.path, "config", "user.email", "codexboard@example.test"])
        try runGit(["-C", projectURL.path, "config", "user.name", "CodexBoard Tests"])
        try Data("fixture\n".utf8).write(to: projectURL.appendingPathComponent("README.md"))
        try runGit(["-C", projectURL.path, "add", "README.md"])
        try runGit(["-C", projectURL.path, "commit", "-m", "Initial"])

        let client = MockCodexTaskClient(projectPath: projectURL.path)
        let store = BoardStore(
            client: client,
            persistence: BoardPersistence(fileURL: directory.appendingPathComponent("board.json")),
            attachmentStorage: AttachmentStorage(rootDirectory: directory.appendingPathComponent("attachments")),
            worktreeManager: WorktreeManager(managedRoot: directory.appendingPathComponent("worktrees"))
        )
        store.start()
        try await eventually {
            store.projects.first(where: { $0.id == projectURL.path })?.isGitRepository == true
        }

        let taskID = try await store.createTask(
            projectID: projectURL.path,
            title: "Isolated execution",
            sourceKind: .issue,
            sourceText: "Execute in a worktree",
            autoRun: true,
            workspaceKind: .worktree
        )
        try await eventually { client.planningTurnCount == 1 }
        client.send(.planFinal(
            threadID: "thread-1",
            turnID: "plan-1",
            text: "Use the isolated workspace"
        ))
        client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "plan-1",
            status: "completed",
            error: nil
        ))
        try await eventually { client.executionCalls.count == 1 }

        let executing = try XCTUnwrap(store.tasks.first(where: { $0.id == taskID }))
        let worktreePath = try XCTUnwrap(executing.workspace.path)
        XCTAssertNotEqual(worktreePath, projectURL.path)
        XCTAssertEqual(client.executionCalls[0].cwd, worktreePath)
        XCTAssertTrue(executing.workspace.branch?.hasPrefix("codex/task-") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreePath))
        let planningRun = try XCTUnwrap(executing.runs.first(where: { $0.phase == .planning }))
        let executionRun = try XCTUnwrap(executing.runs.last(where: { $0.phase == .execution }))
        XCTAssertEqual(planningRun.continuation?.mode, .freshThread)
        XCTAssertNil(planningRun.continuation?.sourceRunID)
        XCTAssertEqual(planningRun.policySnapshot?.workspace.path, projectURL.path)
        XCTAssertEqual(planningRun.policySnapshot?.workspace.kind, .project)
        XCTAssertEqual(planningRun.policySnapshot?.sandboxMode, .readOnly)
        XCTAssertEqual(planningRun.policySnapshot?.approvalPolicy, .never)
        XCTAssertEqual(planningRun.policySnapshot?.networkAccess, false)
        XCTAssertEqual(planningRun.policySnapshot?.writableRoots, [])
        XCTAssertEqual(executionRun.continuation?.mode, .reusedThread)
        XCTAssertEqual(executionRun.continuation?.sourceRunID, planningRun.id)
        XCTAssertEqual(executionRun.policySnapshot?.workspace.path, worktreePath)
        XCTAssertEqual(executionRun.policySnapshot?.workspace.kind, .worktree)
        XCTAssertEqual(executionRun.policySnapshot?.sandboxMode, .workspaceWrite)
        XCTAssertEqual(executionRun.policySnapshot?.approvalPolicy, .onRequest)
        XCTAssertEqual(executionRun.policySnapshot?.networkAccess, true)
        XCTAssertEqual(executionRun.policySnapshot?.writableRoots, [worktreePath])

        client.send(.agentFinal(
            threadID: "thread-1",
            turnID: "execute-1",
            text: "No file changes were required."
        ))
        client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "execute-1",
            status: "completed",
            error: nil
        ))
        try await eventually { store.tasks.first(where: { $0.id == taskID })?.stage == .review }
        await store.cleanupWorktree(taskID: taskID)

        let cleaned = try XCTUnwrap(store.tasks.first(where: { $0.id == taskID }))
        XCTAssertNil(cleaned.workspace.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.path))
    }

    func testManualTaskWaitsInInboxUntilExplicitlyStartedAndThenRequiresConfirmation() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Manual",
            sourceKind: .issue,
            sourceText: "Do the thing",
            autoRun: false
        )

        try await Task.sleep(for: .milliseconds(100))
        let waitingTask = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(waitingTask.stage, .inbox)
        XCTAssertNil(waitingTask.threadID)
        XCTAssertNil(waitingTask.planningTurnID)
        XCTAssertTrue(waitingTask.runs.isEmpty)
        XCTAssertEqual(fixture.client.threadStartCount, 0)
        XCTAssertEqual(fixture.client.planningTurnCount, 0)
        XCTAssertEqual(fixture.client.executionTurnCount, 0)

        await fixture.store.startPlanning(taskID: taskID)
        await fixture.store.startPlanning(taskID: taskID)
        try await eventually {
            fixture.client.planningTurnCount == 1
                && fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .planning
        }
        XCTAssertEqual(fixture.client.threadStartCount, 1)
        XCTAssertEqual(fixture.client.planningTurnCount, 1)
        XCTAssertEqual(
            fixture.store.tasks.first(where: { $0.id == taskID })?.runs.filter { $0.phase == .planning }.count,
            1
        )

        let interactionID = CodexRequestID.string("manual-plan-interaction")
        fixture.client.send(.interactionRequested(CodexInteractionRequest(
            id: interactionID,
            threadID: "thread-1",
            turnID: "plan-1",
            itemID: nil,
            kind: .userInput(CodexUserInputRequest(questions: [], isBlocking: true)),
            createdAt: Date()
        )))
        try await eventually {
            fixture.store.interactions(for: taskID).contains(where: { $0.id == interactionID })
                && fixture.store.attentionNotices.contains(where: {
                    $0.taskID == taskID && $0.kind == .interaction
                })
        }
        fixture.store.selectedTaskID = nil
        let interactionFocusNonce = try XCTUnwrap(fixture.store.taskFocusRequest?.nonce)

        fixture.client.send(.planFinal(threadID: "thread-1", turnID: "plan-1", text: "1. Inspect\n2. Fix"))
        fixture.client.send(.turnCompleted(threadID: "thread-1", turnID: "plan-1", status: "completed", error: nil))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .awaitingApproval
                && fixture.store.attentionNotices.contains(where: {
                    $0.taskID == taskID && $0.kind == .planApproval
                })
        }

        XCTAssertEqual(fixture.client.executionTurnCount, 0)
        XCTAssertFalse(fixture.store.hasPendingInteraction(for: taskID))
        XCTAssertFalse(fixture.store.attentionNotices.contains(where: { $0.kind == .interaction }))
        XCTAssertEqual(fixture.store.selectedProjectID, fixture.projectPath)
        XCTAssertEqual(fixture.store.selectedTaskID, taskID)
        XCTAssertEqual(fixture.store.taskFocusRequest?.taskID, taskID)
        XCTAssertEqual(fixture.store.taskFocusRequest?.stage, .awaitingApproval)
        XCTAssertNotEqual(fixture.store.taskFocusRequest?.nonce, interactionFocusNonce)
        fixture.store.confirmPlan(taskID: taskID)
        XCTAssertFalse(fixture.store.attentionNotices.contains(where: {
            $0.taskID == taskID && $0.kind == .planApproval
        }))
        try await eventually { fixture.client.executionTurnCount == 1 }
        XCTAssertEqual(fixture.store.tasks.first(where: { $0.id == taskID })?.stage, .executing)
    }

    func testReplayedPlanningCompletionDoesNotRegressExecutingManualTaskOrRefocus() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Ignore replayed planning completion",
            sourceKind: .issue,
            sourceText: "Keep executing after an old planning event is replayed",
            autoRun: false
        )

        await fixture.store.startPlanning(taskID: taskID)
        try await eventually {
            fixture.client.planningTurnCount == 1
                && fixture.store.tasks.first(where: { $0.id == taskID })?.planningTurnID != nil
        }
        let planningTask = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        let threadID = try XCTUnwrap(planningTask.threadID)
        let planningTurnID = try XCTUnwrap(planningTask.planningTurnID)

        fixture.client.send(.planFinal(
            threadID: threadID,
            turnID: planningTurnID,
            text: "Implement the fix and verify it"
        ))
        fixture.client.send(.turnCompleted(
            threadID: threadID,
            turnID: planningTurnID,
            status: "completed",
            error: nil
        ))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .awaitingApproval
                && fixture.store.attentionNotices.contains(where: {
                    $0.taskID == taskID && $0.kind == .planApproval
                })
        }

        fixture.store.confirmPlan(taskID: taskID)
        try await eventually {
            fixture.client.executionTurnCount == 1
                && fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .executing
                && fixture.store.tasks.first(where: { $0.id == taskID })?.executionTurnID != nil
        }
        let focusNonce = try XCTUnwrap(fixture.store.taskFocusRequest?.nonce)
        let executionTurnID = try XCTUnwrap(
            fixture.store.tasks.first(where: { $0.id == taskID })?.executionTurnID
        )
        XCTAssertFalse(fixture.store.attentionNotices.contains(where: {
            $0.taskID == taskID && $0.kind == .planApproval
        }))

        fixture.client.send(.turnCompleted(
            threadID: threadID,
            turnID: planningTurnID,
            status: "completed",
            error: nil
        ))
        fixture.client.send(.activity(
            threadID: threadID,
            turnID: executionTurnID,
            message: "Execution remains active after planning replay"
        ))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.liveMessage
                == "Execution remains active after planning replay"
        }

        XCTAssertEqual(fixture.store.tasks.first(where: { $0.id == taskID })?.stage, .executing)
        XCTAssertEqual(fixture.client.executionTurnCount, 1)
        XCTAssertFalse(fixture.store.attentionNotices.contains(where: {
            $0.taskID == taskID && $0.kind == .planApproval
        }))
        XCTAssertEqual(fixture.store.taskFocusRequest?.nonce, focusNonce)
    }

    func testReplayedExecutionCompletionDoesNotRegressAcceptedTask() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Ignore replayed execution completion",
            sourceKind: .issue,
            sourceText: "Keep the accepted task completed after an old execution event is replayed",
            autoRun: false
        )

        await fixture.store.startPlanning(taskID: taskID)
        try await eventually {
            fixture.client.planningTurnCount == 1
                && fixture.store.tasks.first(where: { $0.id == taskID })?.planningTurnID != nil
        }
        let planningTask = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        let threadID = try XCTUnwrap(planningTask.threadID)
        let planningTurnID = try XCTUnwrap(planningTask.planningTurnID)
        fixture.client.send(.planFinal(
            threadID: threadID,
            turnID: planningTurnID,
            text: "Implement and verify the requested behavior"
        ))
        fixture.client.send(.turnCompleted(
            threadID: threadID,
            turnID: planningTurnID,
            status: "completed",
            error: nil
        ))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .awaitingApproval
        }

        fixture.store.confirmPlan(taskID: taskID)
        try await eventually {
            fixture.client.executionTurnCount == 1
                && fixture.store.tasks.first(where: { $0.id == taskID })?.executionTurnID != nil
        }
        let executionTurnID = try XCTUnwrap(
            fixture.store.tasks.first(where: { $0.id == taskID })?.executionTurnID
        )
        fixture.client.send(.turnCompleted(
            threadID: threadID,
            turnID: executionTurnID,
            status: "completed",
            error: nil
        ))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .review
        }

        fixture.store.acceptReview(taskID: taskID)
        let acceptedTask = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        let reviewedAt = try XCTUnwrap(acceptedTask.latestExecutionRun?.reviewedAt)
        XCTAssertEqual(acceptedTask.stage, .completed)
        XCTAssertEqual(acceptedTask.latestExecutionRun?.outcome, .accepted)

        let replayProbe = "Execution completion replay was consumed"
        fixture.client.send(.turnCompleted(
            threadID: threadID,
            turnID: executionTurnID,
            status: "completed",
            error: nil
        ))
        fixture.client.send(.configurationWarning(
            threadID: threadID,
            turnID: executionTurnID,
            message: replayProbe
        ))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.logs.contains(where: {
                $0.message == replayProbe
            }) == true
        }

        let settledTask = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(settledTask.stage, .completed)
        XCTAssertEqual(settledTask.latestExecutionRun?.outcome, .accepted)
        XCTAssertEqual(settledTask.latestExecutionRun?.reviewedAt, reviewedAt)
    }

    func testPersistedManualInboxTaskDoesNotStartWhenStoreReloads() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = BoardPersistence(fileURL: directory.appendingPathComponent("board.json"))
        let task = BoardTask(
            projectID: directory.path,
            title: "Wait after restart",
            sourceKind: .issue,
            sourceText: "Do not plan until I click start",
            autoRun: false
        )
        try await persistence.save(BoardSnapshot(
            version: BoardSnapshot.currentVersion,
            tasks: [task],
            manualProjectPaths: [directory.path],
            preferences: BoardPreferences()
        ))
        let client = MockCodexTaskClient(projectPath: directory.path)
        let store = BoardStore(
            client: client,
            persistence: persistence,
            attachmentStorage: AttachmentStorage(rootDirectory: directory.appendingPathComponent("attachments"))
        )

        store.start()
        try await eventually { store.projects.contains(where: { $0.id == directory.path }) }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(store.tasks.first?.stage, .inbox)
        XCTAssertEqual(store.tasks.first?.liveMessage, "等待开始规划")
        XCTAssertEqual(client.threadStartCount, 0)
        XCTAssertEqual(client.planningTurnCount, 0)
    }

    func testPersistedManualAwaitingApprovalTaskRestoresPlanAttentionAndSelection() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = BoardPersistence(fileURL: directory.appendingPathComponent("board.json"))
        let taskID = UUID()
        let attentionID = UUID()
        let updatedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let task = BoardTask(
            id: taskID,
            projectID: directory.path,
            title: "Restore pending plan",
            sourceKind: .developmentPlan,
            sourceText: "Keep waiting for manual confirmation after relaunch",
            stage: .awaitingApproval,
            autoRun: false,
            executionApproved: false,
            updatedAt: updatedAt,
            planText: "1. Inspect\n2. Implement\n3. Verify",
            hasFinalPlan: true,
            liveMessage: "方案完成，等待确认",
            threadID: "thread-persisted",
            attention: TaskAttention(
                id: attentionID,
                kind: .planApproval,
                createdAt: updatedAt
            )
        )
        try await persistence.save(BoardSnapshot(
            version: BoardSnapshot.currentVersion,
            tasks: [task],
            manualProjectPaths: [directory.path],
            preferences: BoardPreferences()
        ))
        let client = MockCodexTaskClient(projectPath: directory.path)
        let store = BoardStore(
            client: client,
            persistence: persistence,
            attachmentStorage: AttachmentStorage(rootDirectory: directory.appendingPathComponent("attachments"))
        )

        store.start()
        try await eventually {
            store.projects.contains(where: { $0.id == directory.path })
                && store.attentionNotices.contains(where: {
                    $0.taskID == taskID && $0.kind == .planApproval
                })
                && store.taskFocusRequest?.taskID == taskID
        }

        XCTAssertEqual(store.selectedProjectID, directory.path)
        XCTAssertEqual(store.selectedTaskID, taskID)
        XCTAssertEqual(store.taskFocusRequest?.stage, .awaitingApproval)
        XCTAssertEqual(store.tasks.first?.attention?.id, attentionID)
        XCTAssertEqual(
            store.attentionNotices.first(where: {
                $0.taskID == taskID && $0.kind == .planApproval
            })?.id,
            attentionID
        )
        XCTAssertEqual(store.tasks.first?.attention?.createdAt, updatedAt)
        XCTAssertEqual(client.executionTurnCount, 0)
    }

    func testPersistedFailureAttentionRestoresSameNoticeAfterRestart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = BoardPersistence(fileURL: directory.appendingPathComponent("board.json"))
        let taskID = UUID()
        let runID = UUID()
        let attentionID = UUID()
        let failedAt = Date(timeIntervalSince1970: 1_750_000_100)
        let message = "Workspace requires inspection"
        let run = TaskRun(
            id: runID,
            phase: .execution,
            attempt: 1,
            startedAt: failedAt.addingTimeInterval(-10),
            endedAt: failedAt,
            outcome: .failed,
            reasoningEffort: .high,
            fastMode: false,
            failure: TaskRunFailure(
                kind: .workspace,
                message: message,
                occurredAt: failedAt,
                recoveryDisposition: .manualInterventionRequired
            ),
            summary: message,
            error: message
        )
        let task = BoardTask(
            id: taskID,
            projectID: directory.path,
            title: "Restore failure attention",
            sourceKind: .issue,
            sourceText: "Keep the failure actionable after relaunch",
            stage: .needsAttention,
            autoRun: false,
            updatedAt: failedAt,
            lastError: message,
            runs: [run],
            failureState: TaskFailureState(
                kind: .workspace,
                circuitOpen: true,
                occurredAt: failedAt,
                message: message
            ),
            attention: TaskAttention(
                id: attentionID,
                kind: .failure,
                runID: runID,
                createdAt: failedAt
            )
        )
        try await persistence.save(BoardSnapshot(
            version: BoardSnapshot.currentVersion,
            tasks: [task],
            manualProjectPaths: [directory.path],
            preferences: BoardPreferences()
        ))
        let client = MockCodexTaskClient(projectPath: directory.path)
        let store = BoardStore(client: client, persistence: persistence)

        store.start()
        try await eventually {
            store.projects.contains(where: { $0.id == directory.path })
                && store.attentionNotices.contains(where: {
                    $0.id == attentionID && $0.kind == .failure
                })
        }

        XCTAssertEqual(store.tasks.first?.attention?.id, attentionID)
        XCTAssertEqual(store.tasks.first?.attention?.runID, runID)
        XCTAssertEqual(store.attentionNotices.first(where: { $0.id == attentionID })?.createdAt, failedAt)
        XCTAssertEqual(client.threadStartCount, 0)
        XCTAssertEqual(client.executionTurnCount, 0)
    }

    func testMovingTaskWithFinalPlanToAwaitingApprovalCreatesAttentionAndFocusesIt() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let taskID = UUID()
        let task = BoardTask(
            id: taskID,
            projectID: directory.path,
            title: "Move plan for approval",
            sourceKind: .developmentPlan,
            sourceText: "Return this prepared plan to manual approval",
            stage: .needsAttention,
            autoRun: false,
            executionApproved: false,
            planText: "Review the current state, implement the change, and verify it.",
            hasFinalPlan: true,
            liveMessage: "等待人工处理"
        )
        let persistence = RecordingBoardPersistence(initialSnapshot: BoardSnapshot(
            version: BoardSnapshot.currentVersion,
            tasks: [task],
            manualProjectPaths: [directory.path],
            preferences: BoardPreferences()
        ))
        let client = MockCodexTaskClient(projectPath: directory.path)
        let store = BoardStore(
            client: client,
            persistence: persistence,
            attachmentStorage: AttachmentStorage(rootDirectory: directory.appendingPathComponent("attachments"))
        )
        store.start()
        try await eventually { store.projects.contains(where: { $0.id == directory.path }) }
        XCTAssertFalse(store.attentionNotices.contains(where: { $0.taskID == taskID }))

        XCTAssertTrue(store.moveTask(taskID: taskID, to: .awaitingApproval))

        XCTAssertEqual(store.tasks.first(where: { $0.id == taskID })?.stage, .awaitingApproval)
        XCTAssertFalse(store.tasks.first(where: { $0.id == taskID })?.executionApproved ?? true)
        XCTAssertEqual(store.selectedProjectID, directory.path)
        XCTAssertEqual(store.selectedTaskID, taskID)
        XCTAssertEqual(store.taskFocusRequest?.taskID, taskID)
        XCTAssertEqual(store.taskFocusRequest?.stage, .awaitingApproval)
        XCTAssertEqual(
            store.attentionNotices.count(where: {
                $0.taskID == taskID && $0.kind == .planApproval
            }),
            1
        )
    }

    func testCompletingDependencyOnlyAutoStartsEligibleAutoRunTask() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let dependencyID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Dependency",
            sourceKind: .issue,
            sourceText: "Complete first",
            autoRun: false
        )
        let automaticID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Automatic dependent",
            sourceKind: .issue,
            sourceText: "Start when unblocked",
            autoRun: true,
            dependencyIDs: [dependencyID]
        )
        let manualID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Manual dependent",
            sourceKind: .issue,
            sourceText: "Still wait for a click",
            autoRun: false,
            dependencyIDs: [dependencyID]
        )

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.client.planningTurnCount, 0)
        XCTAssertTrue(fixture.store.moveTask(taskID: dependencyID, to: .completed))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == automaticID })?.stage == .planning
                && fixture.client.planningTurnCount == 1
        }

        let manualTask = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == manualID }))
        XCTAssertEqual(manualTask.stage, .inbox)
        XCTAssertEqual(manualTask.liveMessage, "等待开始规划")
        XCTAssertNil(manualTask.threadID)
    }

    func testCreatingTaskUsesExplicitModelEffortAndFastMode() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually {
            fixture.store.projects.contains(where: { $0.id == fixture.projectPath })
                && fixture.store.availableModels.contains(where: { $0.model == "gpt-test" })
        }

        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Configured task",
            sourceKind: .issue,
            sourceText: "Use the selected runtime configuration",
            autoRun: false,
            model: "gpt-selected",
            effort: .max,
            fastMode: true
        )

        await fixture.store.startPlanning(taskID: taskID)
        try await eventually { fixture.client.planningCalls.count == 1 }
        let task = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(task.requestedModel, "gpt-selected")
        XCTAssertEqual(task.reasoningEffort, .max)
        XCTAssertTrue(task.fastMode)
        XCTAssertEqual(task.actualModel, "gpt-selected")

        let threadCall = try XCTUnwrap(fixture.client.threadStartCalls.first)
        XCTAssertEqual(threadCall.model, "gpt-selected")
        XCTAssertEqual(threadCall.serviceTier, "priority")
        let planningCall = try XCTUnwrap(fixture.client.planningCalls.first)
        XCTAssertEqual(planningCall.model, "gpt-selected")
        XCTAssertEqual(planningCall.effort, .max)
        XCTAssertEqual(planningCall.serviceTier, "priority")
    }

    func testTaskConfigurationIsFrozenAcrossPlanningAndExecution() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        fixture.store.updatePreferences {
            $0.modelOverride = "gpt-test"
            $0.planningEffort = .ultra
            $0.executionEffort = .low
        }

        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Frozen configuration",
            sourceKind: .developmentPlan,
            sourceText: "Keep the task configuration stable",
            autoRun: false,
            fastMode: true
        )
        await fixture.store.startPlanning(taskID: taskID)
        try await eventually { fixture.client.planningCalls.count == 1 }

        fixture.store.updatePreferences {
            $0.modelOverride = "gpt-changed-after-creation"
            $0.planningEffort = .low
            $0.executionEffort = .xhigh
        }
        fixture.client.send(.planFinal(
            threadID: "thread-1",
            turnID: "plan-1",
            text: "Frozen plan"
        ))
        fixture.client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "plan-1",
            status: "completed",
            error: nil
        ))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .awaitingApproval
        }
        fixture.store.confirmPlan(taskID: taskID)
        try await eventually { fixture.client.executionCalls.count == 1 }

        let planningCall = try XCTUnwrap(fixture.client.planningCalls.first)
        XCTAssertEqual(planningCall.model, "gpt-test")
        XCTAssertEqual(planningCall.effort, .ultra)
        XCTAssertEqual(planningCall.serviceTier, "priority")
        let executionCall = try XCTUnwrap(fixture.client.executionCalls.first)
        XCTAssertEqual(executionCall.model, "gpt-test")
        XCTAssertEqual(executionCall.effort, .ultra)
        XCTAssertEqual(executionCall.serviceTier, "priority")

        let task = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(task.requestedModel, "gpt-test")
        XCTAssertEqual(task.reasoningEffort, .ultra)
        XCTAssertTrue(task.fastMode)
    }

    func testSelectedCapabilitiesAreFrozenAcrossCatalogRefreshPlanningAndExecution() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }

        let skillPath = fixture.directory
            .appendingPathComponent(".agents/skills/repository-review/SKILL.md")
            .path
        let skill = CodexSkillMetadata(
            name: "Repository Review",
            description: "Review the repository without changing files.",
            shortDescription: "Read-only repository review",
            path: skillPath,
            scope: "repo",
            enabled: true
        )
        let readOnlyApp = CodexApp(
            id: "knowledge-app",
            name: "Knowledge",
            invocationName: "knowledge",
            description: "Search reference material.",
            isAccessible: true,
            isEnabled: true,
            isCallable: true,
            tools: [CodexAppToolSummary(
                name: "search",
                title: "Search",
                description: "Search reference material.",
                isEnabled: true,
                isReadOnly: true,
                disabledReason: nil
            )]
        )
        let mixedApp = CodexApp(
            id: "mixed-app",
            name: "Mixed",
            invocationName: "mixed",
            description: "Reads and writes external data.",
            isAccessible: true,
            isEnabled: true,
            isCallable: true,
            tools: [
                CodexAppToolSummary(
                    name: "read",
                    title: "Read",
                    description: "Read external data.",
                    isEnabled: true,
                    isReadOnly: true,
                    disabledReason: nil
                ),
                CodexAppToolSummary(
                    name: "write",
                    title: "Write",
                    description: "Write external data.",
                    isEnabled: true,
                    isReadOnly: false,
                    disabledReason: nil
                )
            ]
        )
        fixture.client.skillsCatalog = [fixture.projectPath: [skill]]
        fixture.client.appsCatalog = [readOnlyApp, mixedApp]

        await fixture.store.refreshCapabilities(projectID: fixture.projectPath, forceRefresh: true)
        XCTAssertEqual(fixture.store.availableSkills, [skill])
        XCTAssertEqual(fixture.store.availableApps, [readOnlyApp, mixedApp])
        XCTAssertTrue(readOnlyApp.supportsReadOnlyUse)
        XCTAssertFalse(mixedApp.supportsReadOnlyUse)

        let selectedSkill = TaskSkillSelection(
            name: skill.name,
            description: skill.description,
            path: skill.path,
            scope: skill.scope
        )
        let selectedApp = TaskAppSelection(
            id: readOnlyApp.id,
            name: readOnlyApp.name,
            invocationName: readOnlyApp.invocationName,
            description: readOnlyApp.description
        )
        let blockedWriteApp = TaskAppSelection(
            id: mixedApp.id,
            name: mixedApp.name,
            invocationName: mixedApp.invocationName,
            description: mixedApp.description,
            requiresApproval: true
        )
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Frozen capabilities",
            sourceKind: .issue,
            sourceText: "Use the selected read-only capabilities",
            autoRun: false,
            selectedSkills: [selectedSkill],
            selectedApps: [selectedApp, blockedWriteApp]
        )

        let replacementSkill = CodexSkillMetadata(
            name: "Replacement Skill",
            description: "A catalog entry added after task creation.",
            shortDescription: nil,
            path: fixture.directory.appendingPathComponent("replacement/SKILL.md").path,
            scope: "user",
            enabled: true
        )
        let writeDriftedApp = CodexApp(
            id: readOnlyApp.id,
            name: "Knowledge With Writes",
            invocationName: readOnlyApp.invocationName,
            description: "The same app gained an enabled write tool.",
            isAccessible: true,
            isEnabled: true,
            isCallable: true,
            tools: [
                CodexAppToolSummary(
                    name: "lookup",
                    title: "Lookup",
                    description: "Look up data.",
                    isEnabled: true,
                    isReadOnly: true,
                    disabledReason: nil
                ),
                CodexAppToolSummary(
                    name: "update",
                    title: "Update",
                    description: "Update external data.",
                    isEnabled: true,
                    isReadOnly: false,
                    disabledReason: nil
                )
            ]
        )
        let frozenTask = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(frozenTask.selectedSkills, [selectedSkill])
        XCTAssertEqual(frozenTask.selectedApps, [selectedApp])

        await fixture.store.startPlanning(taskID: taskID)
        try await eventually { fixture.client.planningInputs.count == 1 }
        let planningInput = fixture.client.planningInputs[0]
        XCTAssertEqual(planningInput.count, 3)
        guard case .text = planningInput[0] else {
            return XCTFail("Planning text must precede frozen capability inputs")
        }
        XCTAssertEqual(planningInput[1], .skill(name: selectedSkill.name, path: selectedSkill.path))
        XCTAssertEqual(planningInput[2], .mention(name: selectedApp.invocationName, path: "app://\(selectedApp.id)"))

        fixture.client.skillsCatalog = [fixture.projectPath: [replacementSkill]]
        fixture.client.appsCatalog = [writeDriftedApp]
        await fixture.store.refreshCapabilities(projectID: fixture.projectPath, forceRefresh: true)

        XCTAssertEqual(fixture.store.availableSkills, [replacementSkill])
        XCTAssertEqual(fixture.store.availableApps, [writeDriftedApp])

        fixture.client.send(.planFinal(
            threadID: "thread-1",
            turnID: "plan-1",
            text: "Use the frozen read-only capabilities"
        ))
        fixture.client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "plan-1",
            status: "completed",
            error: nil
        ))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .awaitingApproval
        }
        fixture.store.confirmPlan(taskID: taskID)
        try await eventually { fixture.client.executionInputs.count == 1 }

        let executionInput = fixture.client.executionInputs[0]
        XCTAssertEqual(executionInput.count, 2)
        guard case .text = executionInput[0] else {
            return XCTFail("Execution text must precede frozen capability inputs")
        }
        XCTAssertEqual(executionInput[1], planningInput[1])
        XCTAssertFalse(executionInput.contains(planningInput[2]))
        let executingTask = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(executingTask.selectedSkills, [selectedSkill])
        XCTAssertEqual(executingTask.selectedApps, [selectedApp])
        XCTAssertEqual(fixture.client.appListThreadIDs, ["thread-1", "thread-1"])
    }

    func testFastModeOffMapsToDefaultServiceTierForBothTurns() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Standard speed",
            sourceKind: .issue,
            sourceText: "Do not use Fast mode",
            autoRun: false,
            model: "gpt-selected",
            effort: .low,
            fastMode: false
        )

        await fixture.store.startPlanning(taskID: taskID)
        try await eventually { fixture.client.planningCalls.count == 1 }
        XCTAssertEqual(fixture.client.threadStartCalls.first?.serviceTier, "default")
        XCTAssertEqual(fixture.client.planningCalls.first?.serviceTier, "default")
        fixture.client.send(.planFinal(
            threadID: "thread-1",
            turnID: "plan-1",
            text: "Standard-speed plan"
        ))
        fixture.client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "plan-1",
            status: "completed",
            error: nil
        ))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .awaitingApproval
        }
        fixture.store.confirmPlan(taskID: taskID)
        try await eventually { fixture.client.executionCalls.count == 1 }
        XCTAssertEqual(fixture.client.executionCalls.first?.serviceTier, "default")
    }

    func testAwaitingApprovalPlanCanBeEdited() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Editable",
            sourceKind: .issue,
            sourceText: "Adjust the plan",
            autoRun: false
        )

        await fixture.store.startPlanning(taskID: taskID)
        try await eventually { fixture.client.planningTurnCount == 1 }
        fixture.client.send(.planUpdated(
            threadID: "thread-1",
            turnID: "plan-1",
            explanation: nil,
            steps: [CodexPlanStep(step: "Original step", status: .pending)]
        ))
        fixture.client.send(.planFinal(
            threadID: "thread-1",
            turnID: "plan-1",
            text: "# Original plan"
        ))
        fixture.client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "plan-1",
            status: "completed",
            error: nil
        ))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .awaitingApproval
        }
        let previousUpdatedAt = try XCTUnwrap(
            fixture.store.tasks.first(where: { $0.id == taskID })?.updatedAt
        )

        XCTAssertFalse(fixture.store.updatePlan(taskID: taskID, planText: "  \n "))
        XCTAssertTrue(fixture.store.updatePlan(
            taskID: taskID,
            planText: "# Revised plan\n\n1. Keep Markdown formatting"
        ))

        let editedTask = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(editedTask.planText, "# Revised plan\n\n1. Keep Markdown formatting")
        XCTAssertTrue(editedTask.structuredPlan.isEmpty)
        XCTAssertFalse(editedTask.executionApproved)
        XCTAssertGreaterThanOrEqual(editedTask.updatedAt, previousUpdatedAt)
        XCTAssertEqual(editedTask.logs.last?.level, .warning)
        XCTAssertTrue(editedTask.logs.last?.message.contains("需要重新确认") == true)

        try await Task.sleep(for: .milliseconds(350))
        let persisted = try await BoardPersistence(
            fileURL: fixture.directory.appendingPathComponent("board.json")
        ).load()
        XCTAssertEqual(
            persisted.tasks.first(where: { $0.id == taskID })?.planText,
            "# Revised plan\n\n1. Keep Markdown formatting"
        )
    }

    func testEditingQueuedPlanRevokesApprovalUntilReconfirmed() async throws {
        let fixture = try Fixture(autoRunDefault: true)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let firstID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "First",
            sourceKind: .issue,
            sourceText: "Occupy the project",
            autoRun: true
        )
        let secondID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Second",
            sourceKind: .issue,
            sourceText: "Wait for the project",
            autoRun: true
        )
        try await eventually { fixture.client.planningTurnCount == 2 }

        fixture.client.send(.planFinal(
            threadID: "thread-1",
            turnID: "plan-1",
            text: "First plan"
        ))
        fixture.client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "plan-1",
            status: "completed",
            error: nil
        ))
        fixture.client.send(.planFinal(
            threadID: "thread-2",
            turnID: "plan-2",
            text: "Original second plan"
        ))
        fixture.client.send(.turnCompleted(
            threadID: "thread-2",
            turnID: "plan-2",
            status: "completed",
            error: nil
        ))
        try await eventually {
            fixture.client.executionTurnCount == 1
                && fixture.store.tasks.first(where: { $0.id == secondID })?.stage == .awaitingApproval
        }
        XCTAssertTrue(try XCTUnwrap(
            fixture.store.tasks.first(where: { $0.id == secondID })?.executionApproved
        ))
        XCTAssertFalse(fixture.store.attentionNotices.contains(where: {
            $0.taskID == secondID && $0.kind == .planApproval
        }))
        fixture.store.focusTask(firstID)
        let previousFocusNonce = try XCTUnwrap(fixture.store.taskFocusRequest?.nonce)

        XCTAssertTrue(fixture.store.updatePlan(
            taskID: secondID,
            planText: "Revised second plan"
        ))
        XCTAssertFalse(try XCTUnwrap(
            fixture.store.tasks.first(where: { $0.id == secondID })?.executionApproved
        ))
        XCTAssertEqual(fixture.store.selectedTaskID, secondID)
        XCTAssertEqual(fixture.store.taskFocusRequest?.taskID, secondID)
        XCTAssertEqual(fixture.store.taskFocusRequest?.stage, .awaitingApproval)
        XCTAssertNotEqual(fixture.store.taskFocusRequest?.nonce, previousFocusNonce)
        XCTAssertEqual(
            fixture.store.attentionNotices.count(where: {
                $0.taskID == secondID && $0.kind == .planApproval
            }),
            1
        )

        fixture.client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "execute-1",
            status: "completed",
            error: nil
        ))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == firstID })?.stage == .review
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.client.executionTurnCount, 1)

        fixture.store.confirmPlan(taskID: secondID)
        XCTAssertFalse(fixture.store.attentionNotices.contains(where: {
            $0.taskID == secondID && $0.kind == .planApproval
        }))
        try await eventually { fixture.client.executionTurnCount == 2 }
        let executionInput = try XCTUnwrap(fixture.client.executionInputs.last?.first)
        guard case let .text(prompt) = executionInput else {
            return XCTFail("Execution prompt must be the first text input")
        }
        XCTAssertTrue(prompt.contains("Revised second plan"))
        XCTAssertFalse(prompt.contains("Original second plan"))
    }

    func testAutoRunSkipsConfirmationButKeepsPlanning() async throws {
        let fixture = try Fixture(autoRunDefault: true)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Auto",
            sourceKind: .developmentPlan,
            sourceText: "Ship milestone",
            autoRun: true
        )

        try await eventually {
            fixture.client.planningTurnCount == 1
                && fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .planning
        }
        XCTAssertEqual(fixture.client.threadStartCount, 1)
        fixture.client.send(.planFinal(threadID: "thread-1", turnID: "plan-1", text: "Approved plan"))
        fixture.client.send(.turnCompleted(threadID: "thread-1", turnID: "plan-1", status: "completed", error: nil))

        try await eventually { fixture.client.executionTurnCount == 1 }
        XCTAssertEqual(fixture.store.tasks.first(where: { $0.id == taskID })?.stage, .executing)
        XCTAssertFalse(fixture.store.attentionNotices.contains(where: {
            $0.taskID == taskID && $0.kind == .planApproval
        }))
    }

    func testTaskRPCFailureDoesNotMarkConnectedHostOffline() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        fixture.client.planningTurnError = CodexClientError.rpc(
            code: -32_602,
            message: "model unavailable"
        )

        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Task-level failure",
            sourceKind: .issue,
            sourceText: "Keep the host healthy",
            autoRun: false
        )
        await fixture.store.startPlanning(taskID: taskID)

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
        let rootTaskID = try? await store.createTask(
            projectID: rootProject.id,
            title: "Unsafe root",
            sourceKind: .issue,
            sourceText: "Do not run here",
            autoRun: false
        )
        XCTAssertNil(rootTaskID)
        XCTAssertEqual(client.threadStartCount, 0)
    }

    func testPersistenceFailurePreventsStartingRemoteWork() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
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
        let taskID = try await store.createTask(
            projectID: project.id,
            title: "Do not start",
            sourceKind: .issue,
            sourceText: "Persistence is unavailable",
            autoRun: false
        )
        await store.startPlanning(taskID: taskID)

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
            fixture.store.tasks.first(where: { $0.id == fixture.taskID })?.stage == .review
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
        let fixture = try await persistedExecutionFixture(
            status: "inProgress",
            includeClosedExecutionRun: true
        )
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
        let run = try XCTUnwrap(task.runs.last(where: { $0.phase == .execution }))
        XCTAssertEqual(run.id, fixture.executionRunID)
        XCTAssertEqual(run.outcome, .running)
        XCTAssertNil(run.endedAt)
        XCTAssertNil(run.error)
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
        let firstID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "First",
            sourceKind: .issue,
            sourceText: "First change",
            autoRun: true
        )
        let secondID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Second",
            sourceKind: .issue,
            sourceText: "Second change",
            autoRun: true
        )
        try await eventually { fixture.client.planningTurnCount == 2 }

        fixture.client.send(.planFinal(threadID: "thread-1", turnID: "plan-1", text: "First plan"))
        fixture.client.send(.turnCompleted(threadID: "thread-1", turnID: "plan-1", status: "completed", error: nil))
        fixture.client.send(.planFinal(threadID: "thread-2", turnID: "plan-2", text: "Second plan"))
        fixture.client.send(.turnCompleted(threadID: "thread-2", turnID: "plan-2", status: "completed", error: nil))

        try await eventually { fixture.client.executionTurnCount == 1 }
        XCTAssertEqual(fixture.store.tasks.first(where: { $0.id == firstID })?.stage, .executing)
        XCTAssertEqual(fixture.store.tasks.first(where: { $0.id == secondID })?.stage, .awaitingApproval)
        XCTAssertEqual(
            fixture.store.tasks.first(where: { $0.id == secondID })?.liveMessage,
            "等待同项目的主目录任务结束"
        )

        fixture.client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "execute-1",
            status: "completed",
            error: nil
        ))
        try await eventually { fixture.client.executionTurnCount == 2 }
        XCTAssertEqual(fixture.store.tasks.first(where: { $0.id == secondID })?.stage, .executing)
    }

    func testWorktreeExecutionStartsAlongsideActiveDirectWorkspaceTask() async throws {
        let worktreeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexboard-worktree-test-\(UUID().uuidString)", isDirectory: true)
        let fixture = try Fixture(
            autoRunDefault: true,
            isGitRepository: true,
            worktreeManager: StubWorktreeManager(root: worktreeRoot)
        )
        defer { fixture.cleanup() }
        fixture.store.updatePreferences { $0.maxConcurrentExecutions = 4 }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }

        let directTaskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Direct workspace",
            sourceKind: .issue,
            sourceText: "Change the main checkout",
            autoRun: true,
            workspaceKind: .project
        )
        try await eventually { fixture.client.planningTurnCount == 1 }

        let worktreeTaskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Isolated workspace",
            sourceKind: .issue,
            sourceText: "Change an isolated checkout",
            autoRun: true,
            workspaceKind: .worktree
        )
        try await eventually { fixture.client.planningTurnCount == 2 }

        fixture.client.send(.planFinal(
            threadID: "thread-1",
            turnID: "plan-1",
            text: "Direct plan"
        ))
        fixture.client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "plan-1",
            status: "completed",
            error: nil
        ))
        try await eventually {
            fixture.client.executionTurnCount == 1
                && fixture.store.tasks.first(where: { $0.id == directTaskID })?.stage == .executing
        }

        fixture.client.send(.planFinal(
            threadID: "thread-2",
            turnID: "plan-2",
            text: "Worktree plan"
        ))
        fixture.client.send(.turnCompleted(
            threadID: "thread-2",
            turnID: "plan-2",
            status: "completed",
            error: nil
        ))

        try await eventually {
            fixture.client.executionTurnCount == 2
                && fixture.store.tasks.first(where: { $0.id == worktreeTaskID })?.stage == .executing
        }
        XCTAssertEqual(fixture.store.activeExecutionCount, 2)
        XCTAssertEqual(
            fixture.store.tasks.first(where: { $0.id == worktreeTaskID })?.workspace.kind,
            .worktree
        )
        XCTAssertEqual(fixture.client.executionCalls.map(\.cwd).first, fixture.projectPath)
        XCTAssertTrue(fixture.client.executionCalls.map(\.cwd).contains(where: {
            $0.hasPrefix(worktreeRoot.path)
        }))
    }

    func testChangingProjectClearsTaskSelectionFromPreviousProject() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Selected",
            sourceKind: .issue,
            sourceText: "Inspect selection",
            autoRun: false
        )
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
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Partial",
            sourceKind: .issue,
            sourceText: "Do not execute partial output",
            autoRun: false
        )
        await fixture.store.startPlanning(taskID: taskID)
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
        XCTAssertFalse(fixture.store.updatePlan(taskID: taskID, planText: "Invalid replacement"))
        XCTAssertFalse(fixture.store.moveTask(taskID: taskID, to: .awaitingApproval))
        XCTAssertEqual(fixture.client.executionTurnCount, 0)
    }

    func testConnectionLossReleasesActiveTasksToNeedsAttention() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Disconnect",
            sourceKind: .issue,
            sourceText: "Handle transport failure",
            autoRun: false
        )
        await fixture.store.startPlanning(taskID: taskID)
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

    func testConfigurationWarningIsLoggedWithoutBecomingTaskOrGlobalError() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Configuration warning",
            sourceKind: .issue,
            sourceText: "Keep planning",
            autoRun: false
        )
        await fixture.store.startPlanning(taskID: taskID)
        try await eventually { fixture.client.planningTurnCount == 1 }
        let originalLiveMessage = try XCTUnwrap(
            fixture.store.tasks.first(where: { $0.id == taskID })?.liveMessage
        )
        let message = "Skill descriptions were shortened to fit the skills context budget."

        fixture.client.send(.configurationWarning(threadID: nil, turnID: nil, message: message))
        fixture.client.send(.configurationWarning(
            threadID: "thread-1",
            turnID: "plan-1",
            message: message
        ))

        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.logs.contains(where: {
                $0.level == .warning && $0.message == message
            }) == true
        }
        let task = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(task.stage, .planning)
        XCTAssertEqual(task.liveMessage, originalLiveMessage)
        XCTAssertNil(task.lastError)
        XCTAssertNil(fixture.store.lastError)

        try await Task.sleep(for: .milliseconds(350))
        let persisted = try await BoardPersistence(
            fileURL: fixture.directory.appendingPathComponent("board.json")
        ).load()
        XCTAssertTrue(persisted.tasks.first(where: { $0.id == taskID })?.logs.contains(where: {
            $0.level == .warning && $0.message == message
        }) == true)
        XCTAssertNil(persisted.tasks.first(where: { $0.id == taskID })?.lastError)
    }

    func testRuntimeWarningStillBecomesTaskError() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Runtime warning",
            sourceKind: .issue,
            sourceText: "Surface warning",
            autoRun: false
        )
        await fixture.store.startPlanning(taskID: taskID)
        try await eventually { fixture.client.planningTurnCount == 1 }

        fixture.client.send(.warning(
            threadID: "thread-1",
            turnID: "plan-1",
            message: "Approval was declined."
        ))

        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.lastError == "Approval was declined."
        }
        XCTAssertEqual(
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage,
            .planning
        )
    }

    func testRunningTasksPrioritizeExecutionAndCanBeFocused() async throws {
        let fixture = try Fixture(autoRunDefault: true)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }

        let executingID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Executing task",
            sourceKind: .issue,
            sourceText: "Execute this task",
            autoRun: true
        )
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

        let planningID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Planning task",
            sourceKind: .developmentPlan,
            sourceText: "Plan this task",
            autoRun: false
        )
        await fixture.store.startPlanning(taskID: planningID)
        try await eventually { fixture.client.planningTurnCount == 2 }

        XCTAssertEqual(fixture.store.runningTaskCount, 2)
        XCTAssertEqual(fixture.store.runningTasks.map(\.id), [executingID, planningID])
        XCTAssertEqual(fixture.store.projectName(for: fixture.store.runningTasks[0]), fixture.directory.lastPathComponent)

        fixture.store.focusTask(executingID)
        XCTAssertEqual(fixture.store.selectedProjectID, fixture.projectPath)
        XCTAssertEqual(fixture.store.selectedTaskID, executingID)
    }

    func testAttachmentOnlyTaskSendsTextThenLocalImage() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let pngData = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z4i0AAAAASUVORK5CYII="
        ))

        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "",
            sourceKind: .issue,
            sourceText: "",
            attachmentDrafts: [TaskAttachmentDraft(
                displayName: "Screenshot.png",
                byteCount: Int64(pngData.count),
                source: .pastedImage(pngData)
            )],
            autoRun: false
        )

        await fixture.store.startPlanning(taskID: taskID)
        try await eventually { fixture.client.planningInputs.count == 1 }
        let task = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(task.title, "Screenshot.png")
        XCTAssertEqual(task.attachments.count, 1)
        XCTAssertTrue(task.attachments[0].isManaged)
        XCTAssertEqual(fixture.client.planningInputs[0].count, 2)
        guard case .text = fixture.client.planningInputs[0][0] else {
            return XCTFail("Text prompt must be first")
        }
        XCTAssertEqual(
            fixture.client.planningInputs[0][1],
            .localImage(path: task.attachments[0].path)
        )

        fixture.client.send(.planFinal(
            threadID: "thread-1",
            turnID: "plan-1",
            text: "Inspect the screenshot"
        ))
        fixture.client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "plan-1",
            status: "completed",
            error: nil
        ))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .awaitingApproval
        }
        fixture.store.confirmPlan(taskID: taskID)
        try await eventually { fixture.client.executionInputs.count == 1 }
        XCTAssertEqual(
            fixture.client.executionInputs[0][1],
            .localImage(path: task.attachments[0].path)
        )

        fixture.client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "execute-1",
            status: "completed",
            error: nil
        ))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .review
        }
        fixture.store.acceptReview(taskID: taskID)
        XCTAssertEqual(fixture.store.tasks.first(where: { $0.id == taskID })?.stage, .completed)
        fixture.store.deleteTask(taskID: taskID)
        try await eventually { !FileManager.default.fileExists(atPath: task.attachments[0].path) }
    }

    func testExecutionCompletionCreatesReviewRunAndStructuredEvidence() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Reviewable delivery",
            sourceKind: .issue,
            sourceText: "Implement and verify the change",
            autoRun: false
        )

        await fixture.store.startPlanning(taskID: taskID)
        try await eventually { fixture.client.planningTurnCount == 1 }
        fixture.client.send(.planFinal(
            threadID: "thread-1",
            turnID: "plan-1",
            text: "Implement the change and run tests"
        ))
        fixture.client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "plan-1",
            status: "completed",
            error: nil
        ))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .awaitingApproval
        }
        fixture.store.confirmPlan(taskID: taskID)
        try await eventually { fixture.client.executionTurnCount == 1 }

        let result = """
        Implemented the requested behavior and verified it.

        ```codexboard-evidence
        {
          "summary": "Implemented review workflow",
          "changedFiles": ["Sources/Feature.swift", "Tests/FeatureTests.swift"],
          "verificationCommands": ["swift test"],
          "testSummary": "12 tests passed",
          "commitSHA": null,
          "pullRequestURL": null,
          "residualRisks": ["UI still needs manual inspection"]
        }
        ```
        """
        fixture.client.send(.agentFinal(threadID: "thread-1", turnID: "execute-1", text: result))
        fixture.client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "execute-1",
            status: "completed",
            error: nil
        ))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .review
        }

        var task = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(task.runs.count, 2)
        XCTAssertEqual(task.runs[0].phase, .planning)
        XCTAssertEqual(task.runs[0].outcome, .completed)
        XCTAssertEqual(task.runs[1].phase, .execution)
        XCTAssertEqual(task.runs[1].outcome, .awaitingReview)
        XCTAssertEqual(task.runs[1].attempt, 1)
        XCTAssertEqual(task.latestDeliveryEvidence?.changedFiles, [
            "Sources/Feature.swift",
            "Tests/FeatureTests.swift"
        ])
        XCTAssertEqual(task.latestDeliveryEvidence?.verificationCommands, ["swift test"])
        XCTAssertEqual(task.latestDeliveryEvidence?.testSummary, "12 tests passed")

        fixture.store.acceptReview(taskID: taskID)
        task = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(task.stage, .completed)
        XCTAssertEqual(task.latestExecutionRun?.outcome, .accepted)
        XCTAssertNotNil(task.latestExecutionRun?.reviewedAt)
    }

    func testObservedRunTelemetryMergesLifecycleAndReplacesPerThreadUsage() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Observed telemetry",
            sourceKind: .issue,
            sourceText: "Preserve exact sub-agent and token observations",
            autoRun: false
        )

        await fixture.store.startPlanning(taskID: taskID)
        try await eventually { fixture.client.planningTurnCount == 1 }
        let activity = CodexSubAgentActivity(
            id: "activity-1",
            agentThreadID: "child-1",
            agentPath: "/root/child-1",
            kind: "futureActivityKind"
        )
        fixture.client.send(.subAgentActivity(
            threadID: "thread-1",
            turnID: "plan-1",
            lifecycle: .completed(atMilliseconds: 120_000),
            activity: activity
        ))
        fixture.client.send(.subAgentActivity(
            threadID: "thread-1",
            turnID: "plan-1",
            lifecycle: .started(atMilliseconds: 100_000),
            activity: activity
        ))
        fixture.client.send(.tokenUsageUpdated(
            threadID: "thread-1",
            turnID: "plan-1",
            usage: observedUsage(totalTokens: 200, lastTokens: 20)
        ))
        fixture.client.send(.tokenUsageUpdated(
            threadID: "thread-1",
            turnID: "plan-1",
            usage: observedUsage(totalTokens: 240, lastTokens: 24)
        ))
        fixture.client.send(.tokenUsageUpdated(
            threadID: "child-1",
            turnID: "child-turn-1",
            usage: observedUsage(totalTokens: 80, lastTokens: 8)
        ))
        fixture.client.send(.tokenUsageUpdated(
            threadID: "unknown-thread",
            turnID: "unknown-turn",
            usage: observedUsage(totalTokens: 999, lastTokens: 999)
        ))
        fixture.client.send(.tokenUsageUpdated(
            threadID: "thread-1",
            turnID: "wrong-root-turn",
            usage: observedUsage(totalTokens: 999, lastTokens: 999)
        ))
        fixture.client.send(.subAgentActivity(
            threadID: "thread-1",
            turnID: "wrong-root-turn",
            lifecycle: .started(atMilliseconds: 130_000),
            activity: CodexSubAgentActivity(
                id: "stale-activity",
                agentThreadID: "stale-child",
                agentPath: "/root/stale-child",
                kind: "stale"
            )
        ))

        try await eventually {
            let telemetry = fixture.store.tasks.first(where: { $0.id == taskID })?
                .runs.first?.telemetry
            return telemetry?.agentActivities.count == 1
                && telemetry?.tokenUsageByThread.count == 1
                && telemetry?.tokenUsageByThread.first(where: {
                    $0.threadID == "thread-1"
                })?.total.totalTokens == 240
        }

        let task = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        let telemetry = try XCTUnwrap(task.runs.first?.telemetry)
        let recordedActivity = try XCTUnwrap(telemetry.agentActivities.first)
        XCTAssertEqual(recordedActivity.kind, "futureActivityKind")
        XCTAssertEqual(recordedActivity.agentPath, "/root/child-1")
        XCTAssertEqual(recordedActivity.startedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(recordedActivity.completedAt, Date(timeIntervalSince1970: 120))
        XCTAssertEqual(
            telemetry.tokenUsageByThread.first(where: { $0.threadID == "thread-1" })?.last.totalTokens,
            24
        )
        XCTAssertNil(telemetry.tokenUsageByThread.first(where: { $0.threadID == "child-1" }))
        XCTAssertFalse(
            task.runs.first?.multiAgentDrain?.knownThreadIDs.contains("stale-child") == true
        )
        let card = try XCTUnwrap(fixture.store.taskCards.first(where: { $0.id == taskID }))
        XCTAssertEqual(card.latestAgentActivityKind, "futureActivityKind")
        XCTAssertEqual(card.latestAgentPath, "/root/child-1")
        XCTAssertEqual(card.rootThreadTotalTokens, 240)
    }

    func testTurnDiffReplacesSnapshotAndRemainsOnCompletedExecutionRun() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Diff delivery",
            sourceKind: .issue,
            sourceText: "Implement a code change",
            autoRun: false
        )

        await fixture.store.startPlanning(taskID: taskID)
        try await eventually { fixture.client.planningTurnCount == 1 }
        fixture.client.send(.planFinal(
            threadID: "thread-1",
            turnID: "plan-1",
            text: "Implement and test the code change"
        ))
        fixture.client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "plan-1",
            status: "completed",
            error: nil
        ))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .awaitingApproval
        }
        fixture.store.confirmPlan(taskID: taskID)
        try await eventually { fixture.client.executionTurnCount == 1 }

        let firstSnapshot = """
        diff --git a/Sources/Feature.swift b/Sources/Feature.swift
        --- a/Sources/Feature.swift
        +++ b/Sources/Feature.swift
        @@ -1 +1 @@
        -let enabled = false
        +let enabled = true
        """
        let latestSnapshot = firstSnapshot + "\n+let delivered = true"
        fixture.client.send(.turnDiffUpdated(
            threadID: "thread-1",
            turnID: "execute-1",
            diff: firstSnapshot
        ))
        fixture.client.send(.turnDiffUpdated(
            threadID: "thread-1",
            turnID: "execute-1",
            diff: latestSnapshot
        ))

        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?
                .latestCodeDelivery?.unifiedDiff == latestSnapshot
        }
        XCTAssertFalse(
            fixture.store.tasks.first(where: { $0.id == taskID })?
                .latestCodeDelivery?.unifiedDiff.contains(firstSnapshot + firstSnapshot) == true
        )

        fixture.client.send(.agentFinal(
            threadID: "thread-1",
            turnID: "execute-1",
            text: """
            Implemented the code delivery.

            ```codexboard-evidence
            {
              "summary": "Implemented the code delivery",
              "changedFiles": ["Sources/Feature.swift"],
              "artifacts": [],
              "verificationCommands": ["swift test"],
              "testSummary": "Passed",
              "commitSHA": null,
              "pullRequestURL": null,
              "residualRisks": []
            }
            ```
            """
        ))
        fixture.client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "execute-1",
            status: "completed",
            error: nil
        ))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .review
        }

        let run = try XCTUnwrap(
            fixture.store.tasks.first(where: { $0.id == taskID })?.latestExecutionRun
        )
        XCTAssertEqual(run.codeDelivery?.unifiedDiff, latestSnapshot)
        XCTAssertEqual(run.evidence?.summary, "Implemented the code delivery")
    }

    func testRequestChangesStartsAnotherExecutionRunWithReviewFeedback() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Iterative review",
            sourceKind: .developmentPlan,
            sourceText: "Support review iterations",
            autoRun: false
        )

        await fixture.store.startPlanning(taskID: taskID)
        try await eventually { fixture.client.planningTurnCount == 1 }
        fixture.client.send(.planFinal(
            threadID: "thread-1",
            turnID: "plan-1",
            text: "Implement, review, and revise"
        ))
        fixture.client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "plan-1",
            status: "completed",
            error: nil
        ))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .awaitingApproval
        }
        fixture.store.confirmPlan(taskID: taskID)
        try await eventually { fixture.client.executionTurnCount == 1 }
        fixture.client.send(.agentFinal(
            threadID: "thread-1",
            turnID: "execute-1",
            text: "First implementation"
        ))
        fixture.client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "execute-1",
            status: "completed",
            error: nil
        ))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .review
        }

        XCTAssertTrue(fixture.store.requestChanges(
            taskID: taskID,
            feedback: "补充失败路径测试，并修复空值处理。"
        ))
        try await eventually { fixture.client.executionTurnCount == 2 }

        let promptInput = try XCTUnwrap(fixture.client.executionInputs.last?.first)
        guard case let .text(prompt) = promptInput else {
            return XCTFail("Execution prompt must be text")
        }
        XCTAssertTrue(prompt.contains("上一轮验收要求修改"))
        XCTAssertTrue(prompt.contains("补充失败路径测试，并修复空值处理。"))

        let task = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        let executionRuns = task.runs.filter { $0.phase == .execution }
        XCTAssertEqual(executionRuns.count, 2)
        XCTAssertEqual(executionRuns[0].outcome, .changesRequested)
        XCTAssertEqual(executionRuns[0].reviewNote, "补充失败路径测试，并修复空值处理。")
        XCTAssertEqual(executionRuns[1].outcome, .running)
        XCTAssertEqual(executionRuns[1].attempt, 2)
    }

    func testMissingPersistedAttachmentBlocksPlanning() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = BoardPersistence(fileURL: directory.appendingPathComponent("board.json"))
        let missingPath = directory.appendingPathComponent("missing.txt").path
        let task = BoardTask(
            projectID: directory.path,
            title: "Missing attachment",
            sourceKind: .issue,
            sourceText: "Inspect it",
            attachments: [TaskAttachment(
                kind: .file,
                displayName: "missing.txt",
                path: missingPath
            )],
            autoRun: false
        )
        try await persistence.save(BoardSnapshot(
            version: BoardSnapshot.currentVersion,
            tasks: [task],
            manualProjectPaths: [directory.path],
            preferences: BoardPreferences()
        ))
        let client = MockCodexTaskClient(projectPath: directory.path)
        let store = BoardStore(
            client: client,
            persistence: persistence,
            attachmentStorage: AttachmentStorage(rootDirectory: directory.appendingPathComponent("attachments"))
        )
        store.start()
        try await eventually { store.projects.contains(where: { $0.id == directory.path }) }

        await store.startPlanning(taskID: task.id)

        XCTAssertEqual(store.tasks.first?.stage, .needsAttention)
        XCTAssertTrue(store.tasks.first?.lastError?.contains("missing.txt") == true)
        XCTAssertEqual(client.planningTurnCount, 0)
    }

    func testReaddingManualProjectMovesItToTheFrontWithoutChangingSelection() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.selectedProjectID == fixture.projectPath }
        let first = fixture.directory.appendingPathComponent("FirstManual", isDirectory: true)
        let second = fixture.directory.appendingPathComponent("SecondManual", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        fixture.store.addManualProject(path: first.path)
        try await eventually { fixture.store.visibleProjects.first?.path == first.path }
        fixture.store.addManualProject(path: second.path)
        try await eventually { fixture.store.visibleProjects.first?.path == second.path }
        fixture.store.addManualProject(path: first.path)
        try await eventually {
            Array(fixture.store.visibleProjects.prefix(2).map(\.path)) == [first.path, second.path]
        }

        XCTAssertEqual(fixture.store.selectedProjectID, fixture.projectPath)
    }

    func testRefreshAddsNewGitProjectAndRemovedProjectStaysHiddenAfterReload() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstProject = directory.appendingPathComponent("FirstRepository", isDirectory: true)
        let secondProject = directory.appendingPathComponent("SecondRepository", isDirectory: true)
        for project in [firstProject, secondProject] {
            try FileManager.default.createDirectory(
                at: project.appendingPathComponent(".git", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let persistenceURL = directory.appendingPathComponent("board.json")
        let client = MockCodexTaskClient(projectPath: firstProject.path)
        let store = BoardStore(
            client: client,
            persistence: BoardPersistence(fileURL: persistenceURL),
            attachmentStorage: AttachmentStorage(
                rootDirectory: directory.appendingPathComponent("attachments")
            )
        )
        store.start()
        try await eventually { store.selectedProjectID == firstProject.path }

        client.historicalProjectPaths.append(secondProject.path)
        await store.refreshProjects()
        XCTAssertTrue(store.visibleProjects.contains(where: { $0.id == secondProject.path }))

        let taskID = try await store.createTask(
            projectID: firstProject.path,
            title: "Keep after hiding",
            sourceKind: .issue,
            sourceText: "This task must remain persisted",
            autoRun: false
        )
        store.selectedProjectID = firstProject.path
        let project = try XCTUnwrap(
            store.projects.first(where: { $0.id == firstProject.path })
        )
        store.removeProjectFromSidebar(project)

        XCTAssertFalse(store.visibleProjects.contains(where: { $0.id == firstProject.path }))
        XCTAssertEqual(store.selectedProjectID, secondProject.path)
        XCTAssertTrue(store.tasks.contains(where: { $0.id == taskID }))

        await store.refreshProjects()
        XCTAssertFalse(store.visibleProjects.contains(where: { $0.id == firstProject.path }))

        try await Task.sleep(for: .milliseconds(1_100))
        let snapshot = try await BoardPersistence(fileURL: persistenceURL).load()
        XCTAssertTrue(snapshot.hiddenProjectPaths.contains(firstProject.path))
        XCTAssertTrue(snapshot.tasks.contains(where: { $0.id == taskID }))

        let restoredClient = MockCodexTaskClient(projectPath: firstProject.path)
        restoredClient.historicalProjectPaths.append(secondProject.path)
        let restoredStore = BoardStore(
            client: restoredClient,
            persistence: BoardPersistence(fileURL: persistenceURL),
            attachmentStorage: AttachmentStorage(
                rootDirectory: directory.appendingPathComponent("restored-attachments")
            )
        )
        restoredStore.start()
        try await eventually {
            restoredStore.visibleProjects.contains(where: { $0.id == secondProject.path })
                && !restoredStore.visibleProjects.contains(where: { $0.id == firstProject.path })
        }

        restoredStore.addManualProject(path: firstProject.path)
        try await eventually {
            restoredStore.visibleProjects.contains(where: {
                $0.id == firstProject.path && $0.isManual
            })
        }
        XCTAssertTrue(restoredStore.tasks.contains(where: { $0.id == taskID }))
    }

    func testBurstStreamingUpdatesAreCoalescedAndPersistedAtMostTwicePerSecond() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockCodexTaskClient(projectPath: directory.path)
        let persistence = RecordingBoardPersistence(initialSnapshot: BoardSnapshot(
            version: BoardSnapshot.currentVersion,
            tasks: [],
            manualProjectPaths: [directory.path],
            preferences: BoardPreferences()
        ))
        let store = BoardStore(
            client: client,
            persistence: persistence,
            attachmentStorage: AttachmentStorage(rootDirectory: directory.appendingPathComponent("attachments"))
        )
        store.start()
        try await eventually { store.projects.contains(where: { $0.id == directory.path }) }
        let taskID = try await store.createTask(
            projectID: directory.path,
            title: "Streaming",
            sourceKind: .developmentPlan,
            sourceText: "Stream a long plan",
            autoRun: false
        )
        await store.startPlanning(taskID: taskID)
        try await eventually { client.planningTurnCount == 1 }
        try await Task.sleep(for: .seconds(1))
        let baselineSaveCount = await persistence.saveCount

        let deltas = (0..<100).map { "[\($0)]" }
        for (index, delta) in deltas.enumerated() {
            client.send(.agentDelta(
                threadID: "thread-1",
                turnID: "plan-1",
                delta: delta
            ))
            client.send(.activity(
                threadID: "thread-1",
                turnID: "plan-1",
                message: "Activity \(index)"
            ))
        }

        let expectedPlan = deltas.joined()
        try await eventually {
            store.tasks.first(where: { $0.id == taskID })?.planText == expectedPlan
        }
        XCTAssertEqual(
            store.tasks.first(where: { $0.id == taskID })?.liveMessage,
            "Activity 99"
        )
        try await Task.sleep(for: .seconds(1))

        let savesForBurst = await persistence.saveCount - baselineSaveCount
        XCTAssertGreaterThanOrEqual(savesForBurst, 1)
        XCTAssertLessThanOrEqual(savesForBurst, 2)
        let persistedPlan = await persistence.lastSnapshot?
            .tasks.first(where: { $0.id == taskID })?.planText
        XCTAssertEqual(
            persistedPlan,
            expectedPlan
        )
    }

    func testFinalAndConnectionEventsFlushPendingStreamingContent() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Flush barriers",
            sourceKind: .issue,
            sourceText: "Preserve pending content",
            autoRun: false
        )
        await fixture.store.startPlanning(taskID: taskID)
        try await eventually { fixture.client.planningTurnCount == 1 }

        fixture.client.send(.agentDelta(
            threadID: "thread-1",
            turnID: "plan-1",
            delta: "Pending draft"
        ))
        fixture.client.send(.connectionLost(message: "transport closed"))

        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .needsAttention
        }
        XCTAssertEqual(
            fixture.store.tasks.first(where: { $0.id == taskID })?.planText,
            "Pending draft"
        )
    }

    func testStreamingBuffersKeepConcurrentTasksIsolated() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let firstID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "First stream",
            sourceKind: .issue,
            sourceText: "First",
            autoRun: false
        )
        let secondID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Second stream",
            sourceKind: .issue,
            sourceText: "Second",
            autoRun: false
        )
        await fixture.store.startPlanning(taskID: firstID)
        await fixture.store.startPlanning(taskID: secondID)
        try await eventually { fixture.client.planningTurnCount == 2 }

        fixture.client.send(.agentDelta(
            threadID: "thread-1",
            turnID: "plan-1",
            delta: "First only"
        ))
        fixture.client.send(.agentDelta(
            threadID: "thread-2",
            turnID: "plan-2",
            delta: "Second only"
        ))
        fixture.client.send(.activity(
            threadID: "thread-1",
            turnID: "plan-1",
            message: "First activity"
        ))
        fixture.client.send(.activity(
            threadID: "thread-2",
            turnID: "plan-2",
            message: "Second activity"
        ))

        try await eventually {
            fixture.store.tasks.first(where: { $0.id == firstID })?.planText == "First only"
                && fixture.store.tasks.first(where: { $0.id == secondID })?.planText == "Second only"
        }
        XCTAssertEqual(
            fixture.store.tasks.first(where: { $0.id == firstID })?.liveMessage,
            "First activity"
        )
        XCTAssertEqual(
            fixture.store.tasks.first(where: { $0.id == secondID })?.liveMessage,
            "Second activity"
        )
    }

    func testStreamingTextDoesNotInvalidateUnrelatedInspectorOrThreeHundredCards() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selectedID = UUID()
        let existingTasks = (0..<299).map { index in
            BoardTask(
                id: index == 0 ? selectedID : UUID(),
                projectID: directory.path,
                title: "Existing \(index)",
                sourceKind: .issue,
                sourceText: "Existing task",
                stage: .completed,
                autoRun: false,
                planText: index == 0 ? String(repeating: "Long plan. ", count: 500) : "Done",
                hasFinalPlan: true,
                liveMessage: "已完成"
            )
        }
        let persistence = RecordingBoardPersistence(initialSnapshot: BoardSnapshot(
            version: BoardSnapshot.currentVersion,
            tasks: existingTasks,
            manualProjectPaths: [directory.path],
            preferences: BoardPreferences()
        ))
        let client = MockCodexTaskClient(projectPath: directory.path)
        let store = BoardStore(
            client: client,
            persistence: persistence,
            attachmentStorage: AttachmentStorage(rootDirectory: directory.appendingPathComponent("attachments"))
        )
        store.start()
        try await eventually { store.tasks.count == 299 && store.selectedProjectID == directory.path }

        let streamingID = try await store.createTask(
            projectID: directory.path,
            title: "Streaming",
            sourceKind: .developmentPlan,
            sourceText: "Stream without redrawing unrelated views",
            autoRun: false
        )
        await store.startPlanning(taskID: streamingID)
        try await eventually { client.planningTurnCount == 1 }
        store.selectedTaskID = selectedID
        let selectedBefore = try XCTUnwrap(store.selectedTask)
        let cardsBefore = store.taskCards

        client.send(.agentDelta(
            threadID: "thread-1",
            turnID: "plan-1",
            delta: "A streamed token"
        ))
        try await eventually {
            store.tasks.first(where: { $0.id == streamingID })?.planText == "A streamed token"
        }

        XCTAssertEqual(store.selectedTask, selectedBefore)
        XCTAssertEqual(store.taskCards, cardsBefore)
        XCTAssertEqual(store.taskCards.count, 300)
    }

    func testInteractionsRequireManualResponseStayTaskScopedAndClearOnDisconnect() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let automaticID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Automatic interaction",
            sourceKind: .issue,
            sourceText: "Wait for approval",
            autoRun: true
        )
        let manualID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Manual interaction",
            sourceKind: .issue,
            sourceText: "Wait for an answer",
            autoRun: false
        )
        await fixture.store.startPlanning(taskID: manualID)
        try await eventually { fixture.client.planningTurnCount == 2 }

        let approvalID = CodexRequestID.string("approval-1")
        let approval = CodexInteractionRequest(
            id: approvalID,
            threadID: "thread-1",
            turnID: "plan-1",
            itemID: nil,
            kind: .commandApproval(CodexCommandApproval(
                command: "git status",
                cwd: fixture.projectPath,
                reason: "Inspect repository",
                commandActions: nil,
                requestedPermissions: nil,
                networkApprovalContext: nil,
                proposedExecpolicyAmendment: nil,
                proposedNetworkPolicyAmendments: [],
                availableDecisions: [.accept, .decline]
            )),
            createdAt: Date()
        )
        let questionID = CodexRequestID.integer(42)
        let question = CodexInteractionRequest(
            id: questionID,
            threadID: "thread-2",
            turnID: "plan-2",
            itemID: nil,
            kind: .userInput(CodexUserInputRequest(questions: [], isBlocking: true)),
            createdAt: Date()
        )
        fixture.store.selectedProjectID = nil
        XCTAssertNil(fixture.store.selectedTaskID)

        fixture.client.send(.interactionRequested(approval))
        try await eventually {
            fixture.store.interactions(for: automaticID).count == 1
                && fixture.store.attentionNotices.count(where: {
                    $0.taskID == automaticID && $0.kind == .interaction
                }) == 1
                && fixture.store.taskFocusRequest?.taskID == automaticID
        }
        XCTAssertEqual(fixture.store.selectedProjectID, fixture.projectPath)
        XCTAssertEqual(fixture.store.selectedTaskID, automaticID)
        XCTAssertEqual(fixture.store.taskFocusRequest?.stage, .planning)
        let approvalNoticeID = try XCTUnwrap(
            fixture.store.attentionNotices.first(where: {
                $0.taskID == automaticID && $0.kind == .interaction
            })?.id
        )
        let approvalFocusNonce = try XCTUnwrap(fixture.store.taskFocusRequest?.nonce)

        fixture.client.send(.interactionRequested(approval))
        fixture.client.send(.activity(
            threadID: "thread-1",
            turnID: "plan-1",
            message: "Duplicate interaction processed"
        ))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == automaticID })?.liveMessage
                == "Duplicate interaction processed"
        }
        XCTAssertEqual(
            fixture.store.attentionNotices.filter {
                $0.taskID == automaticID && $0.kind == .interaction
            }.map(\.id),
            [approvalNoticeID]
        )
        XCTAssertEqual(fixture.store.taskFocusRequest?.nonce, approvalFocusNonce)

        fixture.store.focusTask(manualID)
        let manualFocusNonce = try XCTUnwrap(fixture.store.taskFocusRequest?.nonce)
        let secondApprovalID = CodexRequestID.string("approval-2")
        fixture.client.send(.interactionRequested(CodexInteractionRequest(
            id: secondApprovalID,
            threadID: "thread-1",
            turnID: "plan-1",
            itemID: "command-2",
            kind: .commandApproval(CodexCommandApproval(
                command: "git diff",
                cwd: fixture.projectPath,
                reason: "Inspect the pending change",
                commandActions: nil,
                requestedPermissions: nil,
                networkApprovalContext: nil,
                proposedExecpolicyAmendment: nil,
                proposedNetworkPolicyAmendments: [],
                availableDecisions: [.accept, .decline]
            )),
            createdAt: Date()
        )))
        try await eventually {
            fixture.store.interactions(for: automaticID).count == 2
                && fixture.store.attentionNotices.count(where: {
                    $0.taskID == automaticID && $0.kind == .interaction
                }) == 2
                && fixture.store.selectedTaskID == automaticID
                && fixture.store.taskFocusRequest?.nonce != manualFocusNonce
        }
        XCTAssertEqual(fixture.store.selectedTaskID, automaticID)
        XCTAssertEqual(fixture.store.taskFocusRequest?.taskID, automaticID)
        XCTAssertNotEqual(fixture.store.taskFocusRequest?.nonce, manualFocusNonce)

        fixture.client.send(.interactionRequested(question))
        try await eventually {
            fixture.store.interactions(for: automaticID).count == 2
                && fixture.store.interactions(for: manualID).count == 1
                && fixture.store.attentionNotices.count(where: { $0.kind == .interaction }) == 3
        }

        XCTAssertTrue(fixture.client.interactionResponses.isEmpty)
        XCTAssertEqual(fixture.store.interactions(for: automaticID).first?.id, approvalID)
        XCTAssertEqual(fixture.store.interactions(for: automaticID).last?.id, secondApprovalID)
        XCTAssertEqual(fixture.store.interactions(for: manualID).first?.id, questionID)
        XCTAssertTrue(fixture.store.hasPendingInteraction(for: automaticID))
        XCTAssertTrue(fixture.store.hasPendingInteraction(for: manualID))

        fixture.client.send(.connectionLost(message: "transport closed"))
        try await eventually {
            !fixture.store.hasPendingInteraction(for: automaticID)
                && !fixture.store.hasPendingInteraction(for: manualID)
        }
        XCTAssertFalse(fixture.store.attentionNotices.contains(where: { $0.kind == .interaction }))
        XCTAssertTrue(fixture.client.interactionResponses.isEmpty)
    }

    func testFocusAttentionTaskRejectsStaleNoticeAndRefreshesFocusForSelectedTask() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Focus notification",
            sourceKind: .issue,
            sourceText: "Focus this card again when the notification is clicked",
            autoRun: false
        )
        await fixture.store.startPlanning(taskID: taskID)
        try await eventually { fixture.client.planningTurnCount == 1 }
        let requestID = CodexRequestID.string("focus-notification")
        fixture.client.send(.interactionRequested(CodexInteractionRequest(
            id: requestID,
            threadID: "thread-1",
            turnID: "plan-1",
            itemID: nil,
            kind: .fileChangeApproval(CodexFileChangeApproval(
                reason: "Apply the requested change",
                grantRoot: fixture.projectPath
            )),
            createdAt: Date()
        )))
        try await eventually {
            fixture.store.attentionNotices.contains(where: {
                $0.taskID == taskID && $0.kind == .interaction
            })
        }

        let initialFocusNonce = try XCTUnwrap(fixture.store.taskFocusRequest?.nonce)
        XCTAssertTrue(fixture.store.focusAttentionTask(taskID))
        XCTAssertEqual(fixture.store.selectedProjectID, fixture.projectPath)
        XCTAssertEqual(fixture.store.selectedTaskID, taskID)
        XCTAssertEqual(fixture.store.taskFocusRequest?.taskID, taskID)
        XCTAssertNotEqual(fixture.store.taskFocusRequest?.nonce, initialFocusNonce)
        let refreshedFocusNonce = try XCTUnwrap(fixture.store.taskFocusRequest?.nonce)

        fixture.client.send(.interactionResolved(threadID: "thread-1", requestID: requestID))
        try await eventually {
            !fixture.store.attentionNotices.contains(where: {
                $0.taskID == taskID && $0.kind == .interaction
            })
        }
        XCTAssertFalse(fixture.store.focusAttentionTask(taskID))
        XCTAssertEqual(fixture.store.taskFocusRequest?.nonce, refreshedFocusNonce)
    }

    func testInteractionFailureKeepsRequestSuccessAndResolvedClearWithoutPersistingAnswers() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Sensitive answer",
            sourceKind: .issue,
            sourceText: "Ask before continuing",
            autoRun: false
        )
        await fixture.store.startPlanning(taskID: taskID)
        try await eventually { fixture.client.planningTurnCount == 1 }
        let requestID = CodexRequestID.string("question-secret")
        fixture.client.send(.interactionRequested(CodexInteractionRequest(
            id: requestID,
            threadID: "thread-1",
            turnID: "plan-1",
            itemID: nil,
            kind: .userInput(CodexUserInputRequest(questions: [], isBlocking: true)),
            createdAt: Date()
        )))
        try await eventually {
            fixture.store.hasPendingInteraction(for: taskID)
                && fixture.store.attentionNotices.contains(where: {
                    $0.taskID == taskID && $0.kind == .interaction
                })
        }
        let failedResponseNoticeID = try XCTUnwrap(
            fixture.store.attentionNotices.first(where: {
                $0.taskID == taskID && $0.kind == .interaction
            })?.id
        )

        fixture.client.interactionResponseFailures = [.interaction]
        let response = CodexInteractionResponse.userInput(["token": ["super-secret-answer"]])
        await fixture.store.respondToInteraction(
            taskID: taskID,
            requestID: requestID,
            response: response
        )
        XCTAssertTrue(fixture.store.hasPendingInteraction(for: taskID))
        XCTAssertTrue(fixture.store.tasks.first(where: { $0.id == taskID })?.lastError?.contains("交互响应失败") == true)
        XCTAssertEqual(
            fixture.store.attentionNotices.first(where: {
                $0.taskID == taskID && $0.kind == .interaction
            })?.id,
            failedResponseNoticeID
        )

        await fixture.store.respondToInteraction(
            taskID: taskID,
            requestID: requestID,
            response: response
        )
        XCTAssertFalse(fixture.store.hasPendingInteraction(for: taskID))
        XCTAssertFalse(fixture.store.attentionNotices.contains(where: {
            $0.taskID == taskID && $0.kind == .interaction
        }))
        XCTAssertEqual(fixture.client.interactionResponses.count, 1)

        let resolvedRequestID = CodexRequestID.string("resolved-by-server")
        fixture.client.send(.interactionRequested(CodexInteractionRequest(
            id: resolvedRequestID,
            threadID: "thread-1",
            turnID: "plan-1",
            itemID: nil,
            kind: .userInput(CodexUserInputRequest(questions: [], isBlocking: true)),
            createdAt: Date()
        )))
        try await eventually {
            fixture.store.interactions(for: taskID).contains(where: { $0.id == resolvedRequestID })
                && fixture.store.attentionNotices.contains(where: {
                    $0.taskID == taskID && $0.kind == .interaction
                })
        }
        fixture.client.send(.interactionResolved(threadID: "thread-1", requestID: resolvedRequestID))
        fixture.client.send(.interactionResolved(threadID: "thread-1", requestID: resolvedRequestID))
        try await eventually {
            !fixture.store.hasPendingInteraction(for: taskID)
                && !fixture.store.attentionNotices.contains(where: {
                    $0.taskID == taskID && $0.kind == .interaction
                })
        }
        try await Task.sleep(for: .milliseconds(900))

        let task = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        XCTAssertFalse(task.logs.contains { $0.message.contains("super-secret-answer") })
        let persistedText = String(
            decoding: try Data(contentsOf: fixture.directory.appendingPathComponent("board.json")),
            as: UTF8.self
        )
        XCTAssertFalse(persistedText.contains("super-secret-answer"))
        XCTAssertFalse(persistedText.contains("question-secret"))
    }

    func testCancelRejectsPendingServerInteractionsBeforeInterruptingTurn() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Cancel interaction",
            sourceKind: .issue,
            sourceText: "Cancel safely",
            autoRun: false
        )
        await fixture.store.startPlanning(taskID: taskID)
        try await eventually { fixture.client.planningTurnCount == 1 }
        let requestID = CodexRequestID.string("permission-1")
        fixture.client.send(.interactionRequested(CodexInteractionRequest(
            id: requestID,
            threadID: "thread-1",
            turnID: "plan-1",
            itemID: nil,
            kind: .permissionsApproval(CodexPermissionsApproval(
                cwd: fixture.projectPath,
                reason: "Need access",
                permissions: .object([:])
            )),
            createdAt: Date()
        )))
        try await eventually { fixture.store.hasPendingInteraction(for: taskID) }

        await fixture.store.cancel(taskID: taskID)

        XCTAssertFalse(fixture.store.hasPendingInteraction(for: taskID))
        XCTAssertEqual(fixture.client.interactionResponses.count, 1)
        XCTAssertEqual(fixture.client.interactionResponses.first?.requestID, requestID)
        XCTAssertEqual(
            fixture.client.interactionResponses.first?.response,
            .permissions(.deny(scope: .turn))
        )
    }

    func testCancelUsesAllowedDeclineAndKeepsRequestWhenResponseAndInterruptFail() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Retry cancellation",
            sourceKind: .issue,
            sourceText: "Keep the approval visible until cancellation succeeds",
            autoRun: false
        )
        await fixture.store.startPlanning(taskID: taskID)
        try await eventually { fixture.client.planningTurnCount == 1 }
        let requestID = CodexRequestID.string("command-decline-only")
        fixture.client.send(.interactionRequested(CodexInteractionRequest(
            id: requestID,
            threadID: "thread-1",
            turnID: "plan-1",
            itemID: "command-1",
            kind: .commandApproval(CodexCommandApproval(
                command: "git status",
                cwd: fixture.projectPath,
                reason: nil,
                commandActions: nil,
                requestedPermissions: nil,
                networkApprovalContext: nil,
                proposedExecpolicyAmendment: nil,
                proposedNetworkPolicyAmendments: [],
                availableDecisions: [.accept, .decline]
            )),
            createdAt: Date()
        )))
        try await eventually { fixture.store.hasPendingInteraction(for: taskID) }

        fixture.client.interactionResponseFailures = [.interaction]
        fixture.client.interruptFailures = [.interaction]
        await fixture.store.cancel(taskID: taskID)

        XCTAssertTrue(fixture.store.hasPendingInteraction(for: taskID))
        XCTAssertTrue(fixture.client.interactionResponses.isEmpty)
        XCTAssertEqual(fixture.client.interruptCalls.count, 1)

        await fixture.store.cancel(taskID: taskID)
        XCTAssertFalse(fixture.store.hasPendingInteraction(for: taskID))
        XCTAssertEqual(fixture.client.interactionResponses.count, 1)
        XCTAssertEqual(fixture.client.interactionResponses.first?.response, .approval(.decline))
        XCTAssertEqual(fixture.client.interruptCalls.count, 2)
    }

    func testCancelIntentPreventsAutoRunFromStartingExecutionDuringResponseRace() async throws {
        let fixture = try Fixture(autoRunDefault: true)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Cancel automatic planning",
            sourceKind: .issue,
            sourceText: "Never execute after stop is clicked",
            autoRun: true
        )
        try await eventually { fixture.client.planningTurnCount == 1 }
        let requestID = CodexRequestID.string("race-permission")
        fixture.client.send(.interactionRequested(CodexInteractionRequest(
            id: requestID,
            threadID: "thread-1",
            turnID: "plan-1",
            itemID: "permission-race",
            kind: .permissionsApproval(CodexPermissionsApproval(
                cwd: fixture.projectPath,
                reason: "Race fixture",
                permissions: .object([:])
            )),
            createdAt: Date()
        )))
        try await eventually { fixture.store.hasPendingInteraction(for: taskID) }
        fixture.client.interactionResponseDelayMilliseconds = 100

        let cancellation = Task { await fixture.store.cancel(taskID: taskID) }
        try await Task.sleep(for: .milliseconds(20))
        fixture.client.send(.planFinal(threadID: "thread-1", turnID: "plan-1", text: "Finished plan"))
        fixture.client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "plan-1",
            status: "completed",
            error: nil
        ))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .needsAttention
        }
        await cancellation.value

        XCTAssertEqual(fixture.client.executionTurnCount, 0)
        XCTAssertFalse(
            fixture.store.tasks.first(where: { $0.id == taskID })?.executionApproved ?? true
        )
    }

    func testCancelBeforeThreadStartReturnsPreventsPlanningTurn() async throws {
        let fixture = try Fixture(autoRunDefault: true)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        fixture.client.threadStartDelayMilliseconds = 100
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Cancel during thread start",
            sourceKind: .issue,
            sourceText: "Do not start a turn after stop",
            autoRun: true
        )
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .planning
                && fixture.client.threadStartCount == 1
        }

        await fixture.store.cancel(taskID: taskID)
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .needsAttention
        }

        XCTAssertEqual(fixture.client.planningTurnCount, 0)
        XCTAssertEqual(
            fixture.store.tasks.first(where: { $0.id == taskID })?.failureState?.kind,
            .interrupted
        )
    }

    func testMCPOAuthStateOpensOnlyFromUserActionAndRefreshesAfterCompletion() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let client = MockCodexTaskClient(projectPath: directory.path)
        client.mcpServerCatalog = [CodexMCPServerStatus(
            name: "example",
            authStatus: "notLoggedIn",
            title: "Example",
            description: "Fixture server",
            version: "1",
            websiteURL: nil,
            toolNames: ["lookup"]
        )]
        var openedURLs: [URL] = []
        let store = BoardStore(
            client: client,
            persistence: BoardPersistence(fileURL: directory.appendingPathComponent("board.json")),
            attachmentStorage: AttachmentStorage(rootDirectory: directory.appendingPathComponent("attachments")),
            externalURLOpener: { url in
                openedURLs.append(url)
                return true
            }
        )
        store.start()
        try await eventually { store.projects.contains(where: { $0.id == directory.path }) }
        await store.refreshMCPServers()
        XCTAssertEqual(store.mcpServers.map(\.name), ["example"])
        XCTAssertTrue(openedURLs.isEmpty)

        await store.beginMCPOAuth(serverName: "example")
        XCTAssertEqual(openedURLs, [client.oauthURL])
        XCTAssertTrue(store.oauthServersInProgress.contains("example"))
        XCTAssertEqual(client.oauthCalls.count, 1)
        client.send(.mcpOAuthCompleted(CodexMCPOAuthCompletion(
            serverName: "example",
            threadID: nil,
            success: true,
            error: nil
        )))
        try await eventually {
            !store.oauthServersInProgress.contains("example") && client.mcpServerListCount >= 2
        }
        XCTAssertNil(store.mcpServerError)

        await store.beginMCPOAuth(serverName: "example")
        client.send(.mcpOAuthCompleted(CodexMCPOAuthCompletion(
            serverName: "example",
            threadID: nil,
            success: false,
            error: "OAuth denied"
        )))
        try await eventually { store.mcpServerError == "OAuth denied" }
        XCTAssertFalse(store.oauthServersInProgress.contains("example"))
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
            },
            drainStabilityDelay: .milliseconds(10)
        )
        store.start()

        try await eventually { store.projects.count == 2 && store.connectedHostCount == 2 }
        let localProject = try XCTUnwrap(store.projects.first { $0.hostID == CodexHost.localID })
        let remoteProject = try XCTUnwrap(store.projects.first { $0.hostID == remoteHost.id })
        XCTAssertEqual(localProject.path, remoteProject.path)
        XCTAssertNotEqual(localProject.id, remoteProject.id)

        do {
            _ = try await store.createTask(
                projectID: remoteProject.id,
                title: "Remote attachment",
                sourceKind: .issue,
                sourceText: "Use a local file",
                attachmentDrafts: [.file(directory.appendingPathComponent("local-only.txt"))],
                autoRun: false
            )
            XCTFail("Remote tasks must reject local attachment drafts")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("上传到远程项目"))
        }
        do {
            _ = try await store.createTask(
                projectID: remoteProject.id,
                title: "Remote worktree",
                sourceKind: .issue,
                sourceText: "Do not create a local worktree",
                autoRun: false,
                workspaceKind: .worktree
            )
            XCTFail("Remote tasks must reject local worktree management")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("远程任务暂不支持"))
        }

        let localSkill = CodexSkillMetadata(
            name: "Local Skill",
            description: "Local only",
            shortDescription: nil,
            path: "/local/SKILL.md",
            scope: "user",
            enabled: true
        )
        let remoteSkill = CodexSkillMetadata(
            name: "Remote Skill",
            description: "Remote only",
            shortDescription: nil,
            path: "/remote/SKILL.md",
            scope: "user",
            enabled: true
        )
        localClient.skillsCatalog = [directory.path: [localSkill]]
        remoteClient.skillsCatalog = [directory.path: [remoteSkill]]
        await store.refreshCapabilities(projectID: remoteProject.id, forceRefresh: true)
        XCTAssertEqual(store.availableSkills, [remoteSkill])
        await store.refreshCapabilities(projectID: localProject.id, forceRefresh: true)
        XCTAssertEqual(store.availableSkills, [localSkill])

        let remoteTaskID = try await store.createTask(
            projectID: remoteProject.id,
            title: "Remote only",
            sourceKind: .issue,
            sourceText: "Run this on the build box",
            autoRun: false
        )
        await store.startPlanning(taskID: remoteTaskID)
        try await eventually { remoteClient.planningTurnCount == 1 }
        XCTAssertEqual(localClient.planningTurnCount, 0)
        XCTAssertEqual(store.tasks.first(where: { $0.id == remoteTaskID })?.hostID, remoteHost.id)
    }

    func testSwitchingHostsClearsCatalogsAndDropsDelayedModelResponse() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remoteHost = CodexHost(
            id: "ssh:model-worker",
            name: "Model Worker",
            kind: .ssh,
            sshAlias: "model-worker"
        )
        let remotePath = "/srv/model-project"
        let persistence = BoardPersistence(fileURL: directory.appendingPathComponent("board.json"))
        try await persistence.save(BoardSnapshot(
            tasks: [],
            hosts: [.local, remoteHost],
            manualProjects: [
                ManualProjectReference(path: directory.path),
                ManualProjectReference(hostID: remoteHost.id, path: remotePath)
            ],
            preferences: BoardPreferences()
        ))
        let localClient = MockCodexTaskClient(projectPath: directory.path)
        let remoteClient = MockCodexTaskClient(projectPath: remotePath)
        localClient.modelIDs = ["local-model"]
        remoteClient.modelIDs = ["remote-model"]
        let localSkill = CodexSkillMetadata(
            name: "Local Catalog",
            description: "Local skill",
            shortDescription: nil,
            path: "/local/catalog/SKILL.md",
            scope: "user",
            enabled: true
        )
        let remoteSkill = CodexSkillMetadata(
            name: "Remote Catalog",
            description: "Remote skill",
            shortDescription: nil,
            path: "/remote/catalog/SKILL.md",
            scope: "user",
            enabled: true
        )
        let localApp = CodexApp(
            id: "local-app",
            name: "Local App",
            invocationName: "local_app",
            description: "Local catalog app",
            isAccessible: true,
            isEnabled: true,
            isCallable: true,
            tools: []
        )
        let remoteApp = CodexApp(
            id: "remote-app",
            name: "Remote App",
            invocationName: "remote_app",
            description: "Remote catalog app",
            isAccessible: true,
            isEnabled: true,
            isCallable: true,
            tools: []
        )
        localClient.skillsCatalog = [directory.path: [localSkill]]
        remoteClient.skillsCatalog = [remotePath: [remoteSkill]]
        localClient.appsCatalog = [localApp]
        remoteClient.appsCatalog = [remoteApp]
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

        store.selectedProjectID = localProject.id
        try await eventually {
            store.availableModels.map(\.model) == ["local-model"]
                && store.availableSkills == [localSkill]
                && store.availableApps == [localApp]
        }

        let delayedModels = AsyncGate()
        localClient.listModelsGate = delayedModels
        let localModelCallCount = localClient.listModelsCallCount
        let staleRefresh = Task { @MainActor in
            await store.refreshModels(for: localProject.id)
        }
        try await eventually { localClient.listModelsCallCount > localModelCallCount }

        store.selectedProjectID = remoteProject.id
        XCTAssertTrue(store.availableModels.isEmpty)
        XCTAssertTrue(store.availableSkills.isEmpty)
        XCTAssertTrue(store.availableApps.isEmpty)
        try await eventually {
            store.availableModels.map(\.model) == ["remote-model"]
                && store.availableSkills == [remoteSkill]
                && store.availableApps == [remoteApp]
        }

        await delayedModels.open()
        await staleRefresh.value
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.availableModels.map(\.model), ["remote-model"])
        XCTAssertEqual(store.availableSkills, [remoteSkill])
        XCTAssertEqual(store.availableApps, [remoteApp])
    }

    func testRemovingRemoteProjectDoesNotResolveControllerSymlinks() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controllerRealPath = directory.appendingPathComponent("real", isDirectory: true)
        let controllerLinkPath = directory.appendingPathComponent("link", isDirectory: true)
        let linkedChildPath = controllerLinkPath.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(
            at: controllerRealPath.appendingPathComponent("child", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: controllerLinkPath,
            withDestinationURL: controllerRealPath
        )

        var localHost = CodexHost.local
        localHost.isEnabled = false
        let remoteHost = CodexHost(
            id: "ssh:path-worker",
            name: "Path Worker",
            kind: .ssh,
            sshAlias: "path-worker"
        )
        let persistence = BoardPersistence(fileURL: directory.appendingPathComponent("board.json"))
        try await persistence.save(BoardSnapshot(
            tasks: [],
            hosts: [localHost, remoteHost],
            manualProjects: [
                ManualProjectReference(hostID: remoteHost.id, path: controllerRealPath.path),
                ManualProjectReference(hostID: remoteHost.id, path: linkedChildPath.path)
            ],
            preferences: BoardPreferences()
        ))
        let localClient = MockCodexTaskClient(projectPath: directory.path)
        localClient.historicalProjectPaths = []
        let remoteClient = MockCodexTaskClient(projectPath: controllerRealPath.path)
        remoteClient.historicalProjectPaths = []
        let store = BoardStore(
            client: localClient,
            persistence: persistence,
            clientFactory: { host in
                host.id == remoteHost.id ? remoteClient : localClient
            }
        )
        store.start()
        try await eventually { store.projects.filter { $0.hostID == remoteHost.id }.count == 2 }

        let realProject = try XCTUnwrap(store.projects.first {
            $0.hostID == remoteHost.id && $0.path == controllerRealPath.path
        })
        store.removeProjectFromSidebar(realProject)
        await store.refreshProjects()

        XCTAssertTrue(store.visibleProjects.contains(where: {
            $0.hostID == remoteHost.id && $0.path == linkedChildPath.path && $0.isManual
        }))
        XCTAssertFalse(store.visibleProjects.contains(where: { $0.id == realProject.id }))
    }

    func testSameInteractionRequestIDIsIsolatedAcrossHostsAndDisconnect() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remoteHost = CodexHost(
            id: "ssh:interaction-worker",
            name: "Interaction Worker",
            kind: .ssh,
            sshAlias: "interaction-worker"
        )
        let remotePath = "/srv/interaction-project"
        let persistence = BoardPersistence(fileURL: directory.appendingPathComponent("board.json"))
        try await persistence.save(BoardSnapshot(
            tasks: [],
            hosts: [.local, remoteHost],
            manualProjects: [
                ManualProjectReference(path: directory.path),
                ManualProjectReference(hostID: remoteHost.id, path: remotePath)
            ],
            preferences: BoardPreferences()
        ))
        let localClient = MockCodexTaskClient(projectPath: directory.path)
        let remoteClient = MockCodexTaskClient(projectPath: remotePath)
        localClient.interactionResponseDelayMilliseconds = 250
        remoteClient.interactionResponseDelayMilliseconds = 250
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
        let localTaskID = try await store.createTask(
            projectID: localProject.id,
            title: "Local interaction",
            sourceKind: .issue,
            sourceText: "Ask locally",
            autoRun: false
        )
        let remoteTaskID = try await store.createTask(
            projectID: remoteProject.id,
            title: "Remote interaction",
            sourceKind: .issue,
            sourceText: "Ask remotely",
            autoRun: false
        )
        await store.startPlanning(taskID: localTaskID)
        await store.startPlanning(taskID: remoteTaskID)
        try await eventually {
            localClient.planningTurnCount == 1 && remoteClient.planningTurnCount == 1
        }

        let requestID = CodexRequestID.string("shared-request-id")
        let request = CodexInteractionRequest(
            id: requestID,
            threadID: "thread-1",
            turnID: "plan-1",
            itemID: nil,
            kind: .userInput(CodexUserInputRequest(questions: [], isBlocking: true)),
            createdAt: Date()
        )
        localClient.send(.interactionRequested(request))
        remoteClient.send(.interactionRequested(request))
        try await eventually {
            store.hasPendingInteraction(for: localTaskID)
                && store.hasPendingInteraction(for: remoteTaskID)
        }

        let response = CodexInteractionResponse.userInput([:])
        let localResponse = Task { @MainActor in
            await store.respondToInteraction(
                taskID: localTaskID,
                requestID: requestID,
                response: response
            )
        }
        try await eventually { store.isResponding(taskID: localTaskID, requestID: requestID) }
        let remoteResponse = Task { @MainActor in
            await store.respondToInteraction(
                taskID: remoteTaskID,
                requestID: requestID,
                response: response
            )
        }
        try await eventually {
            store.isResponding(taskID: localTaskID, requestID: requestID)
                && store.isResponding(taskID: remoteTaskID, requestID: requestID)
        }

        localClient.send(.connectionLost(message: "local transport closed"))
        await localResponse.value
        await remoteResponse.value
        XCTAssertEqual(localClient.interactionResponses.map(\.requestID), [requestID])
        XCTAssertEqual(remoteClient.interactionResponses.map(\.requestID), [requestID])
        XCTAssertFalse(store.hasPendingInteraction(for: localTaskID))
        XCTAssertFalse(store.hasPendingInteraction(for: remoteTaskID))
        XCTAssertEqual(store.tasks.first(where: { $0.id == localTaskID })?.stage, .needsAttention)
        XCTAssertEqual(store.tasks.first(where: { $0.id == remoteTaskID })?.stage, .planning)
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

        let localTaskID = try await store.createTask(
            projectID: localProject.id,
            title: "Local",
            sourceKind: .issue,
            sourceText: "Stay active",
            autoRun: false
        )
        let remoteTaskID = try await store.createTask(
            projectID: remoteProject.id,
            title: "Remote",
            sourceKind: .issue,
            sourceText: "Lose this connection",
            autoRun: false
        )
        await store.startPlanning(taskID: localTaskID)
        await store.startPlanning(taskID: remoteTaskID)
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

        let firstID = try await store.createTask(
            projectID: remoteProjects[0].id,
            title: "First remote project",
            sourceKind: .issue,
            sourceText: "First change",
            autoRun: true
        )
        let secondID = try await store.createTask(
            projectID: remoteProjects[1].id,
            title: "Second remote project",
            sourceKind: .issue,
            sourceText: "Second change",
            autoRun: true
        )
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
        XCTAssertEqual(store.tasks.first(where: { $0.id == firstID })?.stage, .review)
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
            manualProjects: [ManualProjectReference(path: directory.path)],
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
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Recover completed",
            sourceKind: .issue,
            sourceText: "Do not duplicate this change",
            autoRun: true
        )
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
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .review
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
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Recover running",
            sourceKind: .issue,
            sourceText: "Keep following the existing turn",
            autoRun: true
        )
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
        let closedTask = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        let closedRun = try XCTUnwrap(closedTask.runs.last(where: { $0.phase == .execution }))
        let executionRunID = closedRun.id
        XCTAssertEqual(closedRun.outcome, .failed)
        XCTAssertNotNil(closedRun.endedAt)
        XCTAssertNotNil(closedRun.error)
        XCTAssertEqual(closedRun.failure?.kind, .connection)
        XCTAssertEqual(closedTask.attention?.kind, .failure)
        XCTAssertEqual(closedTask.attention?.runID, executionRunID)

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
        let resumedTask = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        let executionRuns = resumedTask.runs.filter { $0.phase == .execution }
        XCTAssertEqual(executionRuns.count, 1)
        let resumedRun = try XCTUnwrap(executionRuns.first)
        XCTAssertEqual(resumedRun.id, executionRunID)
        XCTAssertEqual(resumedRun.outcome, .running)
        XCTAssertNil(resumedRun.endedAt)
        XCTAssertNil(resumedRun.error)
        XCTAssertNil(resumedRun.failure)
        XCTAssertNil(resumedTask.failureState)
        XCTAssertNil(resumedTask.attention)
        XCTAssertFalse(fixture.store.attentionNotices.contains(where: {
            $0.taskID == taskID && $0.kind == .failure
        }))
    }

    func testRootCompletionPersistsDrainAndWaitsForActiveChild() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Wait for child",
            sourceKind: .issue,
            sourceText: "Do not finish while a child is active",
            autoRun: false
        )
        await fixture.store.startPlanning(taskID: taskID)
        try await eventually { fixture.client.planningTurnCount == 1 }
        let activeTask = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        let rootThreadID = try XCTUnwrap(activeTask.threadID)
        let rootTurnID = try XCTUnwrap(activeTask.planningTurnID)
        let childThreadID = "thread-child-wait"
        let childTurnID = "turn-child-wait"
        let childSummary = makeThreadSummary(
            cwd: fixture.projectPath,
            threadID: childThreadID,
            statusType: "active",
            parentThreadID: rootThreadID
        )
        let listGate = AsyncGate()
        fixture.client.descendantThreadListGate = listGate
        fixture.client.descendantThreadSnapshots = [[childSummary]]
        fixture.client.threadDetails[rootThreadID] = makeThreadDetail(
            cwd: fixture.projectPath,
            threadID: rootThreadID,
            turnID: rootTurnID,
            status: "completed"
        )
        fixture.client.threadDetails[childThreadID] = makeThreadDetail(
            cwd: fixture.projectPath,
            threadID: childThreadID,
            turnID: childTurnID,
            status: "inProgress",
            parentThreadID: rootThreadID
        )

        fixture.client.send(.threadStarted(childSummary))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?
                .runs.last(where: { $0.phase == .planning })?
                .multiAgentDrain?.knownThreadIDs.contains(childThreadID) == true
        }
        fixture.client.send(.planFinal(
            threadID: rootThreadID,
            turnID: rootTurnID,
            text: "Wait for the child, then finish"
        ))
        fixture.client.send(.turnCompleted(
            threadID: rootThreadID,
            turnID: rootTurnID,
            status: "completed",
            error: nil
        ))
        try await eventually { fixture.client.descendantThreadCalls.count == 1 }

        let persisted = try await BoardPersistence(
            fileURL: fixture.directory.appendingPathComponent("board.json")
        ).load()
        let persistedTask = try XCTUnwrap(persisted.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(persistedTask.stage, .planning)
        XCTAssertEqual(
            persistedTask.runs.last(where: { $0.phase == .planning })?
                .multiAgentDrain?.rootTerminalStatus,
            "completed"
        )

        await listGate.open()
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?
                .runs.last(where: { $0.phase == .planning })?
                .multiAgentDrain?.activeTurns.contains(where: {
                    $0.threadID == childThreadID && $0.turnID == childTurnID
                }) == true
        }
        XCTAssertEqual(fixture.store.tasks.first(where: { $0.id == taskID })?.stage, .planning)

        fixture.client.threadDetails[childThreadID] = makeThreadDetail(
            cwd: fixture.projectPath,
            threadID: childThreadID,
            turnID: childTurnID,
            status: "completed",
            parentThreadID: rootThreadID
        )
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .awaitingApproval
        }
        let completedRun = try XCTUnwrap(
            fixture.store.tasks.first(where: { $0.id == taskID })?
                .runs.last(where: { $0.phase == .planning })
        )
        XCTAssertEqual(completedRun.multiAgentDrain?.phase, .drained)
        XCTAssertTrue(completedRun.multiAgentDrain?.knownThreadIDs.contains(childThreadID) == true)
        XCTAssertTrue(fixture.client.readThreadCalls.contains(childThreadID))
    }

    func testCancelDrainsDescendantsShallowFirstWithReadback() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Cancel agent tree",
            sourceKind: .issue,
            sourceText: "Stop every descendant safely",
            autoRun: false
        )
        await fixture.store.startPlanning(taskID: taskID)
        try await eventually { fixture.client.planningTurnCount == 1 }
        let activeTask = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        let rootThreadID = try XCTUnwrap(activeTask.threadID)
        let rootTurnID = try XCTUnwrap(activeTask.planningTurnID)
        let childThreadID = "thread-cancel-child"
        let childTurnID = "turn-cancel-child"
        let grandchildThreadID = "thread-cancel-grandchild"
        let grandchildTurnID = "turn-cancel-grandchild"
        let childSummary = makeThreadSummary(
            cwd: fixture.projectPath,
            threadID: childThreadID,
            statusType: "active",
            parentThreadID: rootThreadID
        )
        let grandchildSummary = makeThreadSummary(
            cwd: fixture.projectPath,
            threadID: grandchildThreadID,
            statusType: "active",
            parentThreadID: childThreadID
        )
        fixture.client.descendantThreadSnapshots = [[childSummary, grandchildSummary]]
        fixture.client.threadDetails[rootThreadID] = makeThreadDetail(
            cwd: fixture.projectPath,
            threadID: rootThreadID,
            turnID: rootTurnID,
            status: "inProgress"
        )
        fixture.client.threadDetails[childThreadID] = makeThreadDetail(
            cwd: fixture.projectPath,
            threadID: childThreadID,
            turnID: childTurnID,
            status: "inProgress",
            parentThreadID: rootThreadID
        )
        fixture.client.threadDetails[grandchildThreadID] = makeThreadDetail(
            cwd: fixture.projectPath,
            threadID: grandchildThreadID,
            turnID: grandchildTurnID,
            status: "inProgress",
            parentThreadID: childThreadID
        )
        fixture.client.send(.threadStarted(childSummary))
        fixture.client.send(.threadStarted(grandchildSummary))
        try await eventually {
            Set(fixture.store.tasks.first(where: { $0.id == taskID })?
                .runs.last(where: { $0.phase == .planning })?
                .multiAgentDrain?.knownThreadIDs ?? [])
                == Set([rootThreadID, childThreadID, grandchildThreadID])
        }

        let parentByThreadID = [
            childThreadID: rootThreadID,
            grandchildThreadID: childThreadID
        ]
        let turnByThreadID = [
            rootThreadID: rootTurnID,
            childThreadID: childTurnID,
            grandchildThreadID: grandchildTurnID
        ]
        fixture.client.interruptHook = { [weak client = fixture.client] threadID, _ in
            guard let client, let turnID = turnByThreadID[threadID] else { return }
            client.threadDetails[threadID] = self.makeThreadDetail(
                cwd: fixture.projectPath,
                threadID: threadID,
                turnID: turnID,
                status: "interrupted",
                parentThreadID: parentByThreadID[threadID]
            )
        }

        await fixture.store.cancel(taskID: taskID)
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .needsAttention
        }

        XCTAssertEqual(
            fixture.client.interruptCalls.map(\.threadID),
            [rootThreadID, childThreadID, grandchildThreadID]
        )
        for (threadID, turnID) in [
            (childThreadID, childTurnID),
            (grandchildThreadID, grandchildTurnID)
        ] {
            let interrupt = MockRemoteOperation.interrupt(threadID: threadID, turnID: turnID)
            let interruptIndex = try XCTUnwrap(
                fixture.client.remoteOperations.firstIndex(of: interrupt)
            )
            XCTAssertLessThan(interruptIndex + 1, fixture.client.remoteOperations.count)
            XCTAssertEqual(fixture.client.remoteOperations[interruptIndex + 1], .read(threadID))
        }
        let cancelledTask = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        let cancelledRun = try XCTUnwrap(
            cancelledTask.runs.last(where: { $0.phase == .planning })
        )
        XCTAssertEqual(cancelledRun.outcome, .interrupted)
        XCTAssertEqual(cancelledRun.multiAgentDrain?.phase, .drained)
        XCTAssertEqual(cancelledTask.failureState?.kind, .interrupted)
    }

    func testStartupResumesPersistedDrainWithoutStartingAnotherTurn() async throws {
        let fixture = try await persistedDrainFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        fixture.store.start()

        try await eventually {
            fixture.store.tasks.first(where: { $0.id == fixture.taskID })?.stage == .review
        }
        let task = try XCTUnwrap(
            fixture.store.tasks.first(where: { $0.id == fixture.taskID })
        )
        let run = try XCTUnwrap(task.runs.first(where: { $0.id == fixture.executionRunID }))
        XCTAssertEqual(run.outcome, .awaitingReview)
        XCTAssertEqual(run.multiAgentDrain?.phase, .drained)
        XCTAssertEqual(
            Set(run.multiAgentDrain?.knownThreadIDs ?? []),
            Set([fixture.rootThreadID, fixture.childThreadID])
        )
        XCTAssertEqual(fixture.client.resumeThreadCount, 0)
        XCTAssertEqual(fixture.client.executionTurnCount, 0)
        XCTAssertEqual(fixture.client.descendantThreadCalls.count, 2)
        XCTAssertEqual(fixture.client.readThreadCount, 4)
    }

    func testConnectionLossDuringDrainKeepsExecutionSlotOccupied() async throws {
        let fixture = try Fixture(autoRunDefault: true)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let firstTaskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Active drain",
            sourceKind: .issue,
            sourceText: "Keep the execution slot while disconnected",
            autoRun: true
        )
        try await eventually { fixture.client.planningTurnCount == 1 }
        fixture.client.send(.planFinal(
            threadID: "thread-1",
            turnID: "plan-1",
            text: "Execute while supervising descendants"
        ))
        fixture.client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "plan-1",
            status: "completed",
            error: nil
        ))
        try await eventually {
            fixture.client.executionTurnCount == 1
                && fixture.store.tasks.first(where: { $0.id == firstTaskID })?.stage == .executing
        }

        let secondTaskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Queued behind drain",
            sourceKind: .issue,
            sourceText: "Wait for the same project",
            autoRun: true
        )
        try await eventually { fixture.client.planningTurnCount == 2 }
        fixture.client.send(.planFinal(
            threadID: "thread-2",
            turnID: "plan-2",
            text: "Run after the first task"
        ))
        fixture.client.send(.turnCompleted(
            threadID: "thread-2",
            turnID: "plan-2",
            status: "completed",
            error: nil
        ))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == secondTaskID })?.stage == .awaitingApproval
                && fixture.store.tasks.first(where: { $0.id == secondTaskID })?.liveMessage
                    == "等待同项目的主目录任务结束"
        }

        let childSummary = makeThreadSummary(
            cwd: fixture.projectPath,
            threadID: "thread-disconnected-child",
            statusType: "active",
            parentThreadID: "thread-1"
        )
        fixture.client.send(.threadStarted(childSummary))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == firstTaskID })?
                .runs.last(where: { $0.phase == .execution })?
                .multiAgentDrain != nil
        }
        fixture.client.send(.connectionLost(message: "transport closed during drain"))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == firstTaskID })?
                .runs.last(where: { $0.phase == .execution })?
                .multiAgentDrain?.phase == .blocked
        }

        XCTAssertEqual(fixture.store.tasks.first(where: { $0.id == firstTaskID })?.stage, .executing)
        XCTAssertEqual(fixture.store.activeExecutionCount, 1)
        XCTAssertEqual(
            fixture.store.tasks.first(where: { $0.id == secondTaskID })?.stage,
            .awaitingApproval
        )
        XCTAssertEqual(fixture.client.executionTurnCount, 1)
        XCTAssertTrue(fixture.store.attentionNotices.contains(where: {
            $0.taskID == firstTaskID && $0.kind == .failure
        }))
    }

    func testStartupBlockedPlanningDrainDoesNotReserveExecutionSlot() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let observedAt = Date(timeIntervalSince1970: 10)
        let blockedThreadID = "thread-blocked-planning"
        let blockedTurnID = "turn-blocked-planning"
        let readyThreadID = "thread-ready-after-blocked"
        let blockedRun = TaskRun(
            phase: .planning,
            attempt: 1,
            startedAt: observedAt,
            outcome: .running,
            threadID: blockedThreadID,
            sessionID: "session-blocked-planning",
            turnID: blockedTurnID,
            model: "gpt-test",
            reasoningEffort: .medium,
            fastMode: false,
            multiAgentDrain: TaskRunDrainState(
                phase: .blocked,
                rootTerminalStatus: "completed",
                rootTerminalObservedAt: observedAt,
                knownThreadIDs: [blockedThreadID],
                consecutiveReconciliationFailureCount: 3,
                startedAt: observedAt,
                blockedReason: "Persisted reconciliation failure"
            )
        )
        let blockedTask = BoardTask(
            projectID: directory.path,
            title: "Blocked planning drain",
            sourceKind: .issue,
            sourceText: "Do not reserve execution capacity while blocked",
            stage: .planning,
            autoRun: true,
            createdAt: observedAt,
            updatedAt: observedAt,
            planText: "Blocked task plan",
            hasFinalPlan: true,
            threadID: blockedThreadID,
            sessionID: "session-blocked-planning",
            planningTurnID: blockedTurnID,
            runs: [blockedRun]
        )
        let readyTask = BoardTask(
            projectID: directory.path,
            title: "Approved after blocked drain",
            sourceKind: .issue,
            sourceText: "Start despite the blocked planning drain",
            stage: .awaitingApproval,
            autoRun: true,
            executionApproved: true,
            createdAt: observedAt.addingTimeInterval(1),
            updatedAt: observedAt.addingTimeInterval(1),
            planText: "Ready task plan",
            hasFinalPlan: true,
            threadID: readyThreadID,
            sessionID: "session-ready-after-blocked"
        )
        var preferences = BoardPreferences()
        preferences.maxConcurrentExecutions = 1
        let persistence = BoardPersistence(fileURL: directory.appendingPathComponent("board.json"))
        try await persistence.save(BoardSnapshot(
            tasks: [blockedTask, readyTask],
            hosts: [.local],
            manualProjects: [ManualProjectReference(path: directory.path)],
            preferences: preferences
        ))
        let client = MockCodexTaskClient(projectPath: directory.path)
        let drainGate = AsyncGate()
        client.descendantThreadListGate = drainGate
        client.descendantThreadSnapshots = [[], []]
        let store = BoardStore(
            client: client,
            persistence: persistence,
            drainStabilityDelay: .milliseconds(10)
        )

        store.start()

        try await eventually { client.executionTurnCount == 1 }
        XCTAssertEqual(client.executionCalls.first?.threadID, readyThreadID)
        XCTAssertEqual(
            store.tasks.first(where: { $0.id == readyTask.id })?.stage,
            .executing
        )
        XCTAssertEqual(
            store.tasks.first(where: { $0.id == blockedTask.id })?.stage,
            .planning
        )

        await drainGate.open()
        try await eventually {
            store.tasks.first(where: { $0.id == blockedTask.id })?.stage == .awaitingApproval
        }
    }

    func testCancellingPlanningDrainDoesNotReserveExecutionSlot() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        fixture.store.updatePreferences { $0.maxConcurrentExecutions = 1 }
        fixture.store.setHostConcurrency(id: CodexHost.localID, maximum: 1)
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let readyTaskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Approved during cancellation",
            sourceKind: .issue,
            sourceText: "Run after the older planning drain starts cancelling",
            autoRun: false
        )
        await fixture.store.startPlanning(taskID: readyTaskID)
        try await eventually { fixture.client.planningTurnCount == 1 }
        fixture.client.send(.planFinal(
            threadID: "thread-1",
            turnID: "plan-1",
            text: "Initial ready plan"
        ))
        fixture.client.send(.turnCompleted(
            threadID: "thread-1",
            turnID: "plan-1",
            status: "completed",
            error: nil
        ))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == readyTaskID })?.stage == .awaitingApproval
        }

        let cancellingTaskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Cancelling planning drain",
            sourceKind: .issue,
            sourceText: "Do not reserve capacity after cancellation is requested",
            autoRun: true
        )
        try await eventually { fixture.client.planningTurnCount == 2 }
        let drainGate = AsyncGate()
        let interruptGate = AsyncGate()
        fixture.client.descendantThreadListGate = drainGate
        fixture.client.interruptGate = interruptGate
        fixture.client.descendantThreadSnapshots = [[], []]
        fixture.client.threadDetails["thread-2"] = makeThreadDetail(
            cwd: fixture.projectPath,
            threadID: "thread-2",
            turnID: "plan-2",
            status: "interrupted"
        )
        fixture.client.send(.planFinal(
            threadID: "thread-2",
            turnID: "plan-2",
            text: "Plan that must not reserve while cancelling"
        ))
        fixture.client.send(.turnCompleted(
            threadID: "thread-2",
            turnID: "plan-2",
            status: "completed",
            error: nil
        ))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == cancellingTaskID })?
                .runs.last(where: { $0.phase == .planning })?
                .multiAgentDrain?.phase == .draining
        }

        let cancellationTask = Task { @MainActor in
            await fixture.store.cancel(taskID: cancellingTaskID)
        }
        try await eventually {
            let drain = fixture.store.tasks.first(where: { $0.id == cancellingTaskID })?
                .runs.last(where: { $0.phase == .planning })?
                .multiAgentDrain
            return drain?.phase == .cancelling && drain?.cancellationRequestedAt != nil
        }
        XCTAssertTrue(fixture.store.updatePlan(
            taskID: readyTaskID,
            planText: "Approved after cancellation request"
        ))
        fixture.store.confirmPlan(taskID: readyTaskID)

        try await eventually { fixture.client.executionTurnCount == 1 }
        XCTAssertEqual(fixture.client.executionCalls.first?.threadID, "thread-1")
        XCTAssertEqual(
            fixture.store.tasks.first(where: { $0.id == readyTaskID })?.stage,
            .executing
        )
        XCTAssertEqual(
            fixture.store.tasks.first(where: { $0.id == cancellingTaskID })?.stage,
            .planning
        )

        await interruptGate.open()
        await drainGate.open()
        await cancellationTask.value
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == cancellingTaskID })?.stage == .needsAttention
        }
    }

    func testLateDescendantAndDuplicateTerminalRequireNewStableFixedPoint() async throws {
        let fixture = try Fixture(autoRunDefault: false)
        defer { fixture.cleanup() }
        try await eventually { fixture.store.projects.contains(where: { $0.id == fixture.projectPath }) }
        let taskID = try await fixture.store.createTask(
            projectID: fixture.projectPath,
            title: "Late descendant",
            sourceKind: .issue,
            sourceText: "Require a new fixed point after a late spawn",
            autoRun: false
        )
        await fixture.store.startPlanning(taskID: taskID)
        try await eventually { fixture.client.planningTurnCount == 1 }
        let activeTask = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        let rootThreadID = try XCTUnwrap(activeTask.threadID)
        let rootTurnID = try XCTUnwrap(activeTask.planningTurnID)
        let childThreadID = "thread-late-child"
        let childTurnID = "turn-late-child"
        let grandchildThreadID = "thread-late-grandchild"
        let grandchildTurnID = "turn-late-grandchild"
        let childSummary = makeThreadSummary(
            cwd: fixture.projectPath,
            threadID: childThreadID,
            statusType: "idle",
            parentThreadID: rootThreadID
        )
        let grandchildSummary = makeThreadSummary(
            cwd: fixture.projectPath,
            threadID: grandchildThreadID,
            statusType: "idle",
            parentThreadID: childThreadID
        )
        fixture.client.descendantThreadSnapshots = [
            [childSummary],
            [childSummary, grandchildSummary],
            [childSummary, grandchildSummary]
        ]
        fixture.client.threadDetails[rootThreadID] = makeThreadDetail(
            cwd: fixture.projectPath,
            threadID: rootThreadID,
            turnID: rootTurnID,
            status: "completed"
        )
        fixture.client.threadDetails[childThreadID] = makeThreadDetail(
            cwd: fixture.projectPath,
            threadID: childThreadID,
            turnID: childTurnID,
            status: "completed",
            parentThreadID: rootThreadID
        )
        fixture.client.threadDetails[grandchildThreadID] = makeThreadDetail(
            cwd: fixture.projectPath,
            threadID: grandchildThreadID,
            turnID: grandchildTurnID,
            status: "completed",
            parentThreadID: childThreadID
        )
        fixture.client.send(.threadStarted(childSummary))
        fixture.client.send(.threadStarted(childSummary))
        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?
                .runs.last(where: { $0.phase == .planning })?
                .multiAgentDrain?.knownThreadIDs.contains(childThreadID) == true
        }
        fixture.client.send(.planFinal(
            threadID: rootThreadID,
            turnID: rootTurnID,
            text: "Wait for the stable descendant graph"
        ))
        fixture.client.send(.turnCompleted(
            threadID: rootThreadID,
            turnID: rootTurnID,
            status: "completed",
            error: nil
        ))
        fixture.client.send(.turnCompleted(
            threadID: rootThreadID,
            turnID: rootTurnID,
            status: "completed",
            error: nil
        ))

        try await eventually {
            fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .awaitingApproval
        }
        let task = try XCTUnwrap(fixture.store.tasks.first(where: { $0.id == taskID }))
        let run = try XCTUnwrap(task.runs.last(where: { $0.phase == .planning }))
        XCTAssertEqual(fixture.client.descendantThreadCalls.count, 3)
        XCTAssertEqual(run.outcome, .completed)
        XCTAssertEqual(run.multiAgentDrain?.phase, .drained)
        XCTAssertEqual(
            Set(run.multiAgentDrain?.knownThreadIDs ?? []),
            Set([rootThreadID, childThreadID, grandchildThreadID])
        )
        XCTAssertEqual(
            fixture.store.attentionNotices.count(where: {
                $0.taskID == taskID && $0.kind == .planApproval
            }),
            1
        )
    }

    private func makeThreadDetail(
        cwd: String,
        threadID: String = "thread-1",
        turnID: String,
        status: String,
        threadStatusType: String? = nil,
        parentThreadID: String? = nil,
        finalText: String? = nil
    ) -> CodexThreadDetail {
        let normalizedTurnStatus = status.lowercased().filter(\.isLetter)
        return CodexThreadDetail(
            summary: makeThreadSummary(
                cwd: cwd,
                threadID: threadID,
                statusType: threadStatusType
                    ?? (normalizedTurnStatus == "inprogress" ? "active" : "idle"),
                parentThreadID: parentThreadID
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

    private func makeThreadSummary(
        cwd: String,
        threadID: String,
        statusType: String,
        parentThreadID: String? = nil
    ) -> CodexThreadSummary {
        CodexThreadSummary(
            id: threadID,
            sessionID: "session-\(threadID)",
            cwd: cwd,
            name: "Fixture \(threadID)",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            isPinned: false,
            statusType: statusType,
            sourceKind: parentThreadID == nil ? "appServer" : "subAgent",
            parentThreadID: parentThreadID
        )
    }

    private func makeSpawnCall(
        id: String,
        senderThreadID: String,
        receiverThreadIDs: [String]
    ) -> CodexCollabAgentToolCall {
        CodexCollabAgentToolCall(
            id: id,
            tool: "spawnAgent",
            status: "completed",
            senderThreadID: senderThreadID,
            receiverThreadIDs: receiverThreadIDs,
            prompt: nil,
            model: nil,
            reasoningEffort: nil,
            agentStates: Dictionary(uniqueKeysWithValues: receiverThreadIDs.map {
                ($0, CodexCollabAgentState(status: "running", message: nil))
            })
        )
    }

    private func persistedDrainFixture() async throws -> (
        directory: URL,
        taskID: UUID,
        executionRunID: UUID,
        rootThreadID: String,
        childThreadID: String,
        client: MockCodexTaskClient,
        store: BoardStore
    ) {
        let directory = try temporaryDirectory()
        let rootThreadID = "thread-persisted-root"
        let childThreadID = "thread-persisted-child"
        let rootTurnID = "turn-persisted-root"
        let childTurnID = "turn-persisted-child"
        let executionRunID = UUID()
        let observedAt = Date(timeIntervalSince1970: 10)
        let drain = TaskRunDrainState(
            phase: .draining,
            rootTerminalStatus: "completed",
            rootTerminalObservedAt: observedAt,
            knownThreadIDs: [childThreadID, rootThreadID],
            parentByThreadID: [childThreadID: rootThreadID],
            startedAt: observedAt
        )
        let run = TaskRun(
            id: executionRunID,
            phase: .execution,
            attempt: 1,
            outcome: .running,
            threadID: rootThreadID,
            sessionID: "session-persisted-root",
            turnID: rootTurnID,
            model: "gpt-test",
            reasoningEffort: .medium,
            fastMode: false,
            multiAgentDrain: drain
        )
        let task = BoardTask(
            projectID: directory.path,
            title: "Persisted multi-agent drain",
            sourceKind: .issue,
            sourceText: "Resume drain without duplicating execution",
            stage: .executing,
            autoRun: true,
            executionApproved: true,
            planText: "Persisted plan",
            hasFinalPlan: true,
            resultText: "Recovered multi-agent delivery",
            threadID: rootThreadID,
            sessionID: "session-persisted-root",
            executionTurnID: rootTurnID,
            runs: [run]
        )
        let persistence = BoardPersistence(fileURL: directory.appendingPathComponent("board.json"))
        try await persistence.save(BoardSnapshot(
            tasks: [task],
            hosts: [.local],
            manualProjects: [ManualProjectReference(path: directory.path)],
            preferences: BoardPreferences()
        ))

        let client = MockCodexTaskClient(projectPath: directory.path)
        let childSummary = makeThreadSummary(
            cwd: directory.path,
            threadID: childThreadID,
            statusType: "idle",
            parentThreadID: rootThreadID
        )
        client.descendantThreadSnapshots = [[childSummary], [childSummary]]
        client.threadDetails[rootThreadID] = makeThreadDetail(
            cwd: directory.path,
            threadID: rootThreadID,
            turnID: rootTurnID,
            status: "completed"
        )
        client.threadDetails[childThreadID] = makeThreadDetail(
            cwd: directory.path,
            threadID: childThreadID,
            turnID: childTurnID,
            status: "completed",
            parentThreadID: rootThreadID
        )
        return (
            directory: directory,
            taskID: task.id,
            executionRunID: executionRunID,
            rootThreadID: rootThreadID,
            childThreadID: childThreadID,
            client: client,
            store: BoardStore(
                client: client,
                persistence: persistence,
                drainStabilityDelay: .milliseconds(10)
            )
        )
    }

    private func persistedExecutionFixture(
        status: String,
        finalText: String? = nil,
        includeClosedExecutionRun: Bool = false
    ) async throws -> (
        directory: URL,
        taskID: UUID,
        executionRunID: UUID,
        client: MockCodexTaskClient,
        store: BoardStore
    ) {
        let directory = try temporaryDirectory()
        let threadID = "thread-persisted"
        let turnID = "turn-persisted"
        let executionRunID = UUID()
        let executionRuns = includeClosedExecutionRun ? [TaskRun(
            id: executionRunID,
            phase: .execution,
            attempt: 1,
            endedAt: Date(),
            outcome: .failed,
            threadID: threadID,
            sessionID: "session-before-relaunch",
            turnID: turnID,
            model: "gpt-test",
            reasoningEffort: .medium,
            fastMode: false,
            summary: "Connection was lost",
            error: "Connection was lost"
        )] : []
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
            executionTurnID: turnID,
            runs: executionRuns
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
            executionRunID: executionRunID,
            client: client,
            store: BoardStore(
                client: client,
                persistence: persistence,
                drainStabilityDelay: .milliseconds(10)
            )
        )
    }

    private func eventually(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Condition was not met before timeout", file: file, line: line)
    }

    private func observedUsage(
        totalTokens: Int64,
        lastTokens: Int64
    ) -> CodexThreadTokenUsage {
        CodexThreadTokenUsage(
            total: CodexTokenUsageBreakdown(
                totalTokens: totalTokens,
                inputTokens: totalTokens - 20,
                cachedInputTokens: 10,
                cacheWriteInputTokens: 2,
                outputTokens: 15,
                reasoningOutputTokens: 5
            ),
            last: CodexTokenUsageBreakdown(
                totalTokens: lastTokens,
                inputTokens: max(0, lastTokens - 4),
                cachedInputTokens: 2,
                cacheWriteInputTokens: 0,
                outputTokens: 3,
                reasoningOutputTokens: 1
            ),
            modelContextWindow: 200_000
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func runGit(_ arguments: [String]) throws {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                decoding: error.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw NSError(
                domain: "BoardStoreWorkflowTests.Git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}

private actor RecordingBoardPersistence: BoardPersisting {
    private let initialSnapshot: BoardSnapshot
    private(set) var saveCount = 0
    private(set) var lastSnapshot: BoardSnapshot?

    init(initialSnapshot: BoardSnapshot = .empty) {
        self.initialSnapshot = initialSnapshot
    }

    func load() -> BoardSnapshot { initialSnapshot }

    func save(_ snapshot: BoardSnapshot) {
        saveCount += 1
        lastSnapshot = snapshot
    }
}

private struct MockThreadStartCall {
    let cwd: String
    let model: String?
    let serviceTier: String
}

private struct MockTurnCall {
    let threadID: String
    let cwd: String
    let model: String
    let effort: ReasoningEffort
    let serviceTier: String
    let allowNetwork: Bool?
}

private enum MockClientError: LocalizedError {
    case authentication
    case startup
    case interaction

    var errorDescription: String? {
        switch self {
        case .authentication: "401 Unauthorized: Missing bearer authentication"
        case .startup: "Temporary process startup failure"
        case .interaction: "Interaction response failed"
        }
    }
}

private actor StubWorktreeManager: WorktreeManaging {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    func prepare(
        taskID: UUID,
        projectPath: String,
        configuration: TaskWorkspaceConfiguration
    ) async throws -> TaskWorkspaceConfiguration {
        guard configuration.kind == .worktree else { return .project }
        return TaskWorkspaceConfiguration(
            kind: .worktree,
            path: root.appendingPathComponent(taskID.uuidString, isDirectory: true).path,
            branch: "codex/task-\(taskID.uuidString.prefix(8).lowercased())",
            baseBranch: "main"
        )
    }

    func status(configuration: TaskWorkspaceConfiguration) async throws -> WorktreeStatus {
        WorktreeStatus(isClean: true, changes: [])
    }

    func cleanup(
        projectPath: String,
        configuration: TaskWorkspaceConfiguration
    ) async throws -> TaskWorkspaceConfiguration {
        TaskWorkspaceConfiguration(kind: configuration.kind)
    }
}

private enum MockRemoteOperation: Equatable {
    case listDescendants(String)
    case read(String)
    case interrupt(threadID: String, turnID: String)
}

@MainActor
private final class MockCodexTaskClient: CodexTaskClient {
    var connectionState: CodexConnectionState = .connected
    private let continuation: AsyncStream<CodexEvent>.Continuation
    let events: AsyncStream<CodexEvent>
    let projectPath: String
    var historicalProjectPaths: [String]
    var planningTurnCount = 0
    var executionTurnCount = 0
    var threadStartCount = 0
    var threadStartDelayMilliseconds = 0
    var planningTurnDelayMilliseconds = 0
    var threadStartFailures: [CodexClientError] = []
    var planningInputs: [[CodexTurnInput]] = []
    var executionInputs: [[CodexTurnInput]] = []
    var threadStartCalls: [MockThreadStartCall] = []
    var planningCalls: [MockTurnCall] = []
    var executionCalls: [MockTurnCall] = []
    var planningFailures: [MockClientError] = []
    var modelIDs = ["gpt-test"]
    var listModelsCallCount = 0
    var listModelsGate: AsyncGate?
    var skillsCatalog: [String: [CodexSkillMetadata]] = [:]
    var appsCatalog: [CodexApp] = []
    var appListThreadIDs: [String?] = []
    var mcpServerCatalog: [CodexMCPServerStatus] = []
    var mcpServerListCount = 0
    var oauthURL = URL(string: "https://example.test/oauth")!
    var oauthCalls: [(serverName: String, threadID: String?)] = []
    var interactionResponses: [(requestID: CodexRequestID, response: CodexInteractionResponse)] = []
    var interactionResponseFailures: [MockClientError] = []
    var interactionResponseDelayMilliseconds = 0
    var interruptCalls: [(threadID: String, turnID: String)] = []
    var interruptFailures: [MockClientError] = []
    var interruptGate: AsyncGate?
    var interruptHook: ((String, String) -> Void)?
    private var modelsByThreadID: [String: String] = [:]
    var disconnectCount = 0
    var listThreadsCallCount = 0
    var descendantThreadCalls: [String] = []
    var descendantThreadSnapshots: [[CodexThreadSummary]] = []
    var descendantThreadFailures: [CodexClientError] = []
    var descendantThreadListGate: AsyncGate?
    var readThreadCount = 0
    var readThreadCalls: [String] = []
    var readThreadGate: AsyncGate?
    var remoteOperations: [MockRemoteOperation] = []
    var resumeThreadCount = 0
    var planningTurnError: Error?
    var listThreadsGate: AsyncGate?
    var threadDetails: [String: CodexThreadDetail] = [:]
    var threadDetailScripts: [String: [CodexThreadDetail]] = [:]

    init(projectPath: String) {
        self.projectPath = projectPath
        historicalProjectPaths = [projectPath]
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
    func listModels() async throws -> [CodexModel] {
        listModelsCallCount += 1
        if let listModelsGate {
            await listModelsGate.wait()
        }
        return modelIDs.enumerated().map { index, modelID in
            CodexModel(
                id: modelID,
                model: modelID,
                displayName: modelID,
                description: "Mock model",
                isDefault: index == 0,
                defaultReasoningEffort: .medium,
                supportedReasoningEfforts: ReasoningEffort.standardCases.map {
                    CodexReasoningEffortOption(effort: $0, description: $0.rawValue)
                },
                serviceTiers: [CodexModelServiceTier(
                    id: "priority",
                    name: "Fast",
                    description: "Mock priority tier"
                )]
            )
        }
    }
    func listSkills(cwds: [String], forceReload: Bool) async throws -> [String: [CodexSkillMetadata]] {
        skillsCatalog
    }
    func listApps(forceRefresh: Bool) async throws -> [CodexApp] {
        appsCatalog
    }
    func listApps(forceRefresh: Bool, threadID: String?) async throws -> [CodexApp] {
        appListThreadIDs.append(threadID)
        return appsCatalog
    }
    func listMCPServers(threadID: String?) async throws -> [CodexMCPServerStatus] {
        mcpServerListCount += 1
        return mcpServerCatalog
    }
    func beginMCPOAuth(serverName: String, threadID: String?) async throws -> URL {
        oauthCalls.append((serverName, threadID))
        return oauthURL
    }
    func respond(to requestID: CodexRequestID, with response: CodexInteractionResponse) async throws {
        if interactionResponseDelayMilliseconds > 0 {
            try await Task.sleep(for: .milliseconds(interactionResponseDelayMilliseconds))
        }
        if !interactionResponseFailures.isEmpty {
            throw interactionResponseFailures.removeFirst()
        }
        interactionResponses.append((requestID, response))
    }
    func listThreads(cursor: String?, archived: Bool) async throws -> CodexThreadPage {
        listThreadsCallCount += 1
        if let listThreadsGate {
            await listThreadsGate.wait()
        }
        return CodexThreadPage(
            threads: historicalProjectPaths.enumerated().map { index, path in
                CodexThreadSummary(
                    id: "history-\(index)",
                    sessionID: "history-session-\(index)",
                    cwd: path,
                    name: "Fixture",
                    createdAt: Date(),
                    updatedAt: Date(),
                    isPinned: false,
                    statusType: "idle",
                    sourceKind: "appServer"
                )
            },
            nextCursor: nil
        )
    }
    func listDescendantThreads(ancestorThreadID: String) async throws -> [CodexThreadSummary] {
        descendantThreadCalls.append(ancestorThreadID)
        remoteOperations.append(.listDescendants(ancestorThreadID))
        if let descendantThreadListGate {
            await descendantThreadListGate.wait()
        }
        if !descendantThreadFailures.isEmpty {
            throw descendantThreadFailures.removeFirst()
        }
        if !descendantThreadSnapshots.isEmpty {
            return descendantThreadSnapshots.removeFirst()
        }
        return []
    }
    func readThread(threadID: String, includeTurns: Bool) async throws -> CodexThreadDetail {
        readThreadCount += 1
        readThreadCalls.append(threadID)
        remoteOperations.append(.read(threadID))
        if let readThreadGate {
            await readThreadGate.wait()
        }
        if var scripted = threadDetailScripts[threadID], !scripted.isEmpty {
            let detail = scripted.removeFirst()
            threadDetailScripts[threadID] = scripted
            return detail
        }
        guard let detail = threadDetails[threadID] else {
            throw CodexClientError.invalidResponse("Missing mock thread detail")
        }
        return detail
    }
    func startThread(
        cwd: String,
        model: String?,
        serviceTier: String
    ) async throws -> CodexStartedThread {
        threadStartCount += 1
        if threadStartDelayMilliseconds > 0 {
            try await Task.sleep(for: .milliseconds(threadStartDelayMilliseconds))
        }
        threadStartCalls.append(MockThreadStartCall(
            cwd: cwd,
            model: model,
            serviceTier: serviceTier
        ))
        if !threadStartFailures.isEmpty {
            throw threadStartFailures.removeFirst()
        }
        let threadID = "thread-\(threadStartCount)"
        let resolvedModel = model ?? "gpt-test"
        modelsByThreadID[threadID] = resolvedModel
        return CodexStartedThread(
            threadID: threadID,
            sessionID: "session-\(threadStartCount)",
            model: resolvedModel,
            cwd: cwd
        )
    }
    func resumeThread(threadID: String, cwd: String) async throws -> CodexStartedThread {
        resumeThreadCount += 1
        return CodexStartedThread(
            threadID: threadID,
            sessionID: "session-1",
            model: modelsByThreadID[threadID] ?? "gpt-test",
            cwd: cwd
        )
    }
    func setThreadName(threadID: String, name: String) async throws {}
    func startPlanningTurn(
        threadID: String,
        cwd: String,
        input: [CodexTurnInput],
        model: String,
        effort: ReasoningEffort,
        serviceTier: String
    ) async throws -> CodexStartedTurn {
        planningTurnCount += 1
        planningInputs.append(input)
        planningCalls.append(MockTurnCall(
            threadID: threadID,
            cwd: cwd,
            model: model,
            effort: effort,
            serviceTier: serviceTier,
            allowNetwork: nil
        ))
        if planningTurnDelayMilliseconds > 0 {
            try await Task.sleep(for: .milliseconds(planningTurnDelayMilliseconds))
        }
        if let planningTurnError { throw planningTurnError }
        if !planningFailures.isEmpty {
            throw planningFailures.removeFirst()
        }
        return CodexStartedTurn(turnID: "plan-\(planningTurnCount)", status: "inProgress")
    }
    func startExecutionTurn(
        threadID: String,
        cwd: String,
        input: [CodexTurnInput],
        model: String,
        effort: ReasoningEffort,
        serviceTier: String,
        allowNetwork: Bool
    ) async throws -> CodexStartedTurn {
        executionTurnCount += 1
        executionInputs.append(input)
        executionCalls.append(MockTurnCall(
            threadID: threadID,
            cwd: cwd,
            model: model,
            effort: effort,
            serviceTier: serviceTier,
            allowNetwork: allowNetwork
        ))
        return CodexStartedTurn(turnID: "execute-\(executionTurnCount)", status: "inProgress")
    }
    func interrupt(threadID: String, turnID: String) async throws {
        interruptCalls.append((threadID, turnID))
        remoteOperations.append(.interrupt(threadID: threadID, turnID: turnID))
        if let interruptGate {
            await interruptGate.wait()
        }
        if !interruptFailures.isEmpty {
            throw interruptFailures.removeFirst()
        }
        interruptHook?(threadID, turnID)
    }
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

    init(
        autoRunDefault: Bool,
        isGitRepository: Bool = false,
        worktreeManager: any WorktreeManaging = WorktreeManager()
    ) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if isGitRepository {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", directory.path, "init", "-b", "main"]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        projectPath = directory.path
        client = MockCodexTaskClient(projectPath: projectPath)
        var preferences = BoardPreferences()
        preferences.defaultAutoRun = autoRunDefault
        let snapshot = BoardSnapshot(
            version: BoardSnapshot.currentVersion,
            tasks: [],
            manualProjectPaths: [projectPath],
            preferences: preferences
        )
        let persistenceURL = directory.appendingPathComponent("board.json")
        try JSONEncoder().encode(snapshot).write(to: persistenceURL)
        let persistence = BoardPersistence(fileURL: persistenceURL)
        store = BoardStore(
            client: client,
            persistence: persistence,
            attachmentStorage: AttachmentStorage(rootDirectory: directory.appendingPathComponent("attachments")),
            worktreeManager: worktreeManager,
            drainStabilityDelay: .milliseconds(10)
        )
        store.start()
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
