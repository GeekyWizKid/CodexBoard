import Foundation
import Darwin
@testable import CodexBoard
import XCTest

final class WorktreeManagerTests: XCTestCase {
    func testPrepareRejectsPersistedPathOutsideManagedRoot() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let manager = WorktreeManager(managedRoot: fixture.worktreeRoot)
        let taskID = UUID()

        do {
            _ = try await manager.prepare(
                taskID: taskID,
                projectPath: fixture.repository.path,
                configuration: TaskWorkspaceConfiguration(
                    kind: .worktree,
                    path: fixture.repository.path,
                    branch: "codex/task-\(taskID.uuidString.lowercased())"
                )
            )
            XCTFail("Expected unmanaged path to be rejected")
        } catch let error as WorktreeManagerError {
            guard case .invalidManagedPath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPrepareRejectsManagedRootInsideSourceRepository() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let nestedRoot = fixture.repository.appendingPathComponent(
            ".codexboard/worktrees",
            isDirectory: true
        )
        let manager = WorktreeManager(managedRoot: nestedRoot)

        do {
            _ = try await manager.prepare(
                taskID: UUID(),
                projectPath: fixture.repository.path,
                configuration: TaskWorkspaceConfiguration(kind: .worktree)
            )
            XCTFail("Expected a managed root inside the source repository to be rejected")
        } catch let error as WorktreeManagerError {
            guard case .invalidManagedPath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: nestedRoot.path))
    }

    func testPrepareRejectsRepositoryBucketSymlinkEscapingManagedRoot() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let manager = WorktreeManager(managedRoot: fixture.worktreeRoot)
        let seed = try await manager.prepare(
            taskID: UUID(),
            projectPath: fixture.repository.path,
            configuration: TaskWorkspaceConfiguration(kind: .worktree)
        )
        let seedPath = try XCTUnwrap(seed.path)
        let bucket = URL(fileURLWithPath: seedPath, isDirectory: true)
            .deletingLastPathComponent()
        _ = try await manager.cleanup(
            projectPath: fixture.repository.path,
            configuration: seed
        )
        try FileManager.default.removeItem(at: bucket)
        let escapedRoot = fixture.root.appendingPathComponent("escaped", isDirectory: true)
        try FileManager.default.createDirectory(
            at: escapedRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: bucket,
            withDestinationURL: escapedRoot
        )
        let taskID = UUID()

        do {
            _ = try await manager.prepare(
                taskID: taskID,
                projectPath: fixture.repository.path,
                configuration: TaskWorkspaceConfiguration(kind: .worktree)
            )
            XCTFail("Expected a repository bucket symlink to be rejected")
        } catch let error as WorktreeManagerError {
            guard case .invalidManagedPath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: escapedRoot.appendingPathComponent(
                    taskID.uuidString.lowercased(),
                    isDirectory: true
                ).path
            )
        )
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

        let repeatedCleanup = try await manager.cleanup(
            taskID: taskID,
            projectPath: fixture.repository.path,
            configuration: prepared,
            requiredCapability: .managedV1
        )
        XCTAssertNil(repeatedCleanup.path)
        XCTAssertEqual(repeatedCleanup.preparation, prepared.preparation)
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

    func testCleanupPreservesIgnoredFilesAndReportsThemAsChanges() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        try Data("*.secret\n".utf8).write(
            to: fixture.repository.appendingPathComponent(".gitignore")
        )
        _ = try fixture.git(["-C", fixture.repository.path, "add", ".gitignore"])
        _ = try fixture.git(["-C", fixture.repository.path, "commit", "-m", "Ignore secrets"])
        let manager = WorktreeManager(managedRoot: fixture.worktreeRoot)
        let prepared = try await manager.prepare(
            taskID: UUID(),
            projectPath: fixture.repository.path,
            configuration: TaskWorkspaceConfiguration(kind: .worktree)
        )
        let path = try XCTUnwrap(prepared.path)
        let ignoredFile = URL(fileURLWithPath: path).appendingPathComponent("valuable.secret")
        try Data("keep me\n".utf8).write(to: ignoredFile)

        let status = try await manager.status(configuration: prepared)
        XCTAssertFalse(status.isClean)
        XCTAssertTrue(status.changes.contains(where: { $0.contains("valuable.secret") }))

        do {
            _ = try await manager.cleanup(
                projectPath: fixture.repository.path,
                configuration: prepared
            )
            XCTFail("Expected ignored user data to block cleanup")
        } catch let error as WorktreeManagerError {
            guard case .dirtyWorktree = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ignoredFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testCleanupPreservesTrackedChangesHiddenByIndexFlags() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let extraFile = fixture.repository.appendingPathComponent("SECOND.md")
        try Data("second\n".utf8).write(to: extraFile)
        _ = try fixture.git(["-C", fixture.repository.path, "add", "SECOND.md"])
        _ = try fixture.git(["-C", fixture.repository.path, "commit", "-m", "Add second file"])
        let manager = WorktreeManager(managedRoot: fixture.worktreeRoot)
        let prepared = try await manager.prepare(
            taskID: UUID(),
            projectPath: fixture.repository.path,
            configuration: TaskWorkspaceConfiguration(kind: .worktree)
        )
        let path = try XCTUnwrap(prepared.path)
        _ = try fixture.git(["-C", path, "update-index", "--assume-unchanged", "README.md"])
        _ = try fixture.git(["-C", path, "update-index", "--skip-worktree", "SECOND.md"])
        let readme = URL(fileURLWithPath: path).appendingPathComponent("README.md")
        let second = URL(fileURLWithPath: path).appendingPathComponent("SECOND.md")
        try Data("hidden assume-unchanged edit\n".utf8).write(to: readme)
        try Data("hidden skip-worktree edit\n".utf8).write(to: second)

        let status = try await manager.status(configuration: prepared)
        XCTAssertFalse(status.isClean)
        XCTAssertTrue(status.changes.contains(where: { $0.contains("assume-unchanged") }))
        XCTAssertTrue(status.changes.contains(where: { $0.contains("skip-worktree") }))

        do {
            _ = try await manager.cleanup(
                projectPath: fixture.repository.path,
                configuration: prepared
            )
            XCTFail("Expected hidden tracked changes to block cleanup")
        } catch let error as WorktreeManagerError {
            guard case .dirtyWorktree = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(
            try String(contentsOf: readme, encoding: .utf8),
            "hidden assume-unchanged edit\n"
        )
        XCTAssertEqual(
            try String(contentsOf: second, encoding: .utf8),
            "hidden skip-worktree edit\n"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testCleanupPreservesSpecialNodesAndEmptyDirectoriesMissingFromGitStatus() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let manager = WorktreeManager(managedRoot: fixture.worktreeRoot)
        let prepared = try await manager.prepare(
            taskID: UUID(),
            projectPath: fixture.repository.path,
            configuration: TaskWorkspaceConfiguration(kind: .worktree)
        )
        let path = try XCTUnwrap(prepared.path)
        let fifo = URL(fileURLWithPath: path).appendingPathComponent("valuable.pipe")
        let emptyDirectory = URL(fileURLWithPath: path)
            .appendingPathComponent("valuable-empty-directory", isDirectory: true)
        XCTAssertEqual(Darwin.mkfifo(fifo.path, 0o600), 0)
        try FileManager.default.createDirectory(
            at: emptyDirectory,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(
            try fixture.git([
                "-C", path, "status", "--porcelain=v1", "--ignored=matching",
                "--untracked-files=all",
            ]),
            ""
        )

        let status = try await manager.status(configuration: prepared)
        XCTAssertFalse(status.isClean)
        XCTAssertTrue(status.changes.contains(where: { $0.contains("valuable.pipe") }))
        XCTAssertTrue(status.changes.contains(where: { $0.contains("valuable-empty-directory") }))

        do {
            _ = try await manager.cleanup(
                projectPath: fixture.repository.path,
                configuration: prepared
            )
            XCTFail("Expected unreported filesystem nodes to block cleanup")
        } catch let error as WorktreeManagerError {
            guard case .dirtyWorktree = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fifo.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: emptyDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testCleanupPreservesDataInsideGitlinkAddedByTaskExecution() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let manager = WorktreeManager(managedRoot: fixture.worktreeRoot)
        let prepared = try await manager.prepare(
            taskID: UUID(),
            projectPath: fixture.repository.path,
            configuration: TaskWorkspaceConfiguration(kind: .worktree)
        )
        let path = try XCTUnwrap(prepared.path)
        let commit = try fixture.git(["-C", path, "rev-parse", "HEAD"])
        _ = try fixture.git([
            "-C", path,
            "update-index", "--add", "--cacheinfo", "160000,\(commit),vendor/child",
        ])
        _ = try fixture.git(["-C", path, "commit", "-m", "Add task gitlink"])
        let child = URL(fileURLWithPath: path)
            .appendingPathComponent("vendor/child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let secret = child.appendingPathComponent("valuable.txt")
        try Data("keep me\n".utf8).write(to: secret)
        XCTAssertEqual(
            try fixture.git([
                "-C", path, "status", "--porcelain=v1", "--ignored=matching",
                "--untracked-files=all",
            ]),
            ""
        )

        let status = try await manager.status(configuration: prepared)
        XCTAssertFalse(status.isClean)
        XCTAssertTrue(status.changes.contains(where: { $0.contains("GITLINK") }))

        do {
            _ = try await manager.cleanup(
                projectPath: fixture.repository.path,
                configuration: prepared
            )
            XCTFail("Expected a task-created gitlink to block cleanup")
        } catch let error as WorktreeManagerError {
            guard case .dirtyWorktree = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8), "keep me\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testPrepareCapturesTrackedAndUntrackedDirtyBaselineWithoutChangingSource() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let manager = WorktreeManager(managedRoot: fixture.worktreeRoot)
        let taskID = UUID()

        try Data("*.cache\n".utf8).write(
            to: fixture.repository.appendingPathComponent(".gitignore")
        )
        _ = try fixture.git(["-C", fixture.repository.path, "add", ".gitignore"])
        _ = try fixture.git(["-C", fixture.repository.path, "commit", "-m", "Ignore cache"])

        try Data("staged content\n".utf8).write(
            to: fixture.repository.appendingPathComponent("staged.txt")
        )
        _ = try fixture.git(["-C", fixture.repository.path, "add", "staged.txt"])
        try Data("fixture\nunstaged content\n".utf8).write(
            to: fixture.repository.appendingPathComponent("README.md")
        )
        let scratch = fixture.repository.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Data("untracked content\n".utf8).write(to: scratch.appendingPathComponent("notes.txt"))
        try Data("ignored content\n".utf8).write(
            to: fixture.repository.appendingPathComponent("private.cache")
        )

        let sourceCommit = try fixture.git([
            "-C", fixture.repository.path, "rev-parse", "HEAD",
        ])
        let sourceStatus = try fixture.gitData([
            "-C", fixture.repository.path, "status", "--porcelain=v1", "-z", "--untracked-files=all",
        ])
        let sourceIndex = try fixture.indexData()

        let prepared = try await manager.prepare(
            taskID: taskID,
            projectPath: fixture.repository.path,
            configuration: TaskWorkspaceConfiguration(kind: .worktree)
        )

        let path = try XCTUnwrap(prepared.path)
        let evidence = try XCTUnwrap(prepared.preparation)
        XCTAssertEqual(evidence.capability, .managedV1)
        XCTAssertEqual(evidence.ownerTaskID, taskID)
        XCTAssertEqual(evidence.repositoryPath, fixture.repository.resolvingSymlinksInPath().path)
        XCTAssertEqual(evidence.sourceCommit, sourceCommit)
        XCTAssertNotEqual(evidence.baselineCommit, sourceCommit)
        XCTAssertTrue(evidence.dirtyBaseCaptured)
        XCTAssertEqual(evidence.untrackedFilesCaptured, 1)
        XCTAssertEqual(
            try fixture.git(["-C", path, "rev-parse", "HEAD"]),
            evidence.baselineCommit
        )
        XCTAssertEqual(try fixture.git(["-C", path, "rev-parse", "HEAD^1"]), sourceCommit)
        XCTAssertEqual(
            try String(contentsOfFile: URL(fileURLWithPath: path).appendingPathComponent("staged.txt").path),
            "staged content\n"
        )
        XCTAssertEqual(
            try String(contentsOfFile: URL(fileURLWithPath: path).appendingPathComponent("README.md").path),
            "fixture\nunstaged content\n"
        )
        XCTAssertEqual(
            try String(contentsOfFile: URL(fileURLWithPath: path)
                .appendingPathComponent("scratch/notes.txt").path),
            "untracked content\n"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: path).appendingPathComponent("private.cache").path
            )
        )
        XCTAssertEqual(
            try fixture.git(["-C", path, "status", "--porcelain", "--untracked-files=all"]),
            ""
        )

        XCTAssertEqual(
            try fixture.gitData([
                "-C", fixture.repository.path, "status", "--porcelain=v1", "-z",
                "--untracked-files=all",
            ]),
            sourceStatus
        )
        XCTAssertEqual(try fixture.indexData(), sourceIndex)
        XCTAssertEqual(
            try fixture.git(["-C", fixture.repository.path, "diff", "--cached", "--name-only"]),
            "staged.txt"
        )
        XCTAssertEqual(
            try fixture.git(["-C", fixture.repository.path, "diff", "--name-only"]),
            "README.md"
        )
    }

    func testPrepareFailsClosedBeforeCreationWhenUntrackedFileCountExceedsLimit() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let manager = WorktreeManager(
            managedRoot: fixture.worktreeRoot,
            maximumUntrackedFiles: 1
        )
        try Data("one".utf8).write(to: fixture.repository.appendingPathComponent("one.txt"))
        try Data("two".utf8).write(to: fixture.repository.appendingPathComponent("two.txt"))

        do {
            _ = try await manager.prepare(
                taskID: UUID(),
                projectPath: fixture.repository.path,
                configuration: TaskWorkspaceConfiguration(kind: .worktree)
            )
            XCTFail("Expected the untracked file count limit to block preparation")
        } catch let error as WorktreeManagerError {
            XCTAssertEqual(error, .untrackedFileLimitExceeded(maximum: 1))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.worktreeRoot.path))
    }

    func testPrepareFailsClosedBeforeCreationWhenUntrackedBytesExceedLimit() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let manager = WorktreeManager(
            managedRoot: fixture.worktreeRoot,
            maximumUntrackedBytes: 3
        )
        try Data("four".utf8).write(to: fixture.repository.appendingPathComponent("four.txt"))

        do {
            _ = try await manager.prepare(
                taskID: UUID(),
                projectPath: fixture.repository.path,
                configuration: TaskWorkspaceConfiguration(kind: .worktree)
            )
            XCTFail("Expected the untracked byte limit to block preparation")
        } catch let error as WorktreeManagerError {
            XCTAssertEqual(error, .untrackedByteLimitExceeded(maximum: 3))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.worktreeRoot.path))
    }

    func testPrepareRejectsRepositoryWithoutInitialCommit() async throws {
        let fixture = try GitFixture(makeInitialCommit: false)
        defer { fixture.cleanup() }
        let manager = WorktreeManager(managedRoot: fixture.worktreeRoot)

        let availability = await manager.capability(
            projectPath: fixture.repository.path,
            requiredCapability: .managedV1
        )
        guard case let .unsupported(reason) = availability else {
            return XCTFail("Expected an unsupported capability, got \(availability)")
        }
        XCTAssertTrue(reason.contains("初始提交"))

        do {
            _ = try await manager.prepare(
                taskID: UUID(),
                projectPath: fixture.repository.path,
                configuration: TaskWorkspaceConfiguration(kind: .worktree)
            )
            XCTFail("Expected an unborn repository to be rejected")
        } catch let error as WorktreeManagerError {
            guard case .repositoryHasNoInitialCommit = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRepositoryWithGitlinkIsUnsupportedUntilSubmodulesCanBeCaptured() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let commit = try fixture.git(["-C", fixture.repository.path, "rev-parse", "HEAD"])
        _ = try fixture.git([
            "-C", fixture.repository.path,
            "update-index", "--add", "--cacheinfo", "160000,\(commit),vendor/child",
        ])
        _ = try fixture.git(["-C", fixture.repository.path, "commit", "-m", "Add gitlink"])
        let manager = WorktreeManager(managedRoot: fixture.worktreeRoot)

        let availability = await manager.capability(
            projectPath: fixture.repository.path,
            requiredCapability: .managedV1
        )
        guard case let .unsupported(reason) = availability else {
            return XCTFail("Expected submodule repository to be unsupported, got \(availability)")
        }
        XCTAssertTrue(reason.contains("submodule"))

        do {
            _ = try await manager.prepare(
                taskID: UUID(),
                projectPath: fixture.repository.path,
                configuration: TaskWorkspaceConfiguration(kind: .worktree)
            )
            XCTFail("Expected submodule repository preparation to fail closed")
        } catch let error as WorktreeManagerError {
            guard case .capabilityUnsupported = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.worktreeRoot.path))
    }

    func testRepositoryWithUnreportedSpecialNodeIsUnsupportedBeforeCapture() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let fifo = fixture.repository.appendingPathComponent("source.pipe")
        XCTAssertEqual(Darwin.mkfifo(fifo.path, 0o600), 0)
        let manager = WorktreeManager(managedRoot: fixture.worktreeRoot)

        let availability = await manager.capability(
            projectPath: fixture.repository.path,
            requiredCapability: .managedV1
        )
        guard case let .unsupported(reason) = availability else {
            return XCTFail("Expected a special source node to be unsupported, got \(availability)")
        }
        XCTAssertTrue(reason.contains("特殊节点"))

        do {
            _ = try await manager.prepare(
                taskID: UUID(),
                projectPath: fixture.repository.path,
                configuration: TaskWorkspaceConfiguration(kind: .worktree)
            )
            XCTFail("Expected source special node preparation to fail closed")
        } catch let error as WorktreeManagerError {
            guard case .capabilityUnsupported = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fifo.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.worktreeRoot.path))
    }

    func testRepositoryWithIndexFlagsIsUnsupportedUntilFlagAwareCaptureExists() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let secondFile = fixture.repository.appendingPathComponent("SECOND.md")
        try Data("second\n".utf8).write(to: secondFile)
        _ = try fixture.git(["-C", fixture.repository.path, "add", "SECOND.md"])
        _ = try fixture.git(["-C", fixture.repository.path, "commit", "-m", "Add second file"])
        _ = try fixture.git([
            "-C", fixture.repository.path,
            "update-index", "--assume-unchanged", "README.md",
        ])
        _ = try fixture.git([
            "-C", fixture.repository.path,
            "update-index", "--skip-worktree", "SECOND.md",
        ])
        try Data("hidden edit\n".utf8).write(
            to: fixture.repository.appendingPathComponent("README.md")
        )
        let manager = WorktreeManager(managedRoot: fixture.worktreeRoot)

        let availability = await manager.capability(
            projectPath: fixture.repository.path,
            requiredCapability: .managedV1
        )
        guard case let .unsupported(reason) = availability else {
            return XCTFail("Expected flagged index to be unsupported, got \(availability)")
        }
        XCTAssertTrue(reason.contains("assume-unchanged"))
        XCTAssertTrue(reason.contains("skip-worktree"))

        do {
            _ = try await manager.prepare(
                taskID: UUID(),
                projectPath: fixture.repository.path,
                configuration: TaskWorkspaceConfiguration(kind: .worktree)
            )
            XCTFail("Expected flagged index preparation to fail closed")
        } catch let error as WorktreeManagerError {
            guard case .capabilityUnsupported = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.worktreeRoot.path))
    }

    func testTrackedContentRaceIsDetectedAndCapturedStateIsPreserved() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let sourceFile = fixture.repository.appendingPathComponent("README.md")
        try Data("captured tracked state\n".utf8).write(to: sourceFile)
        let wrapper = try fixture.makeMutatingGitWrapper([
            .write("changed after capture\n", to: sourceFile),
        ])
        let manager = WorktreeManager(
            managedRoot: fixture.worktreeRoot,
            gitExecutableURL: wrapper
        )

        let preservedPath = try await preservedCapturePath(
            manager: manager,
            fixture: fixture
        )
        XCTAssertEqual(
            try String(contentsOf: URL(fileURLWithPath: preservedPath)
                .appendingPathComponent("README.md"), encoding: .utf8),
            "captured tracked state\n"
        )
        XCTAssertEqual(
            try String(contentsOf: sourceFile, encoding: .utf8),
            "changed after capture\n"
        )
    }

    func testUntrackedContentRaceIsDetectedAndCapturedStateIsPreserved() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let sourceFile = fixture.repository.appendingPathComponent("notes.txt")
        try Data("captured untracked state\n".utf8).write(to: sourceFile)
        let wrapper = try fixture.makeMutatingGitWrapper([
            .write("changed after capture\n", to: sourceFile),
        ])
        let manager = WorktreeManager(
            managedRoot: fixture.worktreeRoot,
            gitExecutableURL: wrapper
        )

        let preservedPath = try await preservedCapturePath(
            manager: manager,
            fixture: fixture
        )
        XCTAssertEqual(
            try String(contentsOf: URL(fileURLWithPath: preservedPath)
                .appendingPathComponent("notes.txt"), encoding: .utf8),
            "captured untracked state\n"
        )
        XCTAssertEqual(
            try String(contentsOf: sourceFile, encoding: .utf8),
            "changed after capture\n"
        )
    }

    func testSourceHeadRaceIsDetectedEvenWhenStatusAndFilesStayUnchanged() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let wrapper = try fixture.makeMutatingGitWrapper([
            .emptyCommit(in: fixture.repository),
        ])
        let manager = WorktreeManager(
            managedRoot: fixture.worktreeRoot,
            gitExecutableURL: wrapper
        )

        do {
            _ = try await manager.prepare(
                taskID: UUID(),
                projectPath: fixture.repository.path,
                configuration: TaskWorkspaceConfiguration(kind: .worktree)
            )
            XCTFail("Expected a concurrent source HEAD change to fail preparation")
        } catch let error as WorktreeManagerError {
            guard case .capturedStatePreserved = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCleanSourceBaselineFailurePreservesWatcherStateInWorktree() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let taskID = UUID()
        let expectedPath = fixture.managedWorktreePath(taskID: taskID)
        let watcherFile = expectedPath.appendingPathComponent("watcher-created.txt")
        let wrapper = try fixture.makeMutatingGitWrapper([
            .write("do not delete\n", to: watcherFile),
        ])
        let manager = WorktreeManager(
            managedRoot: fixture.worktreeRoot,
            gitExecutableURL: wrapper
        )

        do {
            _ = try await manager.prepare(
                taskID: taskID,
                projectPath: fixture.repository.path,
                configuration: TaskWorkspaceConfiguration(kind: .worktree)
            )
            XCTFail("Expected post-add watcher state to stop baseline preparation")
        } catch let error as WorktreeManagerError {
            guard case let .capturedStatePreserved(path, branch, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, expectedPath.path)
            XCTAssertEqual(branch, "codex/task-\(taskID.uuidString.lowercased())")
        }
        XCTAssertEqual(
            try String(contentsOf: watcherFile, encoding: .utf8),
            "do not delete\n"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedPath.path))
    }

    func testFailedWorktreeAddRemovesOnlyFreshUnregisteredBranch() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        _ = try fixture.git([
            "-C", fixture.repository.path, "config", "filter.block.clean", "/bin/cat",
        ])
        _ = try fixture.git([
            "-C", fixture.repository.path, "config", "filter.block.smudge", "/usr/bin/false",
        ])
        _ = try fixture.git([
            "-C", fixture.repository.path, "config", "filter.block.required", "true",
        ])
        try Data("filtered.txt filter=block\n".utf8).write(
            to: fixture.repository.appendingPathComponent(".gitattributes")
        )
        try Data("filtered\n".utf8).write(
            to: fixture.repository.appendingPathComponent("filtered.txt")
        )
        _ = try fixture.git([
            "-C", fixture.repository.path, "add", ".gitattributes", "filtered.txt",
        ])
        _ = try fixture.git(["-C", fixture.repository.path, "commit", "-m", "Add filter"])
        let manager = WorktreeManager(managedRoot: fixture.worktreeRoot)
        let taskID = UUID()
        let branch = "codex/task-\(taskID.uuidString.lowercased())"

        do {
            _ = try await manager.prepare(
                taskID: taskID,
                projectPath: fixture.repository.path,
                configuration: TaskWorkspaceConfiguration(kind: .worktree)
            )
            XCTFail("Expected the required smudge filter to fail worktree creation")
        } catch let error as WorktreeManagerError {
            guard case .gitFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.managedWorktreePath(taskID: taskID).path
            )
        )
        XCTAssertThrowsError(try fixture.git([
            "-C", fixture.repository.path,
            "show-ref", "--verify", "--quiet", "refs/heads/\(branch)",
        ]))
    }

    func testLegacyWorktreeWithoutPreparationCanBeCleanedAndRetriedSafely() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let manager = WorktreeManager(managedRoot: fixture.worktreeRoot)
        let taskID = UUID()
        let legacyBranch = "codex/task-\(taskID.uuidString.prefix(8).lowercased())"
        _ = try fixture.git([
            "-C", fixture.repository.path, "branch", legacyBranch, "HEAD",
        ])
        let prepared = try await manager.prepare(
            taskID: taskID,
            projectPath: fixture.repository.path,
            configuration: TaskWorkspaceConfiguration(
                kind: .worktree,
                branch: legacyBranch
            )
        )
        var legacyConfiguration = prepared
        legacyConfiguration.preparation = nil
        let path = try XCTUnwrap(legacyConfiguration.path)
        let valuable = URL(fileURLWithPath: path).appendingPathComponent("valuable.txt")
        try Data("keep until handled\n".utf8).write(to: valuable)

        do {
            _ = try await manager.cleanup(
                taskID: taskID,
                projectPath: fixture.repository.path,
                configuration: legacyConfiguration,
                requiredCapability: .managedV1
            )
            XCTFail("Expected an unproven dirty legacy worktree to be preserved")
        } catch let error as WorktreeManagerError {
            guard case .dirtyWorktree = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: valuable.path))

        try FileManager.default.removeItem(at: valuable)
        let cleaned = try await manager.cleanup(
            taskID: taskID,
            projectPath: fixture.repository.path,
            configuration: legacyConfiguration,
            requiredCapability: .managedV1
        )
        XCTAssertNil(cleaned.path)
        XCTAssertEqual(cleaned.branch, legacyBranch)
        XCTAssertNil(cleaned.preparation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(
            try fixture.git([
                "-C", fixture.repository.path,
                "show-ref", "--verify", "--quiet", "refs/heads/\(legacyBranch)",
            ]),
            ""
        )

        let retried = try await manager.prepare(
            taskID: taskID,
            projectPath: fixture.repository.path,
            configuration: cleaned
        )
        XCTAssertEqual(retried.branch, legacyBranch)
        XCTAssertNotNil(retried.preparation)
    }

    func testPrepareSurfacesCrashCreatedOwnedWorktreeWithoutPreparation() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let manager = WorktreeManager(managedRoot: fixture.worktreeRoot)
        let taskID = UUID()
        let branch = "codex/task-\(taskID.uuidString.lowercased())"
        let destination = fixture.managedWorktreePath(taskID: taskID)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try fixture.git([
            "-C", fixture.repository.path, "worktree", "add", "-b", branch,
            destination.path, "HEAD",
        ])

        do {
            _ = try await manager.prepare(
                taskID: taskID,
                projectPath: fixture.repository.path,
                configuration: TaskWorkspaceConfiguration(kind: .worktree)
            )
            XCTFail("Expected the unproven crash-created worktree to be surfaced")
        } catch let error as WorktreeManagerError {
            guard case let .capturedStatePreserved(path, actualBranch, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, destination.resolvingSymlinksInPath().path)
            XCTAssertEqual(actualBranch, branch)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testPrepareRecoversAttemptBranchAfterPersistenceCrash() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let manager = WorktreeManager(managedRoot: fixture.worktreeRoot)
        let taskID = UUID()
        let defaultBranch = "codex/task-\(taskID.uuidString.lowercased())"
        _ = try fixture.git(["-C", fixture.repository.path, "branch", defaultBranch, "HEAD"])
        let prepared = try await manager.prepare(
            taskID: taskID,
            projectPath: fixture.repository.path,
            configuration: TaskWorkspaceConfiguration(kind: .worktree)
        )
        XCTAssertEqual(prepared.branch, "\(defaultBranch)-attempt-2")

        let recovered = try await manager.prepare(
            taskID: taskID,
            projectPath: fixture.repository.path,
            configuration: TaskWorkspaceConfiguration(kind: .worktree)
        )
        XCTAssertEqual(recovered.path, prepared.path)
        XCTAssertEqual(recovered.branch, prepared.branch)
        XCTAssertEqual(recovered.preparation, prepared.preparation)
    }

    func testPrepareAdoptsPersistedLegacyBranchWithoutLosingPriorCommits() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let manager = WorktreeManager(managedRoot: fixture.worktreeRoot)
        let taskID = UUID()
        let legacyBranch = "codex/task-\(taskID.uuidString.prefix(8).lowercased())"
        let legacyCheckout = fixture.root.appendingPathComponent("legacy-checkout")
        _ = try fixture.git([
            "-C", fixture.repository.path, "worktree", "add", "-b", legacyBranch,
            legacyCheckout.path, "HEAD",
        ])
        try Data("legacy result\n".utf8).write(
            to: legacyCheckout.appendingPathComponent("legacy-result.txt")
        )
        _ = try fixture.git(["-C", legacyCheckout.path, "add", "legacy-result.txt"])
        _ = try fixture.git(["-C", legacyCheckout.path, "commit", "-m", "Legacy result"])
        let legacyTip = try fixture.git([
            "-C", legacyCheckout.path, "rev-parse", "HEAD^{commit}",
        ])
        _ = try fixture.git([
            "-C", fixture.repository.path, "worktree", "remove", legacyCheckout.path,
        ])

        let prepared = try await manager.prepare(
            taskID: taskID,
            projectPath: fixture.repository.path,
            configuration: TaskWorkspaceConfiguration(
                kind: .worktree,
                branch: legacyBranch
            )
        )
        let path = try XCTUnwrap(prepared.path)
        let preparation = try XCTUnwrap(prepared.preparation)
        XCTAssertEqual(prepared.branch, legacyBranch)
        XCTAssertEqual(preparation.sourceCommit, legacyTip)
        XCTAssertEqual(
            try fixture.git(["-C", path, "rev-parse", "HEAD^1"]),
            legacyTip
        )
        XCTAssertEqual(
            try String(
                contentsOf: URL(fileURLWithPath: path).appendingPathComponent("legacy-result.txt"),
                encoding: .utf8
            ),
            "legacy result\n"
        )
    }

    func testPrepareDoesNotRecreateDeletedPersistedLegacyBranch() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let manager = WorktreeManager(managedRoot: fixture.worktreeRoot)
        let taskID = UUID()
        let legacyBranch = "codex/task-\(taskID.uuidString.prefix(8).lowercased())"

        do {
            _ = try await manager.prepare(
                taskID: taskID,
                projectPath: fixture.repository.path,
                configuration: TaskWorkspaceConfiguration(
                    kind: .worktree,
                    branch: legacyBranch
                )
            )
            XCTFail("Expected a missing persisted legacy branch to fail closed")
        } catch let error as WorktreeManagerError {
            guard case .invalidPreparationEvidence = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(
            try fixture.git([
                "-C", fixture.repository.path, "branch", "--list", legacyBranch,
            ]),
            ""
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.managedWorktreePath(taskID: taskID).path)
        )
    }

    func testBaselineRejectsPathDependentCleanFilterOutput() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let filter = fixture.root.appendingPathComponent("path-dependent-clean")
        let script = """
        #!/bin/sh
        case "$PWD" in
          *managed-worktrees*) sed '/^dirty /s/^/managed:/' ;;
          *) cat ;;
        esac
        """
        try Data(script.utf8).write(to: filter, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: filter.path
        )
        _ = try fixture.git([
            "-C", fixture.repository.path, "config", "filter.path.clean", filter.path,
        ])
        _ = try fixture.git([
            "-C", fixture.repository.path, "config", "filter.path.smudge", "/bin/cat",
        ])
        _ = try fixture.git([
            "-C", fixture.repository.path, "config", "filter.path.required", "true",
        ])
        try Data("filtered.txt filter=path\n".utf8).write(
            to: fixture.repository.appendingPathComponent(".gitattributes")
        )
        let filtered = fixture.repository.appendingPathComponent("filtered.txt")
        try Data("committed\n".utf8).write(to: filtered)
        _ = try fixture.git([
            "-C", fixture.repository.path, "add", ".gitattributes", "filtered.txt",
        ])
        _ = try fixture.git(["-C", fixture.repository.path, "commit", "-m", "Add filter"])
        try Data("dirty source state\n".utf8).write(to: filtered)
        let manager = WorktreeManager(managedRoot: fixture.worktreeRoot)

        do {
            _ = try await manager.prepare(
                taskID: UUID(),
                projectPath: fixture.repository.path,
                configuration: TaskWorkspaceConfiguration(kind: .worktree)
            )
            XCTFail("Expected a target-dependent clean filter to fail baseline verification")
        } catch let error as WorktreeManagerError {
            guard case let .capturedStatePreserved(path, _, reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("内容指纹"), reason)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            XCTAssertFalse(
                try fixture.git(["-C", path, "log", "-1", "--format=%B"])
                    .contains("CodexBoard-Owner-Task")
            )
        }
    }

    func testPrepareRejectsUntrackedSymbolicLinkAndForeignBranchName() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let manager = WorktreeManager(managedRoot: fixture.worktreeRoot)
        let link = fixture.repository.appendingPathComponent("outside-link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: fixture.repository.appendingPathComponent("README.md")
        )

        do {
            _ = try await manager.prepare(
                taskID: UUID(),
                projectPath: fixture.repository.path,
                configuration: TaskWorkspaceConfiguration(kind: .worktree)
            )
            XCTFail("Expected a symbolic link to be rejected")
        } catch let error as WorktreeManagerError {
            guard case .unsupportedUntrackedFile = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        try FileManager.default.removeItem(at: link)
        do {
            _ = try await manager.prepare(
                taskID: UUID(),
                projectPath: fixture.repository.path,
                configuration: TaskWorkspaceConfiguration(kind: .worktree, branch: "--help")
            )
            XCTFail("Expected a foreign branch name to be rejected")
        } catch let error as WorktreeManagerError {
            guard case .invalidPreparationEvidence = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCleanupRequiresMatchingOwnerBranchAndGitRegistration() async throws {
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
        let evidence = try XCTUnwrap(prepared.preparation)

        let foreignOwner = TaskWorktreePreparation(
            capability: evidence.capability,
            ownerTaskID: UUID(),
            repositoryPath: evidence.repositoryPath,
            sourceCommit: evidence.sourceCommit,
            baselineCommit: evidence.baselineCommit,
            dirtyBaseCaptured: evidence.dirtyBaseCaptured,
            untrackedFilesCaptured: evidence.untrackedFilesCaptured,
            preparedAt: evidence.preparedAt
        )
        do {
            _ = try await manager.cleanup(
                taskID: taskID,
                projectPath: fixture.repository.path,
                configuration: TaskWorkspaceConfiguration(
                    kind: .worktree,
                    path: path,
                    branch: prepared.branch,
                    baseBranch: prepared.baseBranch,
                    preparation: foreignOwner
                ),
                requiredCapability: .managedV1
            )
            XCTFail("Expected a foreign owner to be rejected")
        } catch let error as WorktreeManagerError {
            guard case .invalidPreparationEvidence = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let legacyBranch = "codex/task-\(taskID.uuidString.prefix(8).lowercased())"
        do {
            _ = try await manager.cleanup(
                taskID: taskID,
                projectPath: fixture.repository.path,
                configuration: TaskWorkspaceConfiguration(
                    kind: .worktree,
                    path: path,
                    branch: legacyBranch,
                    baseBranch: prepared.baseBranch,
                    preparation: evidence
                ),
                requiredCapability: .managedV1
            )
            XCTFail("Expected a mismatched branch to be rejected")
        } catch let error as WorktreeManagerError {
            guard case .branchMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        _ = try fixture.git([
            "-C", fixture.repository.path, "worktree", "remove", "--force", path,
        ])
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path, isDirectory: true),
            withIntermediateDirectories: true
        )
        let sentinel = URL(fileURLWithPath: path).appendingPathComponent("foreign.txt")
        try Data("keep".utf8).write(to: sentinel)
        do {
            _ = try await manager.cleanup(
                taskID: taskID,
                projectPath: fixture.repository.path,
                configuration: prepared,
                requiredCapability: .managedV1
            )
            XCTFail("Expected a missing Git registration to be rejected")
        } catch let error as WorktreeManagerError {
            guard case .invalidManagedPath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testCleanupDoesNotForgetWorktreeMovedToAnotherRegisteredPath() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let manager = WorktreeManager(managedRoot: fixture.worktreeRoot)
        let taskID = UUID()
        let prepared = try await manager.prepare(
            taskID: taskID,
            projectPath: fixture.repository.path,
            configuration: TaskWorkspaceConfiguration(kind: .worktree)
        )
        let originalPath = try XCTUnwrap(prepared.path)
        let movedPath = fixture.root.appendingPathComponent("externally-moved", isDirectory: true)
        _ = try fixture.git([
            "-C", fixture.repository.path,
            "worktree", "move", originalPath, movedPath.path,
        ])

        do {
            _ = try await manager.cleanup(
                taskID: taskID,
                projectPath: fixture.repository.path,
                configuration: prepared,
                requiredCapability: .managedV1
            )
            XCTFail("Expected a moved task worktree to fail closed")
        } catch let error as WorktreeManagerError {
            guard case .invalidManagedPath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedPath.path))
        let branch = try XCTUnwrap(prepared.branch)
        XCTAssertEqual(
            try fixture.git(["-C", movedPath.path, "branch", "--show-current"]),
            branch
        )
    }

    private func preservedCapturePath(
        manager: WorktreeManager,
        fixture: GitFixture
    ) async throws -> String {
        do {
            _ = try await manager.prepare(
                taskID: UUID(),
                projectPath: fixture.repository.path,
                configuration: TaskWorkspaceConfiguration(kind: .worktree)
            )
            XCTFail("Expected a concurrent source change to fail preparation")
            throw NSError(domain: "WorktreeManagerTests", code: 1)
        } catch let error as WorktreeManagerError {
            guard case let .capturedStatePreserved(path, _, _) = error else {
                XCTFail("Unexpected error: \(error)")
                throw error
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            return path
        }
    }
}

private enum GitFixtureMutation {
    case write(String, to: URL)
    case emptyCommit(in: URL)
}

private final class GitFixture {
    let root: URL
    let repository: URL
    let worktreeRoot: URL

    init(makeInitialCommit: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        repository = root.appendingPathComponent("repository", isDirectory: true)
        worktreeRoot = root.appendingPathComponent("managed-worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        _ = try git(["-C", repository.path, "init", "-b", "main"])
        _ = try git(["-C", repository.path, "config", "user.email", "codexboard@example.test"])
        _ = try git(["-C", repository.path, "config", "user.name", "CodexBoard Tests"])
        if makeInitialCommit {
            try Data("fixture\n".utf8).write(to: repository.appendingPathComponent("README.md"))
            _ = try git(["-C", repository.path, "add", "README.md"])
            _ = try git(["-C", repository.path, "commit", "-m", "Initial"])
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func git(_ arguments: [String]) throws -> String {
        String(decoding: try gitData(arguments), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func gitData(_ arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
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

    func indexData() throws -> Data {
        let rawPath = try git(["-C", repository.path, "rev-parse", "--git-path", "index"])
        let indexURL: URL
        if rawPath.hasPrefix("/") {
            indexURL = URL(fileURLWithPath: rawPath)
        } else {
            indexURL = repository.appendingPathComponent(rawPath)
        }
        return try Data(contentsOf: indexURL)
    }

    func managedWorktreePath(taskID: UUID) -> URL {
        let repositoryPath = repository.resolvingSymlinksInPath().path
        let name = repository.lastPathComponent
            .replacingOccurrences(
                of: "[^A-Za-z0-9._-]",
                with: "-",
                options: .regularExpression
            )
        let hash = repositoryPath.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return worktreeRoot
            .appendingPathComponent("\(name)-\(String(hash, radix: 16))", isDirectory: true)
            .appendingPathComponent(taskID.uuidString.lowercased(), isDirectory: true)
    }

    func makeMutatingGitWrapper(_ mutations: [GitFixtureMutation]) throws -> URL {
        let wrapper = root.appendingPathComponent("mutating-git")
        let marker = root.appendingPathComponent("mutation-fired")
        let mutationLines = mutations.map { mutation in
            switch mutation {
            case let .write(contents, url):
                return "printf %s \(shellQuote(contents)) > \(shellQuote(url.path))"
            case let .emptyCommit(repository):
                return "/usr/bin/git -C \(shellQuote(repository.path)) commit --allow-empty -m \(shellQuote("Concurrent source commit")) >/dev/null 2>&1"
            }
        }
        let script = """
        #!/bin/sh
        set -eu
        case " $* " in
          *" commit "*)
            if [ ! -e \(shellQuote(marker.path)) ]; then
              : > \(shellQuote(marker.path))
              \(mutationLines.joined(separator: "\n              "))
            fi
            ;;
        esac
        exec /usr/bin/git "$@"
        """
        try Data(script.utf8).write(to: wrapper, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: wrapper.path
        )
        return wrapper
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
