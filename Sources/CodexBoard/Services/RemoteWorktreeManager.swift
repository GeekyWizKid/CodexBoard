import Foundation

/// A single buffered `command/exec` request reserved for managed remote
/// worktree operations. The command is always sent as an argv vector and is
/// always sandboxed to the explicitly listed remote roots.
struct CodexManagedWorktreeCommand: Equatable, Sendable {
    static let maximumArgumentCount = 64
    static let maximumArgumentBytes = 4_096
    static let maximumWritableRootCount = 4
    static let maximumTimeoutMilliseconds: Int64 = 120_000
    static let maximumOutputBytes = 65_536

    let arguments: [String]
    let projectPath: String
    let cwd: String
    let writableRoots: [String]
    let timeoutMilliseconds: Int64
    let outputBytesCap: Int

    init(
        arguments: [String],
        projectPath: String,
        cwd: String,
        writableRoots: [String],
        timeoutMilliseconds: Int64 = 30_000,
        outputBytesCap: Int = 32_768
    ) {
        self.arguments = arguments
        self.projectPath = projectPath
        self.cwd = cwd
        self.writableRoots = writableRoots
        self.timeoutMilliseconds = timeoutMilliseconds
        self.outputBytesCap = outputBytesCap
    }

    func validated() throws -> CodexManagedWorktreeCommand {
        guard !arguments.isEmpty,
              arguments.count <= Self.maximumArgumentCount,
              arguments[0] == "git" || arguments[0] == "mkdir"
        else {
            throw RemoteWorktreeManagerError.invalidCommand(
                "远端 Worktree 仅允许有界的 git 或 mkdir argv 命令。"
            )
        }
        guard arguments.allSatisfy({ argument in
            !argument.contains("\0")
                && !argument.unicodeScalars.contains(where: CharacterSet.newlines.contains)
                && argument.utf8.count <= Self.maximumArgumentBytes
        }) else {
            throw RemoteWorktreeManagerError.invalidCommand("远端命令参数无效或过长。")
        }
        guard (1...Self.maximumTimeoutMilliseconds).contains(timeoutMilliseconds) else {
            throw RemoteWorktreeManagerError.invalidCommand("远端命令超时不在安全范围内。")
        }
        guard (1...Self.maximumOutputBytes).contains(outputBytesCap) else {
            throw RemoteWorktreeManagerError.invalidCommand("远端命令输出上限不在安全范围内。")
        }
        guard !writableRoots.isEmpty,
              writableRoots.count <= Self.maximumWritableRootCount
        else {
            throw RemoteWorktreeManagerError.invalidCommand("远端命令必须声明有限的可写根目录。")
        }

        let normalizedProjectPath = try Self.normalizedRemotePath(projectPath, allowRoot: false)
        let normalizedCWD = try Self.normalizedRemotePath(cwd, allowRoot: false)
        let normalizedRoots = try writableRoots.map {
            try Self.normalizedRemotePath($0, allowRoot: false)
        }
        guard Set(normalizedRoots).count == normalizedRoots.count else {
            throw RemoteWorktreeManagerError.invalidCommand("远端命令包含重复的可写根目录。")
        }
        guard normalizedRoots.contains(where: {
            Self.isSameOrDescendant(normalizedCWD, of: $0)
        }) else {
            throw RemoteWorktreeManagerError.invalidCommand("远端命令工作目录不在声明的可写根目录内。")
        }
        let lexicalGitAdministrativeRoot = (normalizedProjectPath as NSString)
            .appendingPathComponent(".git")
        guard normalizedRoots.allSatisfy({ root in
            if Self.isSameOrDescendant(normalizedProjectPath, of: root) {
                return false
            }
            if Self.isSameOrDescendant(root, of: normalizedProjectPath) {
                return root == lexicalGitAdministrativeRoot
            }
            return true
        }) else {
            throw RemoteWorktreeManagerError.invalidCommand(
                "远端命令不得把源项目目录或普通源码子目录声明为可写根。"
            )
        }
        let managedRoots = normalizedRoots.filter { $0 != lexicalGitAdministrativeRoot }
        if arguments[0] == "git" {
            guard normalizedRoots.count == 2,
                  normalizedRoots.contains(lexicalGitAdministrativeRoot),
                  managedRoots.count == 1,
                  Self.isSameOrDescendant(normalizedCWD, of: managedRoots[0])
            else {
                throw RemoteWorktreeManagerError.invalidCommand(
                    "远端 Git 命令只允许一个托管工作根和精确的源仓库 Git 管理根。"
                )
            }
            try Self.validateGitArguments(arguments)
        } else {
            guard normalizedRoots.count == 1,
                  managedRoots.count == 1,
                  Self.isSameOrDescendant(normalizedCWD, of: managedRoots[0])
            else {
                throw RemoteWorktreeManagerError.invalidCommand(
                    "远端 mkdir 命令只允许一个托管工作根。"
                )
            }
        }

        return CodexManagedWorktreeCommand(
            arguments: arguments,
            projectPath: normalizedProjectPath,
            cwd: normalizedCWD,
            writableRoots: normalizedRoots.sorted(),
            timeoutMilliseconds: timeoutMilliseconds,
            outputBytesCap: outputBytesCap
        )
    }

    static func normalizedRemotePath(_ rawPath: String, allowRoot: Bool) throws -> String {
        guard !rawPath.isEmpty,
              rawPath.utf8.count <= Self.maximumArgumentBytes,
              rawPath.first == "/",
              !rawPath.contains("\0"),
              !rawPath.unicodeScalars.contains(where: CharacterSet.newlines.contains)
        else {
            throw RemoteWorktreeManagerError.invalidRemotePath(rawPath)
        }
        let normalized = (rawPath as NSString).standardizingPath
        guard normalized.first == "/", allowRoot || normalized != "/" else {
            throw RemoteWorktreeManagerError.invalidRemotePath(rawPath)
        }
        return normalized
    }

    static func isSameOrDescendant(_ path: String, of ancestor: String) -> Bool {
        let pathComponents = (path as NSString).pathComponents
        let ancestorComponents = (ancestor as NSString).pathComponents
        guard ancestorComponents.count <= pathComponents.count else { return false }
        return pathComponents.prefix(ancestorComponents.count).elementsEqual(ancestorComponents)
    }

    private static func validateGitArguments(_ arguments: [String]) throws {
        guard !arguments.dropFirst().contains(where: { argument in
            argument == "-c"
                || argument.hasPrefix("--config-env")
                || argument.hasPrefix("--exec-path")
        }) else {
            throw RemoteWorktreeManagerError.invalidCommand(
                "远端 Git 命令不得注入配置、alias 或外部 helper。"
            )
        }
        var index = 1
        while index < arguments.count, arguments[index] == "-C" {
            guard index + 1 < arguments.count else {
                throw RemoteWorktreeManagerError.invalidCommand("远端 Git -C 缺少路径参数。")
            }
            index += 2
        }
        let allowedSubcommands: Set<String> = [
            "add", "branch", "commit", "diff", "ls-files", "log", "merge-base",
            "rev-parse", "show", "show-ref", "stash", "status", "worktree", "write-tree",
        ]
        guard index < arguments.count, allowedSubcommands.contains(arguments[index]) else {
            throw RemoteWorktreeManagerError.invalidCommand(
                "远端 Git 子命令不在托管 Worktree 白名单中。"
            )
        }
    }
}

struct CodexManagedWorktreeCommandResult: Equatable, Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum RemoteWorktreeManagerError: LocalizedError, Equatable {
    case capabilityUnsupported(String)
    case invalidCommand(String)
    case invalidRemotePath(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case let .capabilityUnsupported(reason): reason
        case let .invalidCommand(reason): reason
        case let .invalidRemotePath(path):
            "无效的远端 Worktree 路径：\(path)"
        case let .invalidResponse(reason): reason
        }
    }
}

/// A host-bound worktree manager. Remote paths remain opaque POSIX strings:
/// every probe and future mutation is delegated to the `CodexTaskClient` for
/// that host, never to this Mac's filesystem.
@MainActor
final class RemoteWorktreeManager: WorktreeManaging {
    private let client: any CodexTaskClient

    init(client: any CodexTaskClient) {
        self.client = client
    }

    func capability(
        projectPath: String,
        requiredCapability: WorktreeCapability
    ) async -> WorktreeCapabilityAvailability {
        guard requiredCapability == .managedV1 else {
            return .unsupported(reason: "未知能力令牌：\(requiredCapability.token)")
        }

        let normalizedProjectPath: String
        do {
            normalizedProjectPath = try CodexManagedWorktreeCommand.normalizedRemotePath(
                projectPath,
                allowRoot: false
            )
        } catch {
            return .unsupported(reason: "远端项目路径无效，无法探测 Worktree 能力。")
        }

        let advertised: Set<WorktreeCapability>
        do {
            advertised = try await client.advertisedRemoteWorktreeCapabilities(
                projectPath: normalizedProjectPath
            )
        } catch {
            return .unavailable(reason: "对应主机的 Worktree 能力探测失败：\(error.localizedDescription)")
        }

        guard advertised.contains(requiredCapability) else {
            return .unsupported(
                reason: "对应主机没有明确确认 \(requiredCapability.token)。"
            )
        }

        // The token represents the complete prepare/status/cleanup contract,
        // not merely the existence of command/exec. CodexBoard does not yet
        // have the atomic remote helper operation protocol needed to implement
        // all four operations, so an advertised token is intentionally not
        // surfaced as supported yet.
        return .unsupported(
            reason: "CodexBoard 尚未实现 \(requiredCapability.token) 的远端原子 Worktree 后端。"
        )
    }

    func prepare(
        taskID: UUID,
        projectPath: String,
        configuration: TaskWorkspaceConfiguration
    ) async throws -> TaskWorkspaceConfiguration {
        try await prepare(
            taskID: taskID,
            projectPath: projectPath,
            configuration: configuration,
            requiredCapability: .managedV1
        )
    }

    func status(configuration: TaskWorkspaceConfiguration) async throws -> WorktreeStatus {
        guard configuration.kind == .worktree, configuration.path != nil else {
            return WorktreeStatus(isClean: true, changes: [])
        }
        guard let preparation = configuration.preparation else {
            throw WorktreeManagerError.invalidPreparationEvidence("缺少任务所有权与基线证据。")
        }
        return try await status(
            taskID: preparation.ownerTaskID,
            projectPath: preparation.repositoryPath,
            configuration: configuration,
            requiredCapability: preparation.capability
        )
    }

    func cleanup(
        projectPath: String,
        configuration: TaskWorkspaceConfiguration
    ) async throws -> TaskWorkspaceConfiguration {
        guard configuration.kind == .worktree, configuration.path != nil else {
            return configuration
        }
        guard let preparation = configuration.preparation else {
            throw WorktreeManagerError.invalidPreparationEvidence("缺少任务所有权与基线证据。")
        }
        return try await cleanup(
            taskID: preparation.ownerTaskID,
            projectPath: projectPath,
            configuration: configuration,
            requiredCapability: preparation.capability
        )
    }

    func prepare(
        taskID _: UUID,
        projectPath: String,
        configuration: TaskWorkspaceConfiguration,
        requiredCapability: WorktreeCapability
    ) async throws -> TaskWorkspaceConfiguration {
        guard configuration.kind == .worktree else { return .project }
        throw await capabilityError(
            projectPath: projectPath,
            requiredCapability: requiredCapability
        )
    }

    func status(
        taskID _: UUID,
        projectPath: String,
        configuration: TaskWorkspaceConfiguration,
        requiredCapability: WorktreeCapability
    ) async throws -> WorktreeStatus {
        guard configuration.kind == .worktree, configuration.path != nil else {
            return WorktreeStatus(isClean: true, changes: [])
        }
        throw await capabilityError(
            projectPath: projectPath,
            requiredCapability: requiredCapability
        )
    }

    func cleanup(
        taskID _: UUID,
        projectPath: String,
        configuration: TaskWorkspaceConfiguration,
        requiredCapability: WorktreeCapability
    ) async throws -> TaskWorkspaceConfiguration {
        guard configuration.kind == .worktree, configuration.path != nil else {
            return configuration
        }
        throw await capabilityError(
            projectPath: projectPath,
            requiredCapability: requiredCapability
        )
    }

    private func capabilityError(
        projectPath: String,
        requiredCapability: WorktreeCapability
    ) async -> WorktreeManagerError {
        switch await capability(
            projectPath: projectPath,
            requiredCapability: requiredCapability
        ) {
        case let .supported(actual) where actual == requiredCapability:
            // Keep this defensive branch even after the implementation starts
            // returning supported: an operation must never silently no-op.
            return .capabilityUnavailable("远端 Worktree 原子操作尚未接入。")
        case let .supported(actual):
            return .capabilityMismatch(required: requiredCapability, actual: actual)
        case let .unsupported(reason):
            return .capabilityUnsupported(reason)
        case let .unavailable(reason):
            return .capabilityUnavailable(reason)
        }
    }
}
