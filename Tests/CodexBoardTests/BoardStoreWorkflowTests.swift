import XCTest
@testable import CodexBoard

@MainActor
final class BoardStoreWorkflowTests: XCTestCase {
    func testManualPlanCompletionWaitsForConfirmation() async throws {
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

        try await eventually { fixture.client.planningTurnCount == 1 }
        fixture.client.send(.planFinal(threadID: "thread-1", turnID: "plan-1", text: "1. Inspect\n2. Fix"))
        fixture.client.send(.turnCompleted(threadID: "thread-1", turnID: "plan-1", status: "completed", error: nil))
        try await eventually { fixture.store.tasks.first(where: { $0.id == taskID })?.stage == .awaitingApproval }

        XCTAssertEqual(fixture.client.executionTurnCount, 0)
        fixture.store.confirmPlan(taskID: taskID)
        try await eventually { fixture.client.executionTurnCount == 1 }
        XCTAssertEqual(fixture.store.tasks.first(where: { $0.id == taskID })?.stage, .executing)
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

        XCTAssertTrue(fixture.store.updatePlan(
            taskID: secondID,
            planText: "Revised second plan"
        ))
        XCTAssertFalse(try XCTUnwrap(
            fixture.store.tasks.first(where: { $0.id == secondID })?.executionApproved
        ))

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

    func testBurstStreamingUpdatesAreCoalescedAndPersistedAtMostTwicePerSecond() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockCodexTaskClient(projectPath: directory.path)
        let persistence = RecordingBoardPersistence()
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

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

@MainActor
private final class MockCodexTaskClient: CodexTaskClient {
    var connectionState: CodexConnectionState = .connected
    private let continuation: AsyncStream<CodexEvent>.Continuation
    let events: AsyncStream<CodexEvent>
    let projectPath: String
    var planningTurnCount = 0
    var executionTurnCount = 0
    var threadStartCount = 0
    var planningInputs: [[CodexTurnInput]] = []
    var executionInputs: [[CodexTurnInput]] = []
    var threadStartCalls: [MockThreadStartCall] = []
    var planningCalls: [MockTurnCall] = []
    var executionCalls: [MockTurnCall] = []
    private var modelsByThreadID: [String: String] = [:]

    init(projectPath: String) {
        self.projectPath = projectPath
        var captured: AsyncStream<CodexEvent>.Continuation!
        events = AsyncStream { captured = $0 }
        continuation = captured
    }

    func send(_ event: CodexEvent) { continuation.yield(event) }
    func connect() async throws {}
    func verifyAccount() async throws -> Bool { true }
    func listModels() async throws -> [CodexModel] {
        [CodexModel(
            id: "gpt-test",
            model: "gpt-test",
            displayName: "GPT Test",
            description: "Mock model",
            isDefault: true,
            defaultReasoningEffort: .medium,
            supportedReasoningEfforts: ReasoningEffort.standardCases.map {
                CodexReasoningEffortOption(effort: $0, description: $0.rawValue)
            },
            serviceTiers: [CodexModelServiceTier(
                id: "priority",
                name: "Fast",
                description: "Mock priority tier"
            )]
        )]
    }
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
    func startThread(
        cwd: String,
        model: String?,
        serviceTier: String
    ) async throws -> CodexStartedThread {
        threadStartCount += 1
        threadStartCalls.append(MockThreadStartCall(
            cwd: cwd,
            model: model,
            serviceTier: serviceTier
        ))
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
        CodexStartedThread(
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
        store = BoardStore(
            client: client,
            persistence: persistence,
            attachmentStorage: AttachmentStorage(rootDirectory: directory.appendingPathComponent("attachments"))
        )
        store.start()
        store.updatePreferences { $0.defaultAutoRun = autoRunDefault }
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
