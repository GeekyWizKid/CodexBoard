import Foundation
import XCTest
@testable import CodexBoard

final class ProjectDiscoveryServiceTests: XCTestCase {
    func testAggregatesGitWorkingDirectoriesAndManualSymlink() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let repository = temporaryDirectory.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try runGit(["init", "--quiet"], in: repository)

        let sources = repository.appendingPathComponent("Sources/Feature", isDirectory: true)
        let tests = repository.appendingPathComponent("Tests", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)

        let repositoryAlias = temporaryDirectory.appendingPathComponent("Project Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: repositoryAlias,
            withDestinationURL: repository
        )

        let olderDate = Date(timeIntervalSince1970: 100)
        let newerDate = Date(timeIntervalSince1970: 200)
        let threads = [
            makeThread(id: "older", cwd: sources.path, updatedAt: olderDate, status: "completed"),
            makeThread(
                id: "newer",
                cwd: repositoryAlias.appendingPathComponent("Tests").path,
                updatedAt: newerDate,
                status: "active"
            )
        ]

        let projects = await ProjectDiscoveryService().discover(
            threads: threads,
            manualPaths: [repositoryAlias.path]
        )

        let project = try XCTUnwrap(projects.first)
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(project.id, repository.resolvingSymlinksInPath().path)
        XCTAssertEqual(project.name, "Project")
        XCTAssertEqual(project.path, repository.resolvingSymlinksInPath().path)
        XCTAssertEqual(
            project.observedWorkingDirectories,
            [tests.resolvingSymlinksInPath().path, sources.resolvingSymlinksInPath().path]
        )
        XCTAssertEqual(project.manualPaths, [repository.resolvingSymlinksInPath().path])
        XCTAssertEqual(project.latestActivityAt, newerDate)
        XCTAssertEqual(project.threadCount, 2)
        XCTAssertEqual(project.activeThreadCount, 1)
        XCTAssertTrue(project.isGitRepository)
        XCTAssertTrue(project.existsOnDisk)
        XCTAssertTrue(project.isManual)
    }

    func testKeepsMissingPathsAndDoesNotDiscoverNestedRepositories() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let ordinaryDirectory = temporaryDirectory.appendingPathComponent("Ordinary", isDirectory: true)
        let nestedRepository = ordinaryDirectory.appendingPathComponent("NestedRepository", isDirectory: true)
        let recentDirectory = temporaryDirectory.appendingPathComponent("Recent", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedRepository, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recentDirectory, withIntermediateDirectories: true)
        try runGit(["init", "--quiet"], in: nestedRepository)

        let ordinaryAlias = temporaryDirectory.appendingPathComponent("Ordinary Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: ordinaryAlias,
            withDestinationURL: ordinaryDirectory
        )
        let missingDirectory = temporaryDirectory.appendingPathComponent("Missing", isDirectory: true)

        let threads = [
            makeThread(
                id: "recent",
                cwd: recentDirectory.path,
                updatedAt: Date(timeIntervalSince1970: 300),
                status: "active"
            ),
            makeThread(
                id: "missing",
                cwd: missingDirectory.path,
                updatedAt: Date(timeIntervalSince1970: 200),
                status: "completed"
            )
        ]

        let projects = await ProjectDiscoveryService().discover(
            threads: threads,
            manualPaths: [ordinaryAlias.path, "  ", ordinaryDirectory.path]
        )

        XCTAssertEqual(
            projects.map(\.path),
            [
                recentDirectory.resolvingSymlinksInPath().path,
                missingDirectory.standardizedFileURL.path,
                ordinaryDirectory.resolvingSymlinksInPath().path
            ]
        )

        let missingProject = try XCTUnwrap(
            projects.first { $0.path == missingDirectory.standardizedFileURL.path }
        )
        XCTAssertFalse(missingProject.existsOnDisk)
        XCTAssertFalse(missingProject.isGitRepository)
        XCTAssertEqual(missingProject.threadCount, 1)

        let ordinaryProject = try XCTUnwrap(
            projects.first { $0.path == ordinaryDirectory.resolvingSymlinksInPath().path }
        )
        XCTAssertTrue(ordinaryProject.existsOnDisk)
        XCTAssertFalse(ordinaryProject.isGitRepository)
        XCTAssertTrue(ordinaryProject.isManual)
        XCTAssertEqual(ordinaryProject.threadCount, 0)
        XCTAssertEqual(ordinaryProject.observedWorkingDirectories, [])
        XCTAssertEqual(ordinaryProject.manualPaths, [ordinaryDirectory.resolvingSymlinksInPath().path])
        XCTAssertNil(
            projects.first { $0.path == nestedRepository.resolvingSymlinksInPath().path },
            "The service must not scan children looking for repositories"
        )
    }

    func testPreservesDistinctGitWorktreeCheckoutRoots() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let primaryCheckout = temporaryDirectory.appendingPathComponent("Primary", isDirectory: true)
        let linkedCheckout = temporaryDirectory.appendingPathComponent("Linked", isDirectory: true)
        try FileManager.default.createDirectory(at: primaryCheckout, withIntermediateDirectories: true)
        try runGit(["init", "--quiet"], in: primaryCheckout)
        try runGit(
            [
                "-c", "user.name=CodexBoard Tests",
                "-c", "user.email=codexboard-tests@example.invalid",
                "commit", "--quiet", "--allow-empty", "-m", "Initial"
            ],
            in: primaryCheckout
        )
        try runGit(
            ["worktree", "add", "--quiet", "-b", "codexboard-linked", linkedCheckout.path],
            in: primaryCheckout
        )

        let primarySubdirectory = primaryCheckout.appendingPathComponent("Sources", isDirectory: true)
        let linkedSubdirectory = linkedCheckout.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: primarySubdirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linkedSubdirectory, withIntermediateDirectories: true)

        let projects = await ProjectDiscoveryService().discover(
            threads: [
                makeThread(
                    id: "linked",
                    cwd: linkedSubdirectory.path,
                    updatedAt: Date(timeIntervalSince1970: 400),
                    status: "active"
                ),
                makeThread(
                    id: "primary",
                    cwd: primarySubdirectory.path,
                    updatedAt: Date(timeIntervalSince1970: 300),
                    status: "completed"
                )
            ],
            manualPaths: []
        )

        XCTAssertEqual(
            projects.map(\.path),
            [
                linkedCheckout.resolvingSymlinksInPath().path,
                primaryCheckout.resolvingSymlinksInPath().path
            ]
        )
        XCTAssertTrue(projects.allSatisfy(\.isGitRepository))
        XCTAssertEqual(projects.map(\.threadCount), [1, 1])
    }

    func testGitProbeTimesOutAndKeepsProjectUsable() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let repository = temporaryDirectory.appendingPathComponent("SlowRepository", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let fakeGit = temporaryDirectory.appendingPathComponent("slow-git")
        try Data("#!/bin/sh\nexec /bin/sleep 5\n".utf8).write(to: fakeGit)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fakeGit.path
        )

        let startedAt = Date()
        let projects = await ProjectDiscoveryService(
            gitExecutableURL: fakeGit,
            gitProbeTimeout: 0.05
        ).discover(
            threads: [
                makeThread(
                    id: "slow",
                    cwd: repository.path,
                    updatedAt: Date(),
                    status: "completed"
                )
            ],
            manualPaths: []
        )

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        let project = try XCTUnwrap(projects.first)
        XCTAssertEqual(project.path, repository.path)
        XCTAssertTrue(project.existsOnDisk)
        XCTAssertFalse(project.isGitRepository)
    }

    func testRemoteDiscoveryNamespacesProjectsAndNeverUsesLocalFilesystemState() async throws {
        let remotePath = "/srv/work/shared-app"
        let service = ProjectDiscoveryService()
        let first = await service.discover(
            threads: [
                makeThread(
                    id: "remote-a",
                    cwd: remotePath,
                    updatedAt: Date(timeIntervalSince1970: 500),
                    status: "active"
                )
            ],
            manualPaths: ["relative/is/not/a/remote/cwd"],
            hostID: "ssh:build-a",
            isRemote: true,
            remotePathInfo: [
                remotePath: CodexProjectPathInfo(
                    canonicalWorkingDirectory: remotePath,
                    projectPath: remotePath,
                    exists: true,
                    isGitRepository: false
                )
            ]
        )
        let second = await service.discover(
            threads: [],
            manualPaths: [remotePath],
            hostID: "ssh:build-b",
            isRemote: true,
            remotePathInfo: [
                remotePath: CodexProjectPathInfo(
                    canonicalWorkingDirectory: remotePath,
                    projectPath: remotePath,
                    exists: true,
                    isGitRepository: false
                )
            ]
        )

        let firstProject = try XCTUnwrap(first.first)
        let secondProject = try XCTUnwrap(second.first)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(firstProject.path, remotePath)
        XCTAssertEqual(secondProject.path, remotePath)
        XCTAssertEqual(firstProject.hostID, "ssh:build-a")
        XCTAssertEqual(secondProject.hostID, "ssh:build-b")
        XCTAssertNotEqual(firstProject.id, secondProject.id)
        XCTAssertTrue(firstProject.existsOnDisk)
        XCTAssertFalse(firstProject.isGitRepository)
        XCTAssertEqual(firstProject.activeThreadCount, 1)
    }

    func testRemoteGitSubdirectoriesCollapseToCanonicalWorktreeRoot() async throws {
        let root = "/srv/repo"
        let subdirectory = "/srv/repo/Sources/Feature"
        let projects = await ProjectDiscoveryService().discover(
            threads: [
                makeThread(
                    id: "root",
                    cwd: root,
                    updatedAt: Date(timeIntervalSince1970: 600),
                    status: "completed"
                ),
                makeThread(
                    id: "subdirectory",
                    cwd: subdirectory,
                    updatedAt: Date(timeIntervalSince1970: 700),
                    status: "active"
                )
            ],
            manualPaths: [subdirectory],
            hostID: "ssh:worker",
            isRemote: true,
            remotePathInfo: [
                root: CodexProjectPathInfo(
                    canonicalWorkingDirectory: root,
                    projectPath: root,
                    exists: true,
                    isGitRepository: true
                ),
                subdirectory: CodexProjectPathInfo(
                    canonicalWorkingDirectory: subdirectory,
                    projectPath: root,
                    exists: true,
                    isGitRepository: true
                )
            ]
        )

        let project = try XCTUnwrap(projects.first)
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(project.path, root)
        XCTAssertEqual(project.threadCount, 2)
        XCTAssertEqual(project.activeThreadCount, 1)
        XCTAssertTrue(project.isGitRepository)
        XCTAssertEqual(project.observedWorkingDirectories, [subdirectory, root])
        XCTAssertEqual(project.manualPaths, [subdirectory])
    }

    func testOfflineRemotePathRemainsVisibleButUnavailable() async throws {
        let projects = await ProjectDiscoveryService().discover(
            threads: [],
            manualPaths: ["/srv/offline"],
            hostID: "ssh:offline",
            isRemote: true
        )
        let project = try XCTUnwrap(projects.first)

        XCTAssertEqual(project.path, "/srv/offline")
        XCTAssertEqual(project.manualPaths, ["/srv/offline"])
        XCTAssertTrue(project.isManual)
        XCTAssertFalse(project.existsOnDisk)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBoardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeThread(
        id: String,
        cwd: String,
        updatedAt: Date,
        status: String
    ) -> CodexThreadSummary {
        CodexThreadSummary(
            id: id,
            sessionID: "session-\(id)",
            cwd: cwd,
            name: nil,
            createdAt: updatedAt.addingTimeInterval(-10),
            updatedAt: updatedAt,
            isPinned: false,
            statusType: status,
            sourceKind: "cli"
        )
    }

    private func runGit(_ arguments: [String], in workingDirectory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", workingDirectory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        let standardError = Pipe()
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()

        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            let error = String(data: errorData, encoding: .utf8) ?? ""
            throw NSError(
                domain: "ProjectDiscoveryServiceTests.Git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: error]
            )
        }
    }
}
