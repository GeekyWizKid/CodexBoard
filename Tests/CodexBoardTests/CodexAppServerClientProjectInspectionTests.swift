import Foundation
import XCTest
@testable import CodexBoard

@MainActor
final class CodexAppServerClientProjectInspectionTests: XCTestCase {
    func testReadOnlyCommandExecParametersAreBoundedAndDoNotUseAShell() throws {
        let value = CodexAppServerClient.readOnlyCommandExecParams(
            command: ["git", "-C", "/srv/repo;literal", "rev-parse", "--show-toplevel"],
            cwd: "/srv/repo;literal"
        )

        XCTAssertEqual(value["command"]?.arrayValue?.compactMap(\.stringValue), [
            "git", "-C", "/srv/repo;literal", "rev-parse", "--show-toplevel"
        ])
        XCTAssertEqual(value["cwd"]?.stringValue, "/srv/repo;literal")
        XCTAssertEqual(value["timeoutMs"]?.intValue, 3_000)
        XCTAssertEqual(value["outputBytesCap"]?.intValue, 8_192)
        XCTAssertEqual(value["sandboxPolicy"]?["type"]?.stringValue, "readOnly")
        XCTAssertEqual(value["sandboxPolicy"]?["networkAccess"]?.boolValue, false)
        XCTAssertEqual(value["env"]?["GIT_OPTIONAL_LOCKS"]?.stringValue, "0")
        XCTAssertEqual(value["env"]?["GIT_TERMINAL_PROMPT"]?.stringValue, "0")
        XCTAssertEqual(value["env"]?["GIT_DIR"], .null)
    }

    func testInspectProjectPathUsesBoundedReadOnlyCommandExecAndPreservesPathSpaces() async throws {
        let fixture = try FakeCommandExecServer(
            pwdOutput: "/srv/repo \n",
            gitExitCode: 0,
            gitOutput: "/srv\n"
        )
        defer { fixture.remove() }
        let client = fixture.makeClient()
        defer { client.disconnect() }

        let information = try await client.inspectProjectPath("/srv/repo ")

        XCTAssertEqual(information.canonicalWorkingDirectory, "/srv/repo ")
        XCTAssertEqual(information.projectPath, "/srv")
        XCTAssertTrue(information.exists)
        XCTAssertTrue(information.isGitRepository)
    }

    func testInspectProjectPathNeverPromotesFilesystemRootFromGit() async throws {
        let fixture = try FakeCommandExecServer(
            pwdOutput: "/srv/repo\n",
            gitExitCode: 0,
            gitOutput: "/\n"
        )
        defer { fixture.remove() }
        let client = fixture.makeClient()
        defer { client.disconnect() }

        let information = try await client.inspectProjectPath("/srv/repo")

        XCTAssertEqual(information.canonicalWorkingDirectory, "/srv/repo")
        XCTAssertEqual(information.projectPath, "/srv/repo")
        XCTAssertTrue(information.exists)
        XCTAssertFalse(information.isGitRepository)
    }

    func testInspectProjectPathRejectsFilesystemRootWithoutRunningAProbe() async throws {
        let fixture = try FakeCommandExecServer(
            pwdOutput: "/should-not-be-used\n",
            gitExitCode: 0,
            gitOutput: "/should-not-be-used\n"
        )
        defer { fixture.remove() }
        let client = fixture.makeClient()
        defer { client.disconnect() }

        let information = try await client.inspectProjectPath("/")

        XCTAssertEqual(information.canonicalWorkingDirectory, "/")
        XCTAssertEqual(information.projectPath, "/")
        XCTAssertFalse(information.exists)
        XCTAssertFalse(information.isGitRepository)
    }

    func testInspectProjectPathRejectsPathWhosePhysicalDirectoryIsRoot() async throws {
        let fixture = try FakeCommandExecServer(
            pwdOutput: "/\n",
            gitExitCode: 0,
            gitOutput: "/\n"
        )
        defer { fixture.remove() }
        let client = fixture.makeClient()
        defer { client.disconnect() }

        let information = try await client.inspectProjectPath("/srv/root-link")

        XCTAssertEqual(information.canonicalWorkingDirectory, "/")
        XCTAssertEqual(information.projectPath, "/")
        XCTAssertFalse(information.exists)
        XCTAssertFalse(information.isGitRepository)
    }

    func testInspectProjectPathCommandExecStillHasClientTimeout() async throws {
        let fixture = try FakeCommandExecServer(
            pwdOutput: "/srv/repo\n",
            gitExitCode: 0,
            gitOutput: "/srv/repo\n",
            pwdDelaySeconds: 2
        )
        defer { fixture.remove() }
        let client = fixture.makeClient(requestTimeout: 1)
        defer { client.disconnect() }

        do {
            _ = try await client.inspectProjectPath("/srv/repo")
            XCTFail("Expected command/exec to time out")
        } catch {
            XCTAssertEqual(error as? CodexClientError, .requestTimedOut("command/exec"))
        }
    }
}

private struct FakeCommandExecServer {
    let directory: URL
    let executableURL: URL

    init(
        pwdOutput: String,
        gitExitCode: Int,
        gitOutput: String,
        pwdDelaySeconds: Int = 0
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAppServerClientProjectInspectionTests-\(UUID().uuidString)", isDirectory: true)
        let executableDirectory = directory.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        executableURL = executableDirectory.appendingPathComponent("codex")

        let pwdJSON = try Self.jsonString(pwdOutput)
        let gitJSON = try Self.jsonString(gitOutput)
        let script = """
        #!/bin/sh
        IFS= read -r initialize
        printf '{"id":1,"result":{}}\\n'
        IFS= read -r initialized
        IFS= read -r pwd_request
        /bin/sleep \(pwdDelaySeconds)
        printf '{"id":2,"result":{"exitCode":0,"stdout":%s,"stderr":""}}\\n' '\(pwdJSON)'
        IFS= read -r git_request
        printf '{"id":3,"result":{"exitCode":%s,"stdout":%s,"stderr":""}}\\n' \(gitExitCode) '\(gitJSON)'
        while IFS= read -r ignored; do :; done
        """
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )
    }

    @MainActor
    func makeClient(requestTimeout: TimeInterval = 5) -> CodexAppServerClient {
        CodexAppServerClient(
            resolver: CodexExecutableResolver(
                environment: ["PATH": directory.path],
                homeDirectory: directory
            ),
            requestTimeout: requestTimeout
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func jsonString(_ value: String) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}
