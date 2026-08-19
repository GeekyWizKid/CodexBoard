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
            hostID: "build-server",
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
        let remoteHost = CodexHost(
            id: "build-server",
            name: "构建服务器",
            kind: .ssh,
            sshAlias: "codex-build",
            maxConcurrentExecutions: 3
        )
        let expected = BoardSnapshot(
            version: BoardSnapshot.currentVersion,
            tasks: [task],
            hosts: [.local, remoteHost],
            manualProjects: [
                ManualProjectReference(path: "/tmp/本机项目"),
                ManualProjectReference(hostID: remoteHost.id, path: "/srv/示例项目")
            ],
            preferences: preferences,
            hiddenProjectPaths: ["/tmp/已隐藏项目"]
        )

        let persistence = BoardPersistence(fileURL: fixture.fileURL)
        try await persistence.save(expected)
        let actual = try await persistence.load()

        XCTAssertEqual(actual.version, expected.version)
        XCTAssertEqual(actual.tasks, expected.tasks)
        XCTAssertEqual(actual.hosts, expected.hosts)
        XCTAssertEqual(actual.manualProjects, expected.manualProjects)
        XCTAssertEqual(actual.manualProjectPaths, ["/tmp/本机项目"])
        XCTAssertEqual(actual.hiddenProjectPaths, expected.hiddenProjectPaths)
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
        XCTAssertNil(run.continuation)
        XCTAssertNil(run.policySnapshot)
        XCTAssertNil(run.failure)
    }

    func testVersionNineSnapshotDefaultsVersionTenRunMetadataAndAttentionToNil() throws {
        let run = TaskRun(
            id: UUID(uuidString: "9C3F24FB-C91E-4A83-993F-3BFFB3EC13DE")!,
            phase: .execution,
            attempt: 1,
            startedAt: Date(timeIntervalSinceReferenceDate: 30),
            endedAt: Date(timeIntervalSinceReferenceDate: 40),
            outcome: .failed,
            threadID: "legacy-thread",
            sessionID: "legacy-session",
            turnID: "legacy-turn",
            model: "gpt-legacy",
            reasoningEffort: .high,
            fastMode: false,
            summary: "Legacy failure",
            error: "Connection lost"
        )
        let task = BoardTask(
            projectID: "/tmp/version-nine",
            title: "Version nine task",
            sourceKind: .issue,
            sourceText: "Preserve the legacy projection",
            stage: .needsAttention,
            autoRun: false,
            threadID: "current-thread",
            sessionID: "current-session",
            executionTurnID: "current-turn",
            requestedModel: "gpt-current",
            actualModel: "gpt-current",
            lastError: "Current projection error",
            runs: [run]
        )
        let snapshot = BoardSnapshot(
            tasks: [task],
            hosts: [.local],
            manualProjects: [],
            preferences: BoardPreferences()
        )
        var object = try jsonDictionary(snapshot)
        object["version"] = 9
        var tasks = try XCTUnwrap(object["tasks"] as? [[String: Any]])
        tasks[0].removeValue(forKey: "attention")
        var runs = try XCTUnwrap(tasks[0]["runs"] as? [[String: Any]])
        runs[0].removeValue(forKey: "continuation")
        runs[0].removeValue(forKey: "policySnapshot")
        runs[0].removeValue(forKey: "failure")
        tasks[0]["runs"] = runs
        object["tasks"] = tasks

        let migrated = try JSONDecoder().decode(
            BoardSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
        let migratedTask = try XCTUnwrap(migrated.tasks.first)
        let migratedRun = try XCTUnwrap(migratedTask.runs.first)

        XCTAssertEqual(migrated.version, 10)
        XCTAssertNil(migratedTask.attention)
        XCTAssertNil(migratedRun.continuation)
        XCTAssertNil(migratedRun.policySnapshot)
        XCTAssertNil(migratedRun.failure)
        XCTAssertEqual(migratedRun.threadID, "legacy-thread")
        XCTAssertEqual(migratedRun.error, "Connection lost")
        XCTAssertEqual(migratedTask.threadID, "current-thread")
        XCTAssertEqual(migratedTask.lastError, "Current projection error")
    }

    func testVersionTenRoundTripPreservesRunMetadataAndAttention() async throws {
        let fixture = try TemporaryBoardFixture()
        defer { fixture.remove() }

        let sourceRunID = UUID(uuidString: "928A67C4-8FB2-4FB2-90FA-0B17A81F59CB")!
        let runID = UUID(uuidString: "C87A3084-FD66-49F4-B0EA-4C5B732E4CC5")!
        let failureDate = Date(timeIntervalSinceReferenceDate: 1_234)
        let retryDate = Date(timeIntervalSinceReferenceDate: 1_242)
        let continuation = TaskRunContinuation(
            mode: .reusedThread,
            sourceRunID: sourceRunID
        )
        let policy = TaskRunPolicySnapshot(
            hostID: "build-server",
            workspace: TaskRunWorkspaceSnapshot(
                kind: .worktree,
                path: "/tmp/worktrees/task",
                branch: "codex/task",
                baseBranch: "main"
            ),
            sandboxMode: .workspaceWrite,
            approvalPolicy: .onRequest,
            networkAccess: true,
            writableRoots: ["/tmp/worktrees/task"],
            serviceTier: "fast"
        )
        let failure = TaskRunFailure(
            kind: .connection,
            message: "Connection lost",
            occurredAt: failureDate,
            recoveryDisposition: .automaticRetryScheduled,
            nextRetryAt: retryDate,
            consecutiveCount: 3,
            automaticRetryCount: 2
        )
        let attention = TaskAttention(
            id: UUID(uuidString: "4679089C-4A2C-4DFA-8597-D39BF57B41A1")!,
            kind: .failure,
            runID: runID,
            createdAt: failureDate
        )
        let run = TaskRun(
            id: runID,
            phase: .execution,
            attempt: 2,
            startedAt: Date(timeIntervalSinceReferenceDate: 1_200),
            endedAt: failureDate,
            outcome: .failed,
            threadID: "thread-10",
            sessionID: "session-10",
            turnID: "turn-10",
            model: "gpt-5",
            reasoningEffort: .xhigh,
            fastMode: true,
            continuation: continuation,
            policySnapshot: policy,
            failure: failure,
            summary: "Connection lost",
            error: failure.message
        )
        let task = BoardTask(
            projectID: "/tmp/project",
            hostID: "build-server",
            title: "Persist v10 metadata",
            sourceKind: .developmentPlan,
            sourceText: "Round-trip the v10 ledger",
            stage: .needsAttention,
            autoRun: false,
            threadID: "thread-10",
            sessionID: "session-10",
            executionTurnID: "turn-10",
            requestedModel: "gpt-5",
            reasoningEffort: .xhigh,
            fastMode: true,
            actualModel: "gpt-5",
            lastError: failure.message,
            runs: [run],
            workspace: TaskWorkspaceConfiguration(
                kind: .worktree,
                path: "/tmp/worktrees/task",
                branch: "codex/task",
                baseBranch: "main"
            ),
            failureState: TaskFailureState(
                kind: .connection,
                consecutiveCount: 3,
                automaticRetryCount: 2,
                nextRetryAt: retryDate,
                message: failure.message
            ),
            attention: attention
        )
        let snapshot = BoardSnapshot(
            tasks: [task],
            hosts: [
                .local,
                CodexHost(
                    id: "build-server",
                    name: "Build Server",
                    kind: .ssh,
                    sshAlias: "build",
                    maxConcurrentExecutions: 2
                )
            ],
            manualProjects: [],
            preferences: BoardPreferences()
        )
        let persistence = BoardPersistence(fileURL: fixture.fileURL)

        try await persistence.save(snapshot)
        let restored = try await persistence.load()
        let restoredTask = try XCTUnwrap(restored.tasks.first)
        let restoredRun = try XCTUnwrap(restoredTask.runs.first)

        XCTAssertEqual(restored.version, 10)
        XCTAssertEqual(restoredRun.continuation, continuation)
        XCTAssertEqual(restoredRun.policySnapshot, policy)
        XCTAssertEqual(restoredRun.failure, failure)
        XCTAssertEqual(restoredTask.attention, attention)
        XCTAssertEqual(restoredTask.failureState?.consecutiveCount, 3)
        XCTAssertEqual(restoredTask.failureState?.automaticRetryCount, 2)
    }

    func testCodeDeliveryDefaultsMissingTruncationFlag() throws {
        let delivery = try JSONDecoder().decode(
            TaskCodeDelivery.self,
            from: Data("{\"unifiedDiff\":\"patch\"}".utf8)
        )

        XCTAssertEqual(delivery.unifiedDiff, "patch")
        XCTAssertFalse(delivery.isTruncated)
    }

    func testVersionOneSnapshotMigratesManualProjectsAndLocalHost() async throws {
        let fixture = try TemporaryBoardFixture()
        defer { fixture.remove() }

        let legacyTask = makeTask()
        var taskObject = try jsonDictionary(legacyTask)
        taskObject.removeValue(forKey: "hostID")
        let legacyObject: [String: Any] = [
            "version": 1,
            "tasks": [taskObject],
            "manualProjectPaths": ["/tmp/legacy-a", "/tmp/legacy-b"],
            "preferences": try jsonDictionary(BoardPreferences())
        ]

        try FileManager.default.createDirectory(
            at: fixture.storageDirectory,
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(
            withJSONObject: legacyObject,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: fixture.fileURL)

        let persistence = BoardPersistence(fileURL: fixture.fileURL)
        let migrated = try await persistence.load()

        XCTAssertEqual(migrated.version, BoardSnapshot.currentVersion)
        XCTAssertEqual(migrated.hosts, [.local])
        XCTAssertEqual(migrated.tasks.first?.hostID, CodexHost.localID)
        XCTAssertEqual(migrated.manualProjects, [
            ManualProjectReference(path: "/tmp/legacy-a"),
            ManualProjectReference(path: "/tmp/legacy-b")
        ])

        try await persistence.save(migrated)
        let savedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.fileURL))
                as? [String: Any]
        )
        XCTAssertNotNil(savedObject["hosts"])
        XCTAssertNotNil(savedObject["manualProjects"])
        XCTAssertNil(savedObject["manualProjectPaths"])
        XCTAssertEqual(savedObject["version"] as? Int, BoardSnapshot.currentVersion)
    }

    func testSnapshotVersionsOneThroughNineDefaultMissingHostDataToLocal() throws {
        let legacyTask = makeTask()
        var taskObject = try jsonDictionary(legacyTask)
        taskObject.removeValue(forKey: "hostID")

        for legacyVersion in 1...9 {
            let legacyObject: [String: Any] = [
                "version": legacyVersion,
                "tasks": [taskObject],
                "manualProjectPaths": ["/tmp/legacy"],
                "preferences": try jsonDictionary(BoardPreferences())
            ]
            let snapshot = try JSONDecoder().decode(
                BoardSnapshot.self,
                from: JSONSerialization.data(
                    withJSONObject: legacyObject,
                    options: [.sortedKeys]
                )
            )

            XCTAssertEqual(snapshot.version, BoardSnapshot.currentVersion)
            XCTAssertEqual(snapshot.hosts, [.local])
            XCTAssertEqual(snapshot.tasks.first?.hostID, CodexHost.localID)
            XCTAssertEqual(snapshot.manualProjects, [ManualProjectReference(path: "/tmp/legacy")])
            XCTAssertEqual(snapshot.hiddenProjectPaths, [])
        }
    }

    func testVersionEightMigrationPreservesLegacyLocalConcurrencyLimit() throws {
        var legacyPreferences = BoardPreferences()
        legacyPreferences.maxConcurrentExecutions = 5
        let legacyObject: [String: Any] = [
            "version": 8,
            "tasks": [],
            "manualProjectPaths": [],
            "preferences": try jsonDictionary(legacyPreferences)
        ]

        let snapshot = try JSONDecoder().decode(
            BoardSnapshot.self,
            from: JSONSerialization.data(
                withJSONObject: legacyObject,
                options: [.sortedKeys]
            )
        )

        XCTAssertEqual(snapshot.hosts.count, 1)
        XCTAssertEqual(snapshot.hosts.first?.id, CodexHost.localID)
        XCTAssertEqual(snapshot.hosts.first?.maxConcurrentExecutions, 5)
        XCTAssertEqual(snapshot.preferences.maxConcurrentExecutions, 5)
    }

    func testLegacyManualProjectReferenceWithoutHostDefaultsToLocal() throws {
        let reference = try JSONDecoder().decode(
            ManualProjectReference.self,
            from: Data("{\"path\":\"/tmp/legacy\"}".utf8)
        )

        XCTAssertEqual(reference, ManualProjectReference(path: "/tmp/legacy"))
    }

    func testSamePathOnDifferentHostsHasDifferentProjectIdentity() {
        let path = "/srv/shared-project"
        let local = ProjectRecord(name: "shared-project", path: path)
        let remoteA = ProjectRecord(hostID: "server-a", name: "shared-project", path: path)
        let remoteB = ProjectRecord(hostID: "server-b", name: "shared-project", path: path)

        XCTAssertEqual(local.id, path)
        XCTAssertNotEqual(remoteA.id, path)
        XCTAssertNotEqual(remoteA.id, remoteB.id)
        XCTAssertEqual(
            remoteA.id,
            ProjectRecord(hostID: "server-a", name: "renamed", path: path).id
        )
    }

    func testBoardTaskCardRetainsHostIdentity() {
        let task = BoardTask(
            projectID: "/srv/project",
            hostID: "ssh:build-server",
            title: "Remote task",
            sourceKind: .issue,
            sourceText: "Run remotely",
            autoRun: false
        )

        XCTAssertEqual(BoardTaskCard(task: task).hostID, task.hostID)
    }

    func testLegacyTaskWithoutHostDefaultsToLocal() throws {
        let legacyTask = makeTask()
        var object = try jsonDictionary(legacyTask)
        object.removeValue(forKey: "hostID")

        let decoded = try JSONDecoder().decode(
            BoardTask.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )

        XCTAssertEqual(decoded.hostID, CodexHost.localID)
        XCTAssertEqual(decoded.projectID, legacyTask.projectID)
    }

    func testHostConcurrencyIsNeverLessThanOne() throws {
        var host = CodexHost(
            id: "server-a",
            name: "Server A",
            kind: .ssh,
            maxConcurrentExecutions: 0
        )
        XCTAssertEqual(host.maxConcurrentExecutions, 1)

        host.maxConcurrentExecutions = -10
        XCTAssertEqual(host.maxConcurrentExecutions, 1)
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

    func testFutureSnapshotVersionIsRejectedAndNeverOverwritten() async throws {
        let fixture = try TemporaryBoardFixture()
        defer { fixture.remove() }

        try FileManager.default.createDirectory(
            at: fixture.storageDirectory,
            withIntermediateDirectories: true
        )
        var object = try jsonDictionary(BoardSnapshot.empty)
        object["version"] = BoardSnapshot.currentVersion + 1
        let futureData = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try futureData.write(to: fixture.fileURL)
        let persistence = BoardPersistence(fileURL: fixture.fileURL)

        do {
            _ = try await persistence.load()
            XCTFail("Expected a future snapshot version to be rejected")
        } catch let BoardPersistenceError.unsupportedSnapshotVersion(_, stored, supported) {
            XCTAssertEqual(stored, BoardSnapshot.currentVersion + 1)
            XCTAssertEqual(supported, BoardSnapshot.currentVersion)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            try await persistence.save(.empty)
            XCTFail("Expected saving over a future snapshot version to fail")
        } catch let BoardPersistenceError.unsupportedSnapshotVersion(_, stored, supported) {
            XCTAssertEqual(stored, BoardSnapshot.currentVersion + 1)
            XCTAssertEqual(supported, BoardSnapshot.currentVersion)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), futureData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.migrationBackupURL.path))
    }

    func testFirstMigrationSaveCreatesPrivateBackupAndNeverOverwritesIt() async throws {
        let fixture = try TemporaryBoardFixture()
        defer { fixture.remove() }

        try FileManager.default.createDirectory(
            at: fixture.storageDirectory,
            withIntermediateDirectories: true
        )
        var object = try jsonDictionary(BoardSnapshot.empty)
        object["version"] = BoardSnapshot.currentVersion - 1
        let legacyData = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try legacyData.write(to: fixture.fileURL)
        let persistence = BoardPersistence(fileURL: fixture.fileURL)

        XCTAssertEqual(fixture.migrationBackupURL.lastPathComponent, "board.pre-v10.json")

        let migrated = try await persistence.load()
        try await persistence.save(migrated)

        XCTAssertEqual(try Data(contentsOf: fixture.migrationBackupURL), legacyData)
        XCTAssertEqual(try permissions(at: fixture.migrationBackupURL), 0o600)
        let firstBackup = try Data(contentsOf: fixture.migrationBackupURL)

        var updated = migrated
        updated.preferences.defaultAutoRun.toggle()
        try await persistence.save(updated)

        XCTAssertEqual(try Data(contentsOf: fixture.migrationBackupURL), firstBackup)
        let savedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.fileURL)) as? [String: Any]
        )
        XCTAssertEqual(savedObject["version"] as? Int, BoardSnapshot.currentVersion)
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
        object.removeValue(forKey: "hiddenProjectPaths")
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

        XCTAssertEqual(loaded.version, BoardSnapshot.currentVersion)
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
        XCTAssertNil(loaded.tasks.first?.attention)
        XCTAssertEqual(loaded.hiddenProjectPaths, [])
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

    func testAbsoluteEnvironmentDataPathIsUsedWhenFileURLIsNotProvided() async throws {
        let fixture = try TemporaryBoardFixture()
        defer { fixture.remove() }
        let environmentFileURL = fixture.rootDirectory
            .appendingPathComponent("environment-store", isDirectory: true)
            .appendingPathComponent("board.json", isDirectory: false)
        let persistence = BoardPersistence(environment: [
            BoardPersistence.dataPathEnvironmentKey: environmentFileURL.path
        ])

        try await persistence.save(.empty)
        let loaded = try await persistence.load()

        XCTAssertTrue(FileManager.default.fileExists(atPath: environmentFileURL.path))
        XCTAssertTrue(loaded.tasks.isEmpty)
        XCTAssertEqual(loaded.hosts, [.local])
        XCTAssertTrue(loaded.manualProjects.isEmpty)
    }

    func testExplicitFileURLTakesPrecedenceOverEnvironmentDataPath() async throws {
        let fixture = try TemporaryBoardFixture()
        defer { fixture.remove() }
        let ignoredEnvironmentURL = fixture.rootDirectory
            .appendingPathComponent("ignored-store", isDirectory: true)
            .appendingPathComponent("board.json", isDirectory: false)
        let persistence = BoardPersistence(
            fileURL: fixture.fileURL,
            environment: [BoardPersistence.dataPathEnvironmentKey: ignoredEnvironmentURL.path]
        )

        try await persistence.save(.empty)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ignoredEnvironmentURL.path))
    }

    func testRelativeEnvironmentDataPathFailsClosed() async throws {
        let configuredPath = "relative-store-\(UUID().uuidString)/board.json"
        let persistence = BoardPersistence(environment: [
            BoardPersistence.dataPathEnvironmentKey: configuredPath
        ])

        do {
            try await persistence.save(.empty)
            XCTFail("Expected a relative environment data path to be rejected")
        } catch let error as BoardPersistenceError {
            guard case let .invalidDataPath(value) = error else {
                return XCTFail("Expected invalidDataPath, got \(error)")
            }
            XCTAssertEqual(value, configuredPath)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: configuredPath))
    }

    func testRootEnvironmentDataPathFailsClosed() async throws {
        let persistence = BoardPersistence(environment: [
            BoardPersistence.dataPathEnvironmentKey: "/"
        ])

        do {
            try await persistence.save(.empty)
            XCTFail("Expected the filesystem root data path to be rejected")
        } catch let error as BoardPersistenceError {
            guard case let .invalidDataPath(value) = error else {
                return XCTFail("Expected invalidDataPath, got \(error)")
            }
            XCTAssertEqual(value, "/")
        }
    }

    func testEmptyEnvironmentDataPathFailsClosed() async throws {
        let persistence = BoardPersistence(environment: [
            BoardPersistence.dataPathEnvironmentKey: "   "
        ])

        do {
            _ = try await persistence.load()
            XCTFail("Expected an empty environment data path to be rejected")
        } catch let error as BoardPersistenceError {
            guard case let .invalidDataPath(value) = error else {
                return XCTFail("Expected invalidDataPath, got \(error)")
            }
            XCTAssertEqual(value, "   ")
        }
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let value = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return value.intValue & 0o777
    }

    private func makeTask() -> BoardTask {
        BoardTask(
            id: UUID(uuidString: "3D0E5030-0FBC-4873-BAA4-30452677A6D7")!,
            projectID: "/tmp/legacy",
            title: "旧任务",
            sourceKind: .issue,
            sourceText: "迁移旧任务",
            autoRun: false
        )
    }

    private func jsonDictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
                as? [String: Any]
        )
    }
}

private struct TemporaryBoardFixture {
    let rootDirectory: URL
    let storageDirectory: URL
    let fileURL: URL

    var migrationBackupURL: URL {
        storageDirectory.appendingPathComponent(
            "board.pre-v\(BoardSnapshot.currentVersion).json",
            isDirectory: false
        )
    }

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
