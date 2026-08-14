import Foundation
@testable import CodexBoard
import XCTest

final class WorktreeManagerTests: XCTestCase {
    func testPrepareRejectsPersistedPathOutsideManagedRoot() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let manager = WorktreeManager(managedRoot: fixture.worktreeRoot)

        do {
            _ = try await manager.prepare(
                taskID: UUID(),
                projectPath: fixture.repository.path,
                configuration: TaskWorkspaceConfiguration(
                    kind: .worktree,
                    path: fixture.repository.path,
                    branch: "main"
                )
            )
            XCTFail("Expected unmanaged path to be rejected")
        } catch let error as WorktreeManagerError {
            guard case .invalidManagedPath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPrepareCreatesReusableBranchAndCleanupPreservesBranch() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let manager = WorktreeManager(managedRoot: fixture.worktreeRoot)
        let taskID = UUID()

        let prepared = try await manager.prepare(
            taskID: taskID,
            projectPath: fixture.repository.path,
            configuration: TaskWorkspaceConfiguration(kind: .worktree)
        )
        let path = try XCTUnwrap(prepared.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(prepared.baseBranch, "main")
        XCTAssertTrue(prepared.branch?.hasPrefix("codex/task-") == true)
        XCTAssertEqual(try fixture.git(["-C", path, "branch", "--show-current"]), prepared.branch)

        let reused = try await manager.prepare(
            taskID: taskID,
            projectPath: fixture.repository.path,
            configuration: prepared
        )
        XCTAssertEqual(reused, prepared)

        let cleaned = try await manager.cleanup(
            projectPath: fixture.repository.path,
            configuration: prepared
        )
        XCTAssertNil(cleaned.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let branch = try XCTUnwrap(prepared.branch)
        XCTAssertEqual(
            try fixture.git(["-C", fixture.repository.path, "show-ref", "--verify", "--quiet", "refs/heads/\(branch)"]),
            ""
        )
    }

    func testPrepareRecoversRegisteredWorktreeWhenPersistedPathWasLost() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let manager = WorktreeManager(managedRoot: fixture.worktreeRoot)
        let taskID = UUID()

        let prepared = try await manager.prepare(
            taskID: taskID,
            projectPath: fixture.repository.path,
            configuration: TaskWorkspaceConfiguration(kind: .worktree)
        )
        let recovered = try await manager.prepare(
            taskID: taskID,
            projectPath: fixture.repository.path,
            configuration: TaskWorkspaceConfiguration(kind: .worktree)
        )

        XCTAssertEqual(recovered, prepared)
    }

    func testPrepareStillRejectsUnregisteredOccupiedDestination() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let manager = WorktreeManager(managedRoot: fixture.worktreeRoot)
        let taskID = UUID()

        let prepared = try await manager.prepare(
            taskID: taskID,
            projectPath: fixture.repository.path,
            configuration: TaskWorkspaceConfiguration(kind: .worktree)
        )
        let path = try XCTUnwrap(prepared.path)
        _ = try await manager.cleanup(
            projectPath: fixture.repository.path,
            configuration: prepared
        )
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path, isDirectory: true),
            withIntermediateDirectories: true
        )

        do {
            _ = try await manager.prepare(
                taskID: taskID,
                projectPath: fixture.repository.path,
                configuration: TaskWorkspaceConfiguration(kind: .worktree)
            )
            XCTFail("Expected an unregistered occupied path to be rejected")
        } catch let error as WorktreeManagerError {
            guard case .pathOccupied = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCleanupRefusesDirtyWorktree() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let manager = WorktreeManager(managedRoot: fixture.worktreeRoot)
        let prepared = try await manager.prepare(
            taskID: UUID(),
            projectPath: fixture.repository.path,
            configuration: TaskWorkspaceConfiguration(kind: .worktree)
        )
        let path = try XCTUnwrap(prepared.path)
        let dirtyFile = URL(fileURLWithPath: path).appendingPathComponent("dirty.txt")
        try Data("local change".utf8).write(to: dirtyFile)

        do {
            _ = try await manager.cleanup(
                projectPath: fixture.repository.path,
                configuration: prepared
            )
            XCTFail("Expected dirty worktree cleanup to fail")
        } catch let error as WorktreeManagerError {
            guard case .dirtyWorktree = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        try FileManager.default.removeItem(at: dirtyFile)
        _ = try await manager.cleanup(
            projectPath: fixture.repository.path,
            configuration: prepared
        )
    }
}

private final class GitFixture {
    let root: URL
    let repository: URL
    let worktreeRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        repository = root.appendingPathComponent("repository", isDirectory: true)
        worktreeRoot = root.appendingPathComponent("managed-worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        _ = try git(["-C", repository.path, "init", "-b", "main"])
        _ = try git(["-C", repository.path, "config", "user.email", "codexboard@example.test"])
        _ = try git(["-C", repository.path, "config", "user.name", "CodexBoard Tests"])
        try Data("fixture\n".utf8).write(to: repository.appendingPathComponent("README.md"))
        _ = try git(["-C", repository.path, "add", "README.md"])
        _ = try git(["-C", repository.path, "commit", "-m", "Initial"])
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func git(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GitFixture",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: stderr]
            )
        }
        return stdout
    }
}
