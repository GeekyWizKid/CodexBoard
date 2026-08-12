import AppKit
import Foundation
import Security

struct CodexExecutableResolver: Sendable {
    private let environment: [String: String]
    private let homeDirectory: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    func resolve() throws -> URL {
        var candidates = [
            homeDirectory.appendingPathComponent(".local/bin/codex"),
            homeDirectory.appendingPathComponent(".npm-global/bin/codex"),
            homeDirectory.appendingPathComponent(".codex/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            URL(fileURLWithPath: "/usr/bin/codex")
        ]

        candidates.append(contentsOf: environment["PATH", default: ""]
            .split(separator: ":")
            .map(String.init)
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("codex") })

        var visited = Set<String>()
        var deferredLaunchers: [URL] = []
        for candidate in candidates {
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard visited.insert(resolved.path).inserted, isExecutable(resolved) else { continue }
            if let native = packagedNativeExecutable(backing: resolved), isExecutable(native) {
                return native
            }
            if resolved.pathExtension == "js" {
                deferredLaunchers.append(resolved)
                continue
            }
            return resolved
        }

        for native in directNativeCandidates() {
            let resolved = native.standardizedFileURL.resolvingSymlinksInPath()
            guard visited.insert(resolved.path).inserted else { continue }
            if isExecutable(resolved) { return resolved }
        }

        let applicationCandidates = [
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications/ChatGPT.app", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications/Codex.app", isDirectory: true)
        ].compactMap { $0 }

        for application in applicationCandidates {
            let appURL = application.standardizedFileURL.resolvingSymlinksInPath()
            guard Self.isTrustedOpenAIApplication(appURL) else { continue }
            let executable = appURL
                .appendingPathComponent("Contents/Resources/codex")
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard executable.path.hasPrefix(appURL.path + "/"), isExecutable(executable) else { continue }
            return executable
        }

        if let launcher = deferredLaunchers.first, environmentCanRunNode() {
            return launcher
        }
        throw CodexClientError.executableNotFound
    }

    private func packagedNativeExecutable(backing executable: URL) -> URL? {
        guard executable.lastPathComponent == "codex.js",
              executable.deletingLastPathComponent().lastPathComponent == "bin",
              let platform
        else { return nil }
        let packageRoot = executable.deletingLastPathComponent().deletingLastPathComponent()
        return nativeCandidates(packageRoot: packageRoot, platform: platform)
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .first(where: isExecutable)
    }

    private func directNativeCandidates() -> [URL] {
        guard let platform else { return [] }
        var roots = [
            homeDirectory.appendingPathComponent(".npm-global/lib/node_modules/@openai/codex", isDirectory: true),
            homeDirectory.appendingPathComponent(".local/lib/node_modules/@openai/codex", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/@openai/codex", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/lib/node_modules/@openai/codex", isDirectory: true)
        ]
        roots.append(contentsOf: environment["PATH", default: ""]
            .split(separator: ":")
            .map(String.init)
            .filter { $0.hasPrefix("/") }
            .map {
                URL(fileURLWithPath: $0, isDirectory: true)
                    .deletingLastPathComponent()
                    .appendingPathComponent("lib/node_modules/@openai/codex", isDirectory: true)
            })
        var visited = Set<String>()
        return roots
            .map { $0.standardizedFileURL }
            .filter { visited.insert($0.path).inserted }
            .flatMap { nativeCandidates(packageRoot: $0, platform: platform) }
    }

    private func nativeCandidates(
        packageRoot: URL,
        platform: (packageName: String, triple: String)
    ) -> [URL] {
        let relative = "vendor/\(platform.triple)/bin/codex"
        return [
            packageRoot
                .appendingPathComponent("node_modules/@openai/\(platform.packageName)")
                .appendingPathComponent(relative),
            packageRoot
                .deletingLastPathComponent()
                .appendingPathComponent(platform.packageName)
                .appendingPathComponent(relative),
            packageRoot.appendingPathComponent(relative)
        ]
    }

    private var platform: (packageName: String, triple: String)? {
        #if arch(arm64)
        ("codex-darwin-arm64", "aarch64-apple-darwin")
        #elseif arch(x86_64)
        ("codex-darwin-x64", "x86_64-apple-darwin")
        #else
        nil
        #endif
    }

    private func environmentCanRunNode() -> Bool {
        environment["PATH", default: ""]
            .split(separator: ":")
            .map(String.init)
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("node") }
            .contains(where: isExecutable)
    }

    private func isExecutable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: url.path)
    }

    private static func isTrustedOpenAIApplication(_ applicationURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(applicationURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return false }

        let requirementText = """
        anchor apple generic and identifier "com.openai.codex" \
        and certificate leaf[subject.OU] = "2DC432GLL2"
        """
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementText as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
        let requirement
        else { return false }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess
    }
}
