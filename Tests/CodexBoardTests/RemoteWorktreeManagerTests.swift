import Foundation
import XCTest
@testable import CodexBoard

@MainActor
final class RemoteWorktreeManagerTests: XCTestCase {
    func testManagedWorktreeCapabilityUsesExactSemanticToken() {
        XCTAssertEqual(
            WorktreeCapability.managedV1.token,
            "codexboard-managed-worktree-v1"
        )
    }

    func testManagedCommandExecParametersAreArgvBoundedOfflineAndRootScoped() throws {
        let value = try CodexAppServerClient.managedWorktreeCommandExecParams(
            CodexManagedWorktreeCommand(
                arguments: [
                    "git", "-C", "/srv/repo with spaces;literal", "worktree", "add",
                    "/srv/codexboard/worktrees/task-1"
                ],
                projectPath: "/srv/repo with spaces;literal",
                cwd: "/srv/codexboard/worktrees",
                writableRoots: [
                    "/srv/codexboard/worktrees",
                    "/srv/repo with spaces;literal/.git"
                ],
                timeoutMilliseconds: 45_000,
                outputBytesCap: 16_384
            )
        )

        XCTAssertEqual(value["command"]?.arrayValue?.compactMap(\.stringValue), [
            "git", "-C", "/srv/repo with spaces;literal", "worktree", "add",
            "/srv/codexboard/worktrees/task-1"
        ])
        XCTAssertEqual(value["cwd"]?.stringValue, "/srv/codexboard/worktrees")
        XCTAssertEqual(value["timeoutMs"]?.intValue, 45_000)
        XCTAssertEqual(value["outputBytesCap"]?.intValue, 16_384)
        XCTAssertEqual(value["sandboxPolicy"]?["type"]?.stringValue, "workspaceWrite")
        XCTAssertEqual(value["sandboxPolicy"]?["networkAccess"]?.boolValue, false)
        XCTAssertEqual(
            value["sandboxPolicy"]?["writableRoots"]?.arrayValue?.compactMap(\.stringValue),
            ["/srv/codexboard/worktrees", "/srv/repo with spaces;literal/.git"]
        )
        XCTAssertEqual(value["sandboxPolicy"]?["excludeSlashTmp"]?.boolValue, true)
        XCTAssertEqual(value["sandboxPolicy"]?["excludeTmpdirEnvVar"]?.boolValue, true)
        XCTAssertEqual(value["env"]?["GIT_TERMINAL_PROMPT"]?.stringValue, "0")
        XCTAssertEqual(value["env"]?["GIT_DIR"], .null)
        XCTAssertNil(value["permissionProfile"])
        XCTAssertNil(value["disableTimeout"])
        XCTAssertNil(value["disableOutputCap"])
    }

    func testManagedCommandCapabilityProbeUsesProjectPathInsteadOfWorktreeCWD() throws {
        let command = CodexManagedWorktreeCommand(
            arguments: ["git", "status", "--porcelain"],
            projectPath: "/srv/repo",
            cwd: "/srv/codexboard/worktrees/task-1",
            writableRoots: [
                "/srv/codexboard/worktrees",
                "/srv/repo/.git"
            ]
        )

        XCTAssertEqual(
            try CodexAppServerClient.managedWorktreeCapabilityProbePath(command),
            "/srv/repo"
        )
        XCTAssertEqual(
            try CodexAppServerClient.managedWorktreeCommandExecParams(command)["cwd"]?.stringValue,
            "/srv/codexboard/worktrees/task-1"
        )
    }

    func testManagedCommandValidationRejectsBroadOrUnrelatedWriteScope() {
        assertInvalidCommand(
            CodexManagedWorktreeCommand(
                arguments: ["git", "status"],
                projectPath: "/srv/repo",
                cwd: "/srv/repo",
                writableRoots: ["/"]
            )
        )
        assertInvalidCommand(
            CodexManagedWorktreeCommand(
                arguments: ["git", "status"],
                projectPath: "/srv/repo",
                cwd: "/srv/repo",
                writableRoots: ["/srv/other"]
            )
        )
        assertInvalidCommand(
            CodexManagedWorktreeCommand(
                arguments: ["git", "status"],
                projectPath: "/srv/repo",
                cwd: "/srv/repo",
                writableRoots: ["/srv/repo"]
            )
        )
        assertInvalidCommand(
            CodexManagedWorktreeCommand(
                arguments: ["git", "status"],
                projectPath: "/srv/repo",
                cwd: "/srv/repo/Sources",
                writableRoots: ["/srv/repo/Sources"]
            )
        )
        assertInvalidCommand(
            CodexManagedWorktreeCommand(
                arguments: ["sh", "-c", "git status"],
                projectPath: "/srv/repo",
                cwd: "/srv/codexboard/worktrees",
                writableRoots: ["/srv/codexboard/worktrees", "/srv/repo/.git"]
            )
        )
        assertInvalidCommand(
            CodexManagedWorktreeCommand(
                arguments: ["git", "status"],
                projectPath: "/srv/repo",
                cwd: "/srv/codexboard/worktrees/task-1",
                writableRoots: [
                    "/srv/codexboard/worktrees",
                    "/srv/repo/.git",
                    "/etc"
                ]
            )
        )
        assertInvalidCommand(
            CodexManagedWorktreeCommand(
                arguments: ["git", "-c", "alias.pwn=!sh", "pwn"],
                projectPath: "/srv/repo",
                cwd: "/srv/codexboard/worktrees",
                writableRoots: ["/srv/codexboard/worktrees", "/srv/repo/.git"]
            )
        )
        assertInvalidCommand(
            CodexManagedWorktreeCommand(
                arguments: ["git", "status"],
                projectPath: "/srv/repo",
                cwd: "/srv/codexboard/worktrees",
                writableRoots: ["/srv/codexboard/worktrees", "/srv/repo/.git"],
                timeoutMilliseconds: CodexManagedWorktreeCommand.maximumTimeoutMilliseconds + 1
            )
        )
        assertInvalidCommand(
            CodexManagedWorktreeCommand(
                arguments: ["git", "status"],
                projectPath: "/srv/repo",
                cwd: "/srv/codexboard/worktrees",
                writableRoots: ["/srv/codexboard/worktrees", "/srv/repo/.git"],
                outputBytesCap: CodexManagedWorktreeCommand.maximumOutputBytes + 1
            )
        )
        assertInvalidCommand(
            CodexManagedWorktreeCommand(
                arguments: ["git", "status\nnext-command"],
                projectPath: "/srv/repo",
                cwd: "/srv/codexboard/worktrees",
                writableRoots: ["/srv/codexboard/worktrees", "/srv/repo/.git"]
            )
        )
    }

    func testManagedCommandResultParserRejectsMalformedOrOversizedOutput() throws {
        let parsed = try CodexAppServerClient.parseManagedWorktreeCommandResult(
            .object([
                "exitCode": .integer(0),
                "stdout": .string("ok\n"),
                "stderr": .string("")
            ]),
            outputBytesCap: 8
        )
        XCTAssertEqual(
            parsed,
            CodexManagedWorktreeCommandResult(exitCode: 0, stdout: "ok\n", stderr: "")
        )

        XCTAssertThrowsError(try CodexAppServerClient.parseManagedWorktreeCommandResult(
            .object([
                "exitCode": .integer(0),
                "stdout": .string("123456789"),
                "stderr": .string("")
            ]),
            outputBytesCap: 8
        ))
        XCTAssertThrowsError(try CodexAppServerClient.parseManagedWorktreeCommandResult(
            .object([
                "exitCode": .integer(Int64(Int32.max) + 1),
                "stdout": .string(""),
                "stderr": .string("")
            ]),
            outputBytesCap: 8
        ))
    }

    func testAppServerClientKeepsCapabilityUnsupportedWithoutExplicitAcknowledgement() async throws {
        let fixture = try UnsupportedCapabilityServer()
        defer { fixture.remove() }
        let client = CodexAppServerClient(
            requestTimeout: 2,
            transportFactory: {
                AppServerTransport(executableURL: fixture.executableURL)
            }
        )
        defer { client.disconnect() }

        let capabilities = try await client.advertisedRemoteWorktreeCapabilities(
            projectPath: "/srv/repo"
        )
        XCTAssertTrue(capabilities.isEmpty)

        do {
            _ = try await client.executeManagedWorktreeCommand(
                CodexManagedWorktreeCommand(
                    arguments: ["git", "-C", "/srv/repo", "status"],
                    projectPath: "/srv/repo",
                    cwd: "/srv/codexboard/worktrees",
                    writableRoots: ["/srv/codexboard/worktrees", "/srv/repo/.git"]
                )
            )
            XCTFail("Expected an unacknowledged write capability to be rejected")
        } catch let error as RemoteWorktreeManagerError {
            guard case let .capabilityUnsupported(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("codexboard-managed-worktree-v1"))
        }

        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.commandMarkerURL.path))
    }

    func testRemoteManagerDoesNotSurfacePartialBackendAsSupported() async {
        let client = CapabilityAdvertisingClient(capabilities: [.managedV1])
        let manager = RemoteWorktreeManager(client: client)

        let availability = await manager.capability(
            projectPath: "/srv/repo/./",
            requiredCapability: .managedV1
        )

        guard case let .unsupported(reason) = availability else {
            return XCTFail("A partial remote backend must never be advertised as supported")
        }
        XCTAssertTrue(reason.contains("codexboard-managed-worktree-v1"))
        XCTAssertTrue(reason.contains("原子"))
        XCTAssertEqual(client.probedProjectPaths, ["/srv/repo"])
    }

    func testRemoteManagerDistinguishesMissingAcknowledgementFromProbeFailure() async {
        let unsupportedClient = CapabilityAdvertisingClient(capabilities: [])
        let unsupportedManager = RemoteWorktreeManager(client: unsupportedClient)
        let unsupported = await unsupportedManager.capability(
            projectPath: "/srv/repo",
            requiredCapability: .managedV1
        )
        guard case let .unsupported(reason) = unsupported else {
            return XCTFail("A missing semantic acknowledgement must be unsupported")
        }
        XCTAssertTrue(reason.contains("codexboard-managed-worktree-v1"))

        let unavailableClient = CapabilityAdvertisingClient(
            capabilities: [],
            probeFails: true
        )
        let unavailableManager = RemoteWorktreeManager(client: unavailableClient)
        let unavailable = await unavailableManager.capability(
            projectPath: "/srv/repo",
            requiredCapability: .managedV1
        )
        guard case let .unavailable(reason) = unavailable else {
            return XCTFail("A transport failure must be unavailable, not unsupported")
        }
        XCTAssertTrue(reason.contains("探测失败"))
    }

    private func assertInvalidCommand(
        _ command: CodexManagedWorktreeCommand,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try CodexAppServerClient.managedWorktreeCommandExecParams(command),
            file: file,
            line: line
        )
    }
}

@MainActor
private final class CapabilityAdvertisingClient: CodexTaskClient {
    let events = AsyncStream<CodexEvent> { continuation in continuation.finish() }
    var connectionState: CodexConnectionState = .connected
    let capabilities: Set<WorktreeCapability>
    let probeFails: Bool
    private(set) var probedProjectPaths: [String] = []

    init(capabilities: Set<WorktreeCapability>, probeFails: Bool = false) {
        self.capabilities = capabilities
        self.probeFails = probeFails
    }

    func advertisedRemoteWorktreeCapabilities(
        projectPath: String
    ) async throws -> Set<WorktreeCapability> {
        probedProjectPaths.append(projectPath)
        if probeFails {
            throw CodexClientError.disconnected
        }
        return capabilities
    }

    func connect() async throws {}
    func verifyAccount() async throws -> Bool { true }
    func listModels() async throws -> [CodexModel] { [] }
    func listSkills(
        cwds _: [String],
        forceReload _: Bool
    ) async throws -> [String: [CodexSkillMetadata]] {
        [:]
    }
    func listApps(forceRefresh _: Bool) async throws -> [CodexApp] { [] }
    func listMCPServers(threadID _: String?) async throws -> [CodexMCPServerStatus] { [] }
    func beginMCPOAuth(serverName _: String, threadID _: String?) async throws -> URL {
        throw CodexClientError.invalidResponse("unused test operation")
    }
    func respond(
        to _: CodexRequestID,
        with _: CodexInteractionResponse
    ) async throws {}
    func listThreads(cursor _: String?, archived _: Bool) async throws -> CodexThreadPage {
        CodexThreadPage(threads: [], nextCursor: nil)
    }
    func startThread(
        cwd _: String,
        model _: String?,
        serviceTier _: String
    ) async throws -> CodexStartedThread {
        throw CodexClientError.invalidResponse("unused test operation")
    }
    func resumeThread(threadID _: String, cwd _: String) async throws -> CodexStartedThread {
        throw CodexClientError.invalidResponse("unused test operation")
    }
    func setThreadName(threadID _: String, name _: String) async throws {}
    func startPlanningTurn(
        threadID _: String,
        cwd _: String,
        input _: [CodexTurnInput],
        model _: String,
        effort _: ReasoningEffort,
        serviceTier _: String
    ) async throws -> CodexStartedTurn {
        throw CodexClientError.invalidResponse("unused test operation")
    }
    func startExecutionTurn(
        threadID _: String,
        cwd _: String,
        input _: [CodexTurnInput],
        model _: String,
        effort _: ReasoningEffort,
        serviceTier _: String,
        allowNetwork _: Bool
    ) async throws -> CodexStartedTurn {
        throw CodexClientError.invalidResponse("unused test operation")
    }
    func interrupt(threadID _: String, turnID _: String) async throws {}
}

private struct UnsupportedCapabilityServer {
    let directory: URL
    let executableURL: URL
    let commandMarkerURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteWorktreeManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executableURL = directory.appendingPathComponent("codex")
        commandMarkerURL = directory.appendingPathComponent("command-received")
        let script = """
        #!/bin/sh
        IFS= read -r initialize
        printf '{"id":1,"result":{}}\\n'
        IFS= read -r initialized
        if IFS= read -r command_request; then
          : > '\(commandMarkerURL.path)'
          printf '{"id":2,"result":{"exitCode":0,"stdout":"","stderr":""}}\\n'
        fi
        while IFS= read -r ignored; do :; done
        """
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
