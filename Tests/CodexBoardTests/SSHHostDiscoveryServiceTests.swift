import Foundation
import XCTest
@testable import CodexBoard

final class SSHHostDiscoveryServiceTests: XCTestCase {
    func testDiscoversConcreteAliasesAndPreservesFirstSeenOrder() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config")
        try write(
            """
            # Global comment
            Host alpha beta alpha
              HostName alpha.example.com
            HOST=gamma delta # trailing comment
            Host *.example.com !blocked question? bracket[0-9]
            Host "alias with spaces"
            """,
            to: configURL
        )

        let hosts = SSHHostDiscoveryService(
            configURL: configURL,
            homeDirectory: directory
        ).discoverHosts()

        XCTAssertEqual(hosts, ["alpha", "beta", "gamma", "delta"])
    }

    func testProcessesRelativeGlobAndSSHDirectoryFallbackIncludesInPlace() throws {
        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let sshDirectory = homeDirectory.appendingPathComponent(".ssh", isDirectory: true)
        let customDirectory = homeDirectory.appendingPathComponent("custom", isDirectory: true)
        let localIncludes = customDirectory.appendingPathComponent("config.d", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localIncludes, withIntermediateDirectories: true)

        try write("Host local-two duplicate\n", to: localIncludes.appendingPathComponent("20.conf"))
        try write("Host local-one duplicate\n", to: localIncludes.appendingPathComponent("10.conf"))
        try write("Host shared\n", to: sshDirectory.appendingPathComponent("shared.conf"))

        let identityFile = customDirectory.appendingPathComponent("identity")
        try write("Host must-not-be-read\n", to: identityFile)

        let configURL = customDirectory.appendingPathComponent("config")
        try write(
            """
            Host root-before
            Include config.d/*.conf
            Include shared.conf
            IdentityFile identity
            Host root-after
            """,
            to: configURL
        )

        let hosts = SSHHostDiscoveryService(
            configURL: configURL,
            homeDirectory: homeDirectory
        ).discoverHosts()

        XCTAssertEqual(
            hosts,
            ["root-before", "local-one", "duplicate", "local-two", "shared", "root-after"]
        )
    }

    func testSupportsHomeRelativeIncludesAndStopsCycles() throws {
        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }
        let sshDirectory = homeDirectory.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)

        let configURL = sshDirectory.appendingPathComponent("config")
        let includedURL = sshDirectory.appendingPathComponent("included.conf")
        try write(
            """
            Host included
            Include ~/.ssh/config
            Host included-tail
            """,
            to: includedURL
        )
        try write(
            """
            Host root
            Include ~/.ssh/included.conf
            Host root-tail
            """,
            to: configURL
        )

        let hosts = SSHHostDiscoveryService(homeDirectory: homeDirectory).discoverHosts()

        XCTAssertEqual(hosts, ["root", "included", "included-tail", "root-tail"])
    }

    func testHonorsMaximumIncludeDepth() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config")
        try write("Host root\nInclude first.conf\n", to: configURL)
        try write("Host first\nInclude second.conf\n", to: directory.appendingPathComponent("first.conf"))
        try write("Host second\n", to: directory.appendingPathComponent("second.conf"))

        let hosts = SSHHostDiscoveryService(
            configURL: configURL,
            homeDirectory: directory,
            maximumIncludeDepth: 1
        ).discoverHosts()

        XCTAssertEqual(hosts, ["root", "first"])
    }

    func testMissingDefaultConfigReturnsEmptyList() throws {
        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        XCTAssertEqual(
            SSHHostDiscoveryService(homeDirectory: homeDirectory).discoverHosts(),
            []
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHHostDiscoveryServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }
}
