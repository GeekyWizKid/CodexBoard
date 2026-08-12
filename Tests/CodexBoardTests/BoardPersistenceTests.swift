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
        let expected = BoardSnapshot(
            version: 7,
            tasks: [task],
            manualProjectPaths: ["/tmp/示例项目"],
            preferences: preferences
        )

        let persistence = BoardPersistence(fileURL: fixture.fileURL)
        try await persistence.save(expected)
        let actual = try await persistence.load()

        XCTAssertEqual(actual.version, expected.version)
        XCTAssertEqual(actual.tasks, expected.tasks)
        XCTAssertEqual(actual.manualProjectPaths, expected.manualProjectPaths)
        XCTAssertEqual(actual.preferences, expected.preferences)
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
