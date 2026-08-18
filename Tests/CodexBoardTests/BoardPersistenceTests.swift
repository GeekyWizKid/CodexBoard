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
            model: "gpt-test",
            lastError: nil,
            logs: [
                TaskLogEntry(
                    id: UUID(uuidString: "266FD6FD-986A-4892-A43D-7C79CF0530A9")!,
                    date: Date(timeIntervalSinceReferenceDate: 123_800),
                    level: .success,
                    message: "已保存"
                )
            ]
        )
        let remoteHost = CodexHost(
            id: "build-server",
            name: "构建服务器",
            kind: .ssh,
            sshAlias: "codex-build",
            maxConcurrentExecutions: 3
        )
        let expected = BoardSnapshot(
            version: 2,
            tasks: [task],
            hosts: [.local, remoteHost],
            manualProjects: [
                ManualProjectReference(path: "/tmp/本机项目"),
                ManualProjectReference(hostID: remoteHost.id, path: "/srv/示例项目")
            ],
            preferences: preferences
        )

        let persistence = BoardPersistence(fileURL: fixture.fileURL)
        try await persistence.save(expected)
        let actual = try await persistence.load()

        XCTAssertEqual(actual.version, expected.version)
        XCTAssertEqual(actual.tasks, expected.tasks)
        XCTAssertEqual(actual.hosts, expected.hosts)
        XCTAssertEqual(actual.manualProjects, expected.manualProjects)
        XCTAssertEqual(actual.manualProjectPaths, ["/tmp/本机项目"])
        XCTAssertEqual(actual.preferences, expected.preferences)
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
