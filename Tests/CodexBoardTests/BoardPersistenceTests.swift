import Foundation
import XCTest
@testable import CodexBoard

final class BoardPersistenceTests: XCTestCase {
    func testRoundTripPreservesSnapshot() async throws {
        let fixture = try TemporaryBoardFixture()
        defer { fixture.remove() }

        var preferences = BoardPreferences()
        preferences.defaultAutoRun = true
        preferences.modelOverride = "gpt-test"
        preferences.planningEffort = .high
        preferences.executionEffort = .xhigh
        preferences.maxConcurrentExecutions = 3
        preferences.allowNetworkAccess = false
        preferences.showMissingProjects = true

        let task = BoardTask(
            id: UUID(uuidString: "A642B184-BAD1-4989-9F75-53066FBECE20")!,
            projectID: "project-1",
            title: "持久化测试",
            sourceKind: .developmentPlan,
            sourceText: "保存并重新加载",
            attachments: [TaskAttachment(
                id: UUID(uuidString: "CE85D72C-5346-48C8-BEED-99586AD6DE53")!,
                kind: .image,
                displayName: "screen.png",
                path: "/tmp/screen.png",
                byteCount: 128,
                isManaged: true
            )],
            selectedSkills: [TaskSkillSelection(
                name: "test-skill",
                description: "Test workflow",
                path: "/tmp/project/.agents/skills/test-skill/SKILL.md",
                scope: "repo"
            )],
            selectedApps: [TaskAppSelection(
                id: "connector_readonly",
                name: "Read-only Connector",
                invocationName: "readonly",
                description: "Reads external context",
                requiresApproval: true
            )],
            stage: .awaitingApproval,
            autoRun: true,
            createdAt: Date(timeIntervalSinceReferenceDate: 123_456),
            updatedAt: Date(timeIntervalSinceReferenceDate: 123_789),
            planText: "1. 保存\n2. 加载",
            structuredPlan: [CodexPlanStep(step: "保存", status: .completed)],
            resultText: "完成",
            liveMessage: "",
            threadID: "thread-1",
            sessionID: "session-1",
            planningTurnID: "planning-turn",
            executionTurnID: "execution-turn",
            requestedModel: "gpt-selected",
            reasoningEffort: .max,
            fastMode: true,
            actualModel: "gpt-actual",
            lastError: nil,
            logs: [
                TaskLogEntry(
                    id: UUID(uuidString: "266FD6FD-986A-4892-A43D-7C79CF0530A9")!,
                    date: Date(timeIntervalSinceReferenceDate: 123_800),
                    level: .success,
                    message: "已保存"
                )
            ],
            runs: [TaskRun(
                id: UUID(uuidString: "14455CE6-3C0A-47BB-A2A7-B5A7D71853C9")!,
                phase: .execution,
                attempt: 1,
                startedAt: Date(timeIntervalSinceReferenceDate: 123_700),
                endedAt: Date(timeIntervalSinceReferenceDate: 123_780),
                outcome: .awaitingReview,
                threadID: "thread-1",
                sessionID: "session-1",
                turnID: "execution-turn",
                model: "gpt-actual",
                reasoningEffort: .max,
                fastMode: true,
                summary: "Implemented persistence",
                evidence: TaskDeliveryEvidence(
                    summary: "Implemented persistence",
                    changedFiles: ["Sources/Persistence.swift"],
                    artifacts: [TaskDeliveryArtifact(
                        title: "Migration report",
                        path: "reports/migration.pdf",
                        kind: "document"
                    )],
                    verificationCommands: ["swift test"],
                    testSummary: "All tests passed",
                    residualRisks: ["Manual UI review pending"]
                ),
                codeDelivery: TaskCodeDelivery(
                    unifiedDiff: "diff --git a/a.swift b/a.swift\n-old\n+new"
                )
            )],
            reviewFeedback: "Add one migration test",
            workspace: TaskWorkspaceConfiguration(
                kind: .worktree,
                path: "/tmp/worktree",
                branch: "codex/persistence",
                baseBranch: "main"
            )
        )
        let expected = BoardSnapshot(
            version: 7,
            tasks: [task],
            manualProjectPaths: ["/tmp/最新项目", "/tmp/示例项目"],
            preferences: preferences
        )

        let persistence = BoardPersistence(fileURL: fixture.fileURL)
        try await persistence.save(expected)
        let actual = try await persistence.load()

        XCTAssertEqual(actual.version, expected.version)
        XCTAssertEqual(actual.tasks, expected.tasks)
        XCTAssertEqual(actual.manualProjectPaths, expected.manualProjectPaths)
        XCTAssertEqual(actual.preferences, expected.preferences)
        XCTAssertEqual(actual.tasks.first?.requestedModel, "gpt-selected")
        XCTAssertEqual(actual.tasks.first?.reasoningEffort, .max)
        XCTAssertEqual(actual.tasks.first?.fastMode, true)
        XCTAssertEqual(actual.tasks.first?.actualModel, "gpt-actual")
        XCTAssertEqual(actual.tasks.first?.selectedSkills, task.selectedSkills)
        XCTAssertEqual(actual.tasks.first?.selectedApps, task.selectedApps)
        XCTAssertEqual(actual.tasks.first?.selectedApps.first?.requiresApproval, true)
        XCTAssertEqual(actual.tasks.first?.runs, task.runs)
        XCTAssertEqual(actual.tasks.first?.reviewFeedback, "Add one migration test")
        XCTAssertEqual(actual.tasks.first?.workspace, task.workspace)
    }

    func testLegacyTaskAppSelectionDefaultsRequiresApprovalToFalse() throws {
        let data = Data("""
        {
          "id": "connector_legacy",
          "name": "Legacy Connector",
          "invocationName": "legacy",
          "description": "Saved before approval semantics"
        }
        """.utf8)

        let selection = try JSONDecoder().decode(TaskAppSelection.self, from: data)

        XCTAssertFalse(selection.requiresApproval)
    }

    func testLegacyTaskRunWithoutCodeDeliveryDecodesAsNil() throws {
        let data = Data("""
        {
          "id": "14455CE6-3C0A-47BB-A2A7-B5A7D71853C9",
          "phase": "execution",
          "attempt": 1,
          "startedAt": 0,
          "outcome": "completed",
          "reasoningEffort": "high",
          "fastMode": false,
          "summary": "Legacy run"
        }
        """.utf8)

        let run = try JSONDecoder().decode(TaskRun.self, from: data)

        XCTAssertNil(run.codeDelivery)
        XCTAssertNil(run.evidence)
    }

    func testCodeDeliveryDefaultsMissingTruncationFlag() throws {
        let delivery = try JSONDecoder().decode(
            TaskCodeDelivery.self,
            from: Data("{\"unifiedDiff\":\"patch\"}".utf8)
        )

        XCTAssertEqual(delivery.unifiedDiff, "patch")
        XCTAssertFalse(delivery.isTruncated)
    }

    func testSaveUsesPrivateDirectoryAndFilePermissions() async throws {
        let fixture = try TemporaryBoardFixture()
        defer { fixture.remove() }

        let persistence = BoardPersistence(fileURL: fixture.fileURL)
        try await persistence.save(.empty)

        XCTAssertEqual(try permissions(at: fixture.storageDirectory), 0o700)
        XCTAssertEqual(try permissions(at: fixture.fileURL), 0o600)
    }

    func testCorruptFileIsReportedAndNeverOverwritten() async throws {
        let fixture = try TemporaryBoardFixture()
        defer { fixture.remove() }

        try FileManager.default.createDirectory(
            at: fixture.storageDirectory,
            withIntermediateDirectories: true
        )
        let corruptData = Data("{ definitely-not-json".utf8)
        try corruptData.write(to: fixture.fileURL)

        let persistence = BoardPersistence(fileURL: fixture.fileURL)

        do {
            _ = try await persistence.load()
            XCTFail("Expected loading corrupt JSON to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("已损坏"))
            XCTAssertTrue(error.localizedDescription.contains("未覆盖"))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), corruptData)

        do {
            try await persistence.save(.empty)
            XCTFail("Expected saving over corrupt JSON to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("已损坏"))
            XCTAssertTrue(error.localizedDescription.contains("未覆盖"))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), corruptData)
    }

    func testLegacyTaskDefaultsNewConfigurationAndMapsOldModel() async throws {
        let fixture = try TemporaryBoardFixture()
        defer { fixture.remove() }
        let task = BoardTask(
            projectID: "/tmp/project",
            title: "Legacy task",
            sourceKind: .issue,
            sourceText: "Old board data",
            autoRun: false
        )
        let snapshot = BoardSnapshot(
            version: 1,
            tasks: [task],
            manualProjectPaths: [],
            preferences: BoardPreferences()
        )
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var tasks = try XCTUnwrap(object["tasks"] as? [[String: Any]])
        tasks[0].removeValue(forKey: "attachments")
        tasks[0].removeValue(forKey: "selectedSkills")
        tasks[0].removeValue(forKey: "selectedApps")
        tasks[0].removeValue(forKey: "requestedModel")
        tasks[0].removeValue(forKey: "reasoningEffort")
        tasks[0].removeValue(forKey: "fastMode")
        tasks[0].removeValue(forKey: "actualModel")
        tasks[0].removeValue(forKey: "runs")
        tasks[0].removeValue(forKey: "reviewFeedback")
        tasks[0].removeValue(forKey: "workspace")
        tasks[0]["model"] = "gpt-legacy"
        object["tasks"] = tasks
        try FileManager.default.createDirectory(
            at: fixture.storageDirectory,
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: object).write(to: fixture.fileURL)

        let persistence = BoardPersistence(fileURL: fixture.fileURL)
        var loaded = try await persistence.load()

        XCTAssertEqual(loaded.version, 1)
        XCTAssertEqual(loaded.tasks.first?.attachments, [])
        XCTAssertEqual(loaded.tasks.first?.selectedSkills, [])
        XCTAssertEqual(loaded.tasks.first?.selectedApps, [])
        XCTAssertEqual(loaded.tasks.first?.requestedModel, "gpt-legacy")
        XCTAssertEqual(loaded.tasks.first?.reasoningEffort, .medium)
        XCTAssertEqual(loaded.tasks.first?.fastMode, false)
        XCTAssertEqual(loaded.tasks.first?.actualModel, "gpt-legacy")
        XCTAssertEqual(loaded.tasks.first?.runs, [])
        XCTAssertNil(loaded.tasks.first?.reviewFeedback)
        XCTAssertEqual(loaded.tasks.first?.workspace, .project)
        loaded.version = BoardSnapshot.currentVersion
        try await persistence.save(loaded)
        let reloaded = try await persistence.load()
        XCTAssertEqual(reloaded.version, BoardSnapshot.currentVersion)
    }

    func testLegacyApprovedTaskPreservesExecutionEffort() async throws {
        let fixture = try TemporaryBoardFixture()
        defer { fixture.remove() }

        var preferences = BoardPreferences()
        preferences.planningEffort = .low
        preferences.executionEffort = .xhigh
        let task = BoardTask(
            projectID: "/tmp/project",
            title: "Legacy approved task",
            sourceKind: .developmentPlan,
            sourceText: "Execute the existing plan",
            stage: .awaitingApproval,
            autoRun: false,
            planText: "1. Execute",
            hasFinalPlan: true
        )
        let snapshot = BoardSnapshot(
            version: 2,
            tasks: [task],
            manualProjectPaths: [],
            preferences: preferences
        )
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var tasks = try XCTUnwrap(object["tasks"] as? [[String: Any]])
        tasks[0].removeValue(forKey: "reasoningEffort")
        tasks[0].removeValue(forKey: "fastMode")
        object["tasks"] = tasks
        try FileManager.default.createDirectory(
            at: fixture.storageDirectory,
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: object).write(to: fixture.fileURL)

        let loaded = try await BoardPersistence(fileURL: fixture.fileURL).load()

        XCTAssertEqual(loaded.tasks.first?.reasoningEffort, .xhigh)
        XCTAssertEqual(loaded.tasks.first?.fastMode, false)
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let value = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return value.intValue & 0o777
    }
}

private struct TemporaryBoardFixture {
    let rootDirectory: URL
    let storageDirectory: URL
    let fileURL: URL

    init() throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBoardTests-\(UUID().uuidString)", isDirectory: true)
        storageDirectory = rootDirectory.appendingPathComponent("private-store", isDirectory: true)
        fileURL = storageDirectory.appendingPathComponent("board.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}
