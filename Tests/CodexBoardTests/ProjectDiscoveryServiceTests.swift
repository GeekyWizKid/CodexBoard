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
