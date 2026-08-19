import Foundation
import Darwin
import CryptoKit

struct WorktreeStatus: Hashable, Sendable {
    let isClean: Bool
    let changes: [String]
}

enum WorktreeCapabilityAvailability: Hashable, Sendable {
    case supported(WorktreeCapability)
    case unsupported(reason: String)
    case unavailable(reason: String)
}

protocol WorktreeManaging: Sendable {
    func capability(
        projectPath: String,
        requiredCapability: WorktreeCapability
    ) async -> WorktreeCapabilityAvailability

    func prepare(
        taskID: UUID,
        projectPath: String,
        configuration: TaskWorkspaceConfiguration
    ) async throws -> TaskWorkspaceConfiguration

    func status(configuration: TaskWorkspaceConfiguration) async throws -> WorktreeStatus

    func cleanup(
        projectPath: String,
        configuration: TaskWorkspaceConfiguration
    ) async throws -> TaskWorkspaceConfiguration

    func prepare(
        taskID: UUID,
        projectPath: String,
        configuration: TaskWorkspaceConfiguration,
        requiredCapability: WorktreeCapability
    ) async throws -> TaskWorkspaceConfiguration

    func status(
        taskID: UUID,
        projectPath: String,
        configuration: TaskWorkspaceConfiguration,
        requiredCapability: WorktreeCapability
    ) async throws -> WorktreeStatus

    func cleanup(
        taskID: UUID,
        projectPath: String,
        configuration: TaskWorkspaceConfiguration,
        requiredCapability: WorktreeCapability
    ) async throws -> TaskWorkspaceConfiguration
}

extension WorktreeManaging {
    func capability(
        projectPath _: String,
        requiredCapability _: WorktreeCapability
    ) async -> WorktreeCapabilityAvailability {
        .unavailable(reason: "Worktree 管理器未实现能力探测。")
    }

    func prepare(
        taskID: UUID,
        projectPath: String,
        configuration: TaskWorkspaceConfiguration,
        requiredCapability: WorktreeCapability
    ) async throws -> TaskWorkspaceConfiguration {
        try await requireSupportedCapability(
            projectPath: projectPath,
            requiredCapability: requiredCapability
        )
        return try await prepare(
            taskID: taskID,
            projectPath: projectPath,
            configuration: configuration
        )
    }

    func status(
        taskID _: UUID,
        projectPath: String,
        configuration: TaskWorkspaceConfiguration,
        requiredCapability: WorktreeCapability
    ) async throws -> WorktreeStatus {
        try await requireSupportedCapability(
            projectPath: projectPath,
            requiredCapability: requiredCapability
        )
        return try await status(configuration: configuration)
    }

    func cleanup(
        taskID _: UUID,
        projectPath: String,
        configuration: TaskWorkspaceConfiguration,
        requiredCapability: WorktreeCapability
    ) async throws -> TaskWorkspaceConfiguration {
        try await requireSupportedCapability(
            projectPath: projectPath,
            requiredCapability: requiredCapability
        )
        return try await cleanup(projectPath: projectPath, configuration: configuration)
    }

    private func requireSupportedCapability(
        projectPath: String,
        requiredCapability: WorktreeCapability
    ) async throws {
        switch await capability(
            projectPath: projectPath,
            requiredCapability: requiredCapability
        ) {
        case let .supported(actual) where actual == requiredCapability:
            return
        case let .supported(actual):
            throw WorktreeManagerError.capabilityMismatch(
                required: requiredCapability,
                actual: actual
            )
        case let .unsupported(reason):
            throw WorktreeManagerError.capabilityUnsupported(reason)
        case let .unavailable(reason):
            throw WorktreeManagerError.capabilityUnavailable(reason)
        }
    }
}

enum WorktreeManagerError: LocalizedError, Equatable {
    case projectIsNotGitRepository(String)
    case repositoryHasNoInitialCommit(String)
    case capabilityMismatch(required: WorktreeCapability, actual: WorktreeCapability)
    case capabilityUnsupported(String)
    case capabilityUnavailable(String)
    case pathOccupied(String)
    case invalidManagedPath(String)
    case invalidPreparationEvidence(String)
    case branchMismatch(expected: String, actual: String)
    case branchAlreadyExists(String)
    case dirtyWorktree([String])
    case unsafeUntrackedPath(String)
    case unsupportedUntrackedFile(path: String, type: String)
    case repositoryContainsSubmodules(String)
    case unsupportedIndexFlags([String])
    case unsupportedFilesystemNodes([String])
    case filesystemInspectionFailed(path: String, message: String)
    case untrackedFileLimitExceeded(maximum: Int)
    case untrackedByteLimitExceeded(maximum: Int64)
    case untrackedFileChanged(String)
    case sourceWorkspaceChanged(String)
    case capturedStatePreserved(path: String, branch: String, reason: String)
    case gitTimedOut(arguments: [String], seconds: Int)
    case gitFailed(arguments: [String], message: String)

    var errorDescription: String? {
        switch self {
        case let .projectIsNotGitRepository(path):
            "无法创建 Worktree：\(path) 不是可用的 Git 仓库。"
        case let .repositoryHasNoInitialCommit(path):
            "无法创建 Worktree：\(path) 尚无可验证的初始提交。"
        case let .capabilityMismatch(required, actual):
            "Worktree 能力不匹配：需要 \(required.token)，实际为 \(actual.token)。"
        case let .capabilityUnsupported(reason):
            "当前项目不支持隔离 Worktree：\(reason)"
        case let .capabilityUnavailable(reason):
            "Worktree 能力当前不可用：\(reason)"
        case let .pathOccupied(path):
            "Worktree 目标路径已被占用：\(path)"
        case let .invalidManagedPath(path):
            "拒绝使用或清理不受 CodexBoard 管理的 Worktree：\(path)"
        case let .invalidPreparationEvidence(reason):
            "Worktree 准备证据无效：\(reason)"
        case let .branchMismatch(expected, actual):
            "Worktree 分支不匹配：预期 \(expected)，实际 \(actual)。"
        case let .branchAlreadyExists(branch):
            "拒绝复用缺少所有权证据的已有分支：\(branch)"
        case let .dirtyWorktree(changes):
            "Worktree 仍有未提交改动，已保留现场：\(changes.prefix(5).joined(separator: "、"))"
        case let .unsafeUntrackedPath(path):
            "未跟踪文件路径不安全，已停止捕获：\(path)"
        case let .unsupportedUntrackedFile(path, type):
            "未跟踪项类型不受支持，已停止捕获：\(path)（\(type)）"
        case let .repositoryContainsSubmodules(path):
            "仓库包含 submodule，当前版本无法完整复制其工作区状态，已拒绝创建 Worktree：\(path)"
        case let .unsupportedIndexFlags(entries):
            "Git index 使用了 assume-unchanged 或 skip-worktree，当前版本无法安全捕获或清理：\(entries.prefix(5).joined(separator: "、"))"
        case let .unsupportedFilesystemNodes(entries):
            "源工作区包含 Git 无法表示的文件系统节点，当前版本无法完整复制：\(entries.prefix(5).joined(separator: "、"))"
        case let .filesystemInspectionFailed(path, message):
            "无法安全检查 Worktree 文件系统节点，已保留现场：\(path)（\(message)）"
        case let .untrackedFileLimitExceeded(maximum):
            "未跟踪文件超过安全数量上限（\(maximum)），未创建 Worktree。"
        case let .untrackedByteLimitExceeded(maximum):
            "未跟踪文件超过安全总字节上限（\(maximum)），未创建 Worktree。"
        case let .untrackedFileChanged(path):
            "捕获期间未跟踪文件发生变化，已停止：\(path)"
        case let .sourceWorkspaceChanged(path):
            "捕获期间源工作区状态发生变化，已停止且未改写源目录：\(path)"
        case let .capturedStatePreserved(path, branch, reason):
            "捕获后验证失败；为避免删除用户状态，已保留 Worktree：\(path)（\(branch)）。原因：\(reason)"
        case let .gitTimedOut(arguments, seconds):
            "Git 命令超时（\(seconds) 秒，git \(arguments.joined(separator: " "))）。"
        case let .gitFailed(arguments, message):
            "Git 命令失败（git \(arguments.joined(separator: " "))）：\(message)"
        }
    }
}

actor WorktreeManager: WorktreeManaging {
    static let defaultMaximumUntrackedFiles = 2_000
    static let defaultMaximumUntrackedBytes: Int64 = 200 * 1_024 * 1_024

    private let managedRoot: URL
    private let gitExecutableURL: URL
    private let fileManager: FileManager
    private let maximumUntrackedFiles: Int
    private let maximumUntrackedBytes: Int64
    private let gitTimeout: TimeInterval

    init(
        managedRoot: URL? = nil,
        gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        fileManager: FileManager = .default,
        maximumUntrackedFiles: Int = WorktreeManager.defaultMaximumUntrackedFiles,
        maximumUntrackedBytes: Int64 = WorktreeManager.defaultMaximumUntrackedBytes,
        gitTimeout: TimeInterval = 120
    ) {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        self.managedRoot = managedRoot
            ?? applicationSupport.appendingPathComponent("CodexBoard/worktrees", isDirectory: true)
        self.gitExecutableURL = gitExecutableURL
        self.fileManager = fileManager
        self.maximumUntrackedFiles = maximumUntrackedFiles
        self.maximumUntrackedBytes = maximumUntrackedBytes
        self.gitTimeout = gitTimeout
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
        guard configuration.kind == .worktree, let path = configuration.path else {
            return WorktreeStatus(isClean: true, changes: [])
        }
        guard let preparation = configuration.preparation else {
            let worktreeURL = resolvedURL(path)
            guard isDescendant(worktreeURL, of: resolvedManagedRoot) else {
                throw WorktreeManagerError.invalidManagedPath(worktreeURL.path)
            }
            let changes = try worktreeChanges(at: worktreeURL.path)
            return WorktreeStatus(isClean: changes.isEmpty, changes: changes)
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
        guard configuration.kind == .worktree else {
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

    func capability(
        projectPath: String,
        requiredCapability: WorktreeCapability
    ) async -> WorktreeCapabilityAvailability {
        guard requiredCapability == .managedV1 else {
            return .unsupported(reason: "未知能力令牌：\(requiredCapability.token)")
        }
        let rootResult = runGitResult(["-C", projectPath, "rev-parse", "--show-toplevel"])
        guard rootResult.status == 0 else {
            if rootResult.timedOut {
                return .unavailable(reason: "Git 仓库探测超时。")
            }
            let message = gitMessage(rootResult)
            if isRepositoryUnsupported(message) {
                return .unsupported(reason: "项目不是可用的 Git 工作区。")
            }
            return .unavailable(reason: message.isEmpty ? "Git 仓库探测失败。" : message)
        }

        let repository = rootResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repository.isEmpty else {
            return .unsupported(reason: "Git 未返回仓库根目录。")
        }
        let headResult = runGitResult(["-C", repository, "rev-parse", "--verify", "HEAD^{commit}"])
        guard headResult.status == 0 else {
            if headResult.timedOut {
                return .unavailable(reason: "Git HEAD 探测超时。")
            }
            let message = gitMessage(headResult)
            if isMissingInitialCommit(message) {
                return .unsupported(reason: "仓库尚无可验证的初始提交。")
            }
            return .unavailable(reason: message.isEmpty ? "Git HEAD 探测失败。" : message)
        }
        let indexResult = runGitResult(["-C", repository, "ls-files", "--stage", "-z"])
        guard indexResult.status == 0 else {
            if indexResult.timedOut {
                return .unavailable(reason: "Git submodule 探测超时。")
            }
            let message = gitMessage(indexResult)
            return .unavailable(reason: message.isEmpty ? "Git submodule 探测失败。" : message)
        }
        guard let sourceGitlinks = gitlinkPaths(indexResult.outputData) else {
            return .unavailable(reason: "Git submodule 路径无法安全解析。")
        }
        if !sourceGitlinks.isEmpty {
            return .unsupported(reason: "仓库包含 submodule，当前版本无法完整复制其工作区状态。")
        }
        let flagsResult = runGitResult(["-C", repository, "ls-files", "-v", "-z"])
        guard flagsResult.status == 0 else {
            if flagsResult.timedOut {
                return .unavailable(reason: "Git index 标志探测超时。")
            }
            let message = gitMessage(flagsResult)
            return .unavailable(reason: message.isEmpty ? "Git index 标志探测失败。" : message)
        }
        guard let unsafeEntries = unsafeIndexEntries(from: flagsResult.outputData) else {
            return .unavailable(reason: "Git index 标志输出无法安全解析。")
        }
        if !unsafeEntries.isEmpty {
            return .unsupported(
                reason: "Git index 使用了 assume-unchanged 或 skip-worktree，无法保证完整复制。"
            )
        }
        do {
            let filesystemChanges = try unreportedFilesystemChanges(
                at: repository,
                gitAdministrativeNodeMayBeDirectory: true,
                excludeIgnored: true
            )
            if !filesystemChanges.isEmpty {
                return .unsupported(
                    reason: "源工作区包含 Git 无法表示的特殊节点或空目录，无法保证完整复制。"
                )
            }
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
        return .supported(.managedV1)
    }

    func prepare(
        taskID: UUID,
        projectPath: String,
        configuration: TaskWorkspaceConfiguration,
        requiredCapability: WorktreeCapability
    ) async throws -> TaskWorkspaceConfiguration {
        guard configuration.kind == .worktree else { return .project }
        try await requireLocalCapability(
            projectPath: projectPath,
            requiredCapability: requiredCapability
        )
        let repository = try repositoryRoot(for: projectPath)
        let destination = destinationURL(repository: repository, taskID: taskID)
        _ = try validatedDestinationPath(destination, repository: repository)
        let hasPersistedBranch = configuration.branch != nil
        var branch = configuration.branch ?? taskBranch(taskID: taskID)
        try validateOwnedBranch(branch, taskID: taskID)
        let baseBranch: String
        if let configuredBaseBranch = configuration.baseBranch {
            baseBranch = configuredBaseBranch
        } else {
            baseBranch = try currentBranch(at: repository)
        }

        if let persistedPath = configuration.path {
            let persistedURL = resolvedURL(persistedPath)
            guard persistedURL.path == resolvedURL(destination.path).path else {
                throw WorktreeManagerError.invalidManagedPath(persistedURL.path)
            }
            guard fileManager.fileExists(atPath: persistedURL.path) else {
                throw WorktreeManagerError.pathOccupied("已记录的 Worktree 不存在：\(persistedURL.path)")
            }
            let recovered = try validatedOrRecoveredPreparation(
                taskID: taskID,
                repository: repository,
                worktreePath: persistedURL.path,
                configuration: configuration,
                requiredCapability: requiredCapability
            )
            return TaskWorkspaceConfiguration(
                kind: .worktree,
                path: persistedURL.path,
                branch: recovered.branch,
                baseBranch: baseBranch,
                preparation: recovered.preparation
            )
        }

        if fileManager.fileExists(atPath: destination.path) {
            let recoveredURL = resolvedURL(destination.path)
            guard isDescendant(recoveredURL, of: resolvedManagedRoot),
                  try registeredWorktreePaths(repository: repository).contains(recoveredURL.path)
            else {
                throw WorktreeManagerError.pathOccupied(destination.path)
            }
            let recovered = try validatedOrRecoveredPreparation(
                taskID: taskID,
                repository: repository,
                worktreePath: recoveredURL.path,
                configuration: configuration,
                requiredCapability: requiredCapability
            )
            return TaskWorkspaceConfiguration(
                kind: .worktree,
                path: recoveredURL.path,
                branch: recovered.branch,
                baseBranch: baseBranch,
                preparation: recovered.preparation
            )
        }

        if configuration.preparation == nil,
           !hasPersistedBranch,
           try branchExists(branch, repository: repository) {
            branch = try nextAvailableTaskBranch(taskID: taskID, repository: repository)
        }

        if try branchExists(branch, repository: repository) {
            guard let preparation = configuration.preparation else {
                return try adoptPersistedOwnedBranch(
                    taskID: taskID,
                    repository: repository,
                    destination: destination,
                    branch: branch,
                    baseBranch: baseBranch,
                    requiredCapability: requiredCapability
                )
            }
            try validatePreparation(
                preparation,
                taskID: taskID,
                repository: repository,
                requiredCapability: requiredCapability
            )
            try verifyBaselineIsAncestor(
                preparation.baselineCommit,
                of: branch,
                repository: repository
            )
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try validatedDestinationPath(destination, repository: repository)
            var worktreeWasAdded = false
            do {
                _ = try runGit(["-C", repository, "worktree", "add", destination.path, branch])
                worktreeWasAdded = true
                let addedPath = try validatedAddedWorktreePath(
                    destination,
                    repository: repository,
                    branch: branch
                )
                return TaskWorkspaceConfiguration(
                    kind: .worktree,
                    path: addedPath,
                    branch: branch,
                    baseBranch: baseBranch,
                    preparation: preparation
                )
            } catch {
                if worktreeWasAdded {
                    if let preserved = rollbackAddedWorktree(
                        repository: repository,
                        destination: destination,
                        branch: branch,
                        deleteBranch: false,
                        expectedBranchTip: nil
                    ) {
                        throw WorktreeManagerError.capturedStatePreserved(
                            path: preserved.path,
                            branch: branch,
                            reason: preserved.reason
                        )
                    }
                } else if let preserved = preservedWorktreeAfterFailedAdd(
                    repository: repository,
                    destination: destination,
                    branch: branch
                ) {
                    throw WorktreeManagerError.capturedStatePreserved(
                        path: preserved.path,
                        branch: branch,
                        reason: preserved.reason
                    )
                }
                throw error
            }
        }

        if hasPersistedBranch, configuration.preparation == nil {
            throw WorktreeManagerError.invalidPreparationEvidence(
                "已记录的旧任务分支不存在，拒绝从当前项目静默重建：\(branch)"
            )
        }

        guard configuration.preparation == nil else {
            throw WorktreeManagerError.invalidPreparationEvidence(
                "准备证据指向的任务分支已不存在，拒绝从当前项目静默重建。"
            )
        }

        let capture = try captureSourceBaseline(repository: repository)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try validatedDestinationPath(destination, repository: repository)

        var worktreeWasAdded = false
        var mustPreserveWorktree = false
        var addedWorktreePath: String?
        do {
            _ = try runGit([
                "-C", repository, "worktree", "add", "-b", branch,
                destination.path, capture.sourceCommit,
            ])
            worktreeWasAdded = true
            let worktreePath = try validatedAddedWorktreePath(
                destination,
                repository: repository,
                branch: branch
            )
            addedWorktreePath = worktreePath
            mustPreserveWorktree = true
            if let stashCommit = capture.stashCommit {
                _ = try runGit(["-C", worktreePath, "stash", "apply", "--index", stashCommit])
            }
            try copyUntrackedFiles(
                capture.untrackedFiles,
                from: repository,
                to: URL(fileURLWithPath: worktreePath, isDirectory: true)
            )
            try verifySourceUnchanged(capture, repository: repository)
            let baselineCommit = try createBaselineCommit(
                taskID: taskID,
                sourceCommit: capture.sourceCommit,
                dirtyBaseCaptured: capture.isDirty,
                untrackedFiles: capture.untrackedFiles,
                expectedBaselineTree: capture.expectedBaselineTree,
                worktreePath: worktreePath
            )
            try verifySourceUnchanged(capture, repository: repository)
            let preparedAt = try commitDate(commit: baselineCommit, repository: worktreePath)
            let preparation = TaskWorktreePreparation(
                capability: requiredCapability,
                ownerTaskID: taskID,
                repositoryPath: repository,
                sourceCommit: capture.sourceCommit,
                baselineCommit: baselineCommit,
                dirtyBaseCaptured: capture.isDirty,
                untrackedFilesCaptured: capture.untrackedFiles.count,
                preparedAt: preparedAt
            )
            return TaskWorkspaceConfiguration(
                kind: .worktree,
                path: worktreePath,
                branch: branch,
                baseBranch: baseBranch,
                preparation: preparation
            )
        } catch {
            if worktreeWasAdded, !mustPreserveWorktree {
                if let preserved = rollbackAddedWorktree(
                    repository: repository,
                    destination: destination,
                    branch: branch,
                    deleteBranch: true,
                    expectedBranchTip: capture.sourceCommit
                ) {
                    throw WorktreeManagerError.capturedStatePreserved(
                        path: preserved.path,
                        branch: branch,
                        reason: preserved.reason
                    )
                }
            }
            if worktreeWasAdded, mustPreserveWorktree {
                throw WorktreeManagerError.capturedStatePreserved(
                    path: addedWorktreePath ?? resolvedURL(destination.path).path,
                    branch: branch,
                    reason: error.localizedDescription
                )
            }
            if !worktreeWasAdded {
                if let preserved = preservedWorktreeAfterFailedAdd(
                    repository: repository,
                    destination: destination,
                    branch: branch
                ) {
                    throw WorktreeManagerError.capturedStatePreserved(
                        path: preserved.path,
                        branch: branch,
                        reason: preserved.reason
                    )
                }
                removeUnregisteredBranchIfUnchanged(
                    repository: repository,
                    branch: branch,
                    expectedTip: capture.sourceCommit
                )
            }
            throw error
        }
    }

    private func adoptPersistedOwnedBranch(
        taskID: UUID,
        repository: String,
        destination: URL,
        branch: String,
        baseBranch: String,
        requiredCapability: WorktreeCapability
    ) throws -> TaskWorkspaceConfiguration {
        try validateOwnedBranch(branch, taskID: taskID)
        let branchReference = "refs/heads/\(branch)"
        guard try !registeredWorktrees(repository: repository).contains(where: {
            $0.branchReference == branchReference
        }) else {
            throw WorktreeManagerError.invalidManagedPath(
                "任务分支已注册在其他 Worktree，拒绝重复挂载：\(branch)"
            )
        }
        let sourceCommit = try runGit([
            "-C", repository, "rev-parse", "--verify", "\(branch)^{commit}",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedBaselineTree = try runGit([
            "-C", repository, "rev-parse", "--verify", "\(sourceCommit)^{tree}",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidObjectID(sourceCommit), isValidObjectID(expectedBaselineTree) else {
            throw WorktreeManagerError.invalidPreparationEvidence(
                "旧任务分支的提交证据格式无效。"
            )
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try validatedDestinationPath(destination, repository: repository)

        var worktreeWasAdded = false
        var mustPreserveWorktree = false
        var addedPath: String?
        do {
            _ = try runGit(["-C", repository, "worktree", "add", destination.path, branch])
            worktreeWasAdded = true
            let worktreePath = try validatedAddedWorktreePath(
                destination,
                repository: repository,
                branch: branch
            )
            addedPath = worktreePath
            mustPreserveWorktree = true
            let preexistingChanges = try worktreeChanges(at: worktreePath)
            guard preexistingChanges.isEmpty else {
                throw WorktreeManagerError.dirtyWorktree(preexistingChanges)
            }
            let baselineCommit = try createBaselineCommit(
                taskID: taskID,
                sourceCommit: sourceCommit,
                dirtyBaseCaptured: false,
                untrackedFiles: [],
                expectedBaselineTree: expectedBaselineTree,
                worktreePath: worktreePath
            )
            let preparation = TaskWorktreePreparation(
                capability: requiredCapability,
                ownerTaskID: taskID,
                repositoryPath: repository,
                sourceCommit: sourceCommit,
                baselineCommit: baselineCommit,
                dirtyBaseCaptured: false,
                untrackedFilesCaptured: 0,
                preparedAt: try commitDate(commit: baselineCommit, repository: worktreePath)
            )
            return TaskWorkspaceConfiguration(
                kind: .worktree,
                path: worktreePath,
                branch: branch,
                baseBranch: baseBranch,
                preparation: preparation
            )
        } catch {
            if worktreeWasAdded, !mustPreserveWorktree {
                if let preserved = rollbackAddedWorktree(
                    repository: repository,
                    destination: destination,
                    branch: branch,
                    deleteBranch: false,
                    expectedBranchTip: nil
                ) {
                    throw WorktreeManagerError.capturedStatePreserved(
                        path: preserved.path,
                        branch: branch,
                        reason: preserved.reason
                    )
                }
            }
            if worktreeWasAdded, mustPreserveWorktree {
                throw WorktreeManagerError.capturedStatePreserved(
                    path: addedPath ?? resolvedURL(destination.path).path,
                    branch: branch,
                    reason: error.localizedDescription
                )
            }
            if let preserved = preservedWorktreeAfterFailedAdd(
                repository: repository,
                destination: destination,
                branch: branch
            ) {
                throw WorktreeManagerError.capturedStatePreserved(
                    path: preserved.path,
                    branch: branch,
                    reason: preserved.reason
                )
            }
            throw error
        }
    }

    func status(
        taskID: UUID,
        projectPath: String,
        configuration: TaskWorkspaceConfiguration,
        requiredCapability: WorktreeCapability
    ) async throws -> WorktreeStatus {
        guard configuration.kind == .worktree, configuration.path != nil else {
            return WorktreeStatus(isClean: true, changes: [])
        }
        try requireManagedCapabilityToken(requiredCapability)
        if configuration.preparation == nil {
            let validated = try validatedUnprovenOwnedWorktree(
                taskID: taskID,
                projectPath: projectPath,
                configuration: configuration
            )
            let changes = try worktreeChanges(at: validated.path)
            return WorktreeStatus(isClean: changes.isEmpty, changes: changes)
        }
        let validated = try validatedManagedWorktree(
            taskID: taskID,
            projectPath: projectPath,
            configuration: configuration,
            requiredCapability: requiredCapability
        )
        let changes = try worktreeChanges(at: validated.path)
        return WorktreeStatus(isClean: changes.isEmpty, changes: changes)
    }

    func cleanup(
        taskID: UUID,
        projectPath: String,
        configuration: TaskWorkspaceConfiguration,
        requiredCapability: WorktreeCapability
    ) async throws -> TaskWorkspaceConfiguration {
        guard configuration.kind == .worktree, configuration.path != nil else {
            return configuration
        }
        try requireManagedCapabilityToken(requiredCapability)
        if configuration.preparation == nil {
            return try cleanupUnprovenOwnedWorktree(
                taskID: taskID,
                projectPath: projectPath,
                configuration: configuration
            )
        }
        if let alreadyCleaned = try safelyCleanedConfigurationIfWorktreeIsAlreadyAbsent(
            taskID: taskID,
            projectPath: projectPath,
            configuration: configuration,
            requiredCapability: requiredCapability
        ) {
            return alreadyCleaned
        }
        let validated = try validatedManagedWorktree(
            taskID: taskID,
            projectPath: projectPath,
            configuration: configuration,
            requiredCapability: requiredCapability
        )
        let changes = try worktreeChanges(at: validated.path)
        guard changes.isEmpty else {
            throw WorktreeManagerError.dirtyWorktree(changes)
        }
        _ = try runGit(["-C", validated.repository, "worktree", "remove", validated.path])

        return TaskWorkspaceConfiguration(
            kind: .worktree,
            path: nil,
            branch: configuration.branch,
            baseBranch: configuration.baseBranch,
            preparation: configuration.preparation
        )
    }

    private func worktreeChanges(at path: String) throws -> [String] {
        let output = try runGit([
            "-C", path,
            "status", "--porcelain=v1", "--ignored=matching", "--untracked-files=all",
        ])
        var changes = output.split(whereSeparator: \.isNewline).map(String.init)
        let index = try runGitData(["-C", path, "ls-files", "--stage", "-z"])
        guard let gitlinks = gitlinkPaths(index) else {
            throw WorktreeManagerError.invalidPreparationEvidence(
                "Git gitlink 输出无法安全解析。"
            )
        }
        changes.append(contentsOf: gitlinks.map { "GITLINK \($0.debugDescription)" })
        let unsafeEntries = try unsafeIndexEntries(at: path)
        changes.append(contentsOf: unsafeEntries.map(\.statusDescription))
        if changes.isEmpty {
            changes.append(contentsOf: try unreportedFilesystemChanges(
                at: path,
                gitAdministrativeNodeMayBeDirectory: false,
                excludeIgnored: false
            ))
        }
        return changes
    }

    private func unreportedFilesystemChanges(
        at path: String,
        gitAdministrativeNodeMayBeDirectory: Bool,
        excludeIgnored: Bool
    ) throws -> [String] {
        let root = resolvedURL(path)
        var directories = [root]
        var changes: [String] = []

        while let directory = directories.popLast() {
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: []
                )
            } catch {
                throw WorktreeManagerError.filesystemInspectionFailed(
                    path: directory.path,
                    message: error.localizedDescription
                )
            }
            if directory != root, children.isEmpty {
                let relative = relativePath(directory, from: root)
                let shouldReport: Bool
                if excludeIgnored {
                    shouldReport = try !isIgnored(relative, at: root.path)
                } else {
                    shouldReport = true
                }
                if shouldReport {
                    changes.append("EMPTY-DIR \(relative.debugDescription)")
                }
            }

            for child in children {
                var metadata = stat()
                guard lstat(child.path, &metadata) == 0 else {
                    throw WorktreeManagerError.filesystemInspectionFailed(
                        path: child.path,
                        message: String(cString: strerror(errno))
                    )
                }
                let type = metadata.st_mode & S_IFMT
                let relativePath = relativePath(child, from: root)
                if relativePath == ".git" {
                    if type == S_IFREG
                        || (gitAdministrativeNodeMayBeDirectory && type == S_IFDIR) {
                        continue
                    }
                    changes.append(
                        "SPECIAL \(relativePath.debugDescription) [unexpected-git-admin-node]"
                    )
                    continue
                }
                switch type {
                case S_IFDIR:
                    directories.append(child)
                case S_IFREG, S_IFLNK:
                    continue
                default:
                    let shouldReport: Bool
                    if excludeIgnored {
                        shouldReport = try !isIgnored(relativePath, at: root.path)
                    } else {
                        shouldReport = true
                    }
                    if shouldReport {
                        changes.append(
                            "SPECIAL \(relativePath.debugDescription) [\(filesystemNodeType(type))]"
                        )
                    }
                }
            }
        }
        return changes.sorted()
    }

    private func isIgnored(_ relativePath: String, at repository: String) throws -> Bool {
        let arguments = ["-C", repository, "check-ignore", "--quiet", "--", relativePath]
        let result = runGitResult(arguments)
        if result.status == 0 { return true }
        if result.status == 1 { return false }
        throw gitError(arguments: arguments, result: result)
    }

    private func relativePath(_ url: URL, from root: URL) -> String {
        let rootComponents = root.pathComponents
        let components = url.pathComponents
        guard components.count > rootComponents.count,
              components.prefix(rootComponents.count).elementsEqual(rootComponents)
        else {
            return url.lastPathComponent
        }
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private func filesystemNodeType(_ type: mode_t) -> String {
        switch type {
        case S_IFIFO: "fifo"
        case S_IFSOCK: "socket"
        case S_IFCHR: "character-device"
        case S_IFBLK: "block-device"
        default: "unknown"
        }
    }

    private func safelyCleanedConfigurationIfWorktreeIsAlreadyAbsent(
        taskID: UUID,
        projectPath: String,
        configuration: TaskWorkspaceConfiguration,
        requiredCapability: WorktreeCapability
    ) throws -> TaskWorkspaceConfiguration? {
        guard let path = configuration.path else { return nil }
        let repository = try repositoryRoot(for: projectPath)
        let worktreeURL = resolvedURL(path)
        let expectedURL = resolvedURL(destinationURL(repository: repository, taskID: taskID).path)
        guard worktreeURL.path == expectedURL.path,
              isDescendant(worktreeURL, of: resolvedManagedRoot)
        else {
            throw WorktreeManagerError.invalidManagedPath(worktreeURL.path)
        }
        let registered = try registeredWorktrees(repository: repository)
        guard !fileManager.fileExists(atPath: worktreeURL.path),
              !registered.contains(where: { $0.path == worktreeURL.path })
        else { return nil }
        guard let preparation = configuration.preparation,
              let branch = configuration.branch
        else {
            throw WorktreeManagerError.invalidPreparationEvidence(
                "缺少任务所有权、分支或基线证据。"
            )
        }
        try validatePreparation(
            preparation,
            taskID: taskID,
            repository: repository,
            requiredCapability: requiredCapability
        )
        try validateOwnedBranch(branch, taskID: taskID)
        let branchReference = "refs/heads/\(branch)"
        if let moved = registered.first(where: { $0.branchReference == branchReference }) {
            throw WorktreeManagerError.invalidManagedPath(
                "任务分支仍注册在其他 Worktree：\(moved.path)"
            )
        }
        guard try branchExists(branch, repository: repository) else {
            throw WorktreeManagerError.invalidPreparationEvidence(
                "任务分支已不存在，无法确认此前清理结果。"
            )
        }
        try verifyBaselineIsAncestor(
            preparation.baselineCommit,
            of: branch,
            repository: repository
        )
        return TaskWorkspaceConfiguration(
            kind: .worktree,
            path: nil,
            branch: branch,
            baseBranch: configuration.baseBranch,
            preparation: preparation
        )
    }

    private func repositoryRoot(for projectPath: String) throws -> String {
        let output = try runGit(["-C", projectPath, "rev-parse", "--show-toplevel"])
        let root = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            throw WorktreeManagerError.projectIsNotGitRepository(projectPath)
        }
        return resolvedURL(root).path
    }

    private func gitlinkPaths(_ indexData: Data) -> [String]? {
        let gitlinkPrefix = Data("160000 ".utf8)
        var paths: [String] = []
        for record in indexData.split(separator: 0, omittingEmptySubsequences: true) {
            guard record.count >= gitlinkPrefix.count else { continue }
            guard record.prefix(gitlinkPrefix.count).elementsEqual(gitlinkPrefix) else {
                continue
            }
            guard let separator = record.firstIndex(of: 0x09),
                  record.index(after: separator) < record.endIndex,
                  let path = String(
                    data: Data(record[record.index(after: separator)...]),
                    encoding: .utf8
                  )
            else {
                return nil
            }
            paths.append(path)
        }
        return paths
    }

    private func unsafeIndexEntries(at path: String) throws -> [UnsafeGitIndexEntry] {
        let output = try runGitData(["-C", path, "ls-files", "-v", "-z"])
        guard let entries = unsafeIndexEntries(from: output) else {
            throw WorktreeManagerError.invalidPreparationEvidence(
                "Git index 标志输出无法安全解析。"
            )
        }
        return entries
    }

    private func unsafeIndexEntries(from output: Data) -> [UnsafeGitIndexEntry]? {
        var entries: [UnsafeGitIndexEntry] = []
        for rawRecord in output.split(separator: 0, omittingEmptySubsequences: true) {
            guard rawRecord.count >= 3,
                  rawRecord[rawRecord.startIndex + 1] == 0x20,
                  let path = String(data: Data(rawRecord.dropFirst(2)), encoding: .utf8)
            else {
                return nil
            }
            let tag = rawRecord[rawRecord.startIndex]
            let assumeUnchanged = tag >= 0x61 && tag <= 0x7A
            let skipWorktree = tag == 0x53 || tag == 0x73
            if assumeUnchanged || skipWorktree {
                entries.append(
                    UnsafeGitIndexEntry(
                        path: path,
                        assumeUnchanged: assumeUnchanged,
                        skipWorktree: skipWorktree
                    )
                )
            }
        }
        return entries
    }

    private func requireLocalCapability(
        projectPath: String,
        requiredCapability: WorktreeCapability
    ) async throws {
        switch await capability(
            projectPath: projectPath,
            requiredCapability: requiredCapability
        ) {
        case let .supported(actual) where actual == requiredCapability:
            return
        case let .supported(actual):
            throw WorktreeManagerError.capabilityMismatch(
                required: requiredCapability,
                actual: actual
            )
        case let .unsupported(reason):
            if reason.contains("初始提交") {
                throw WorktreeManagerError.repositoryHasNoInitialCommit(projectPath)
            }
            throw WorktreeManagerError.capabilityUnsupported(reason)
        case let .unavailable(reason):
            throw WorktreeManagerError.capabilityUnavailable(reason)
        }
    }

    private func requireManagedCapabilityToken(
        _ requiredCapability: WorktreeCapability
    ) throws {
        guard requiredCapability == .managedV1 else {
            throw WorktreeManagerError.capabilityUnsupported(
                "未知能力令牌：\(requiredCapability.token)"
            )
        }
    }

    private func captureSourceBaseline(repository: String) throws -> SourceBaselineCapture {
        let sourceCommit = try runGit([
            "-C", repository, "rev-parse", "--verify", "HEAD^{commit}",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceCommit.isEmpty else {
            throw WorktreeManagerError.repositoryHasNoInitialCommit(repository)
        }

        let sourceStatus = try runGitData([
            "-C", repository, "status", "--porcelain=v1", "-z", "--untracked-files=all",
        ])
        let sourceIndex = try runGitData(["-C", repository, "ls-files", "--stage", "-z"])
        let sourceIndexURL = try gitIndexURL(repository: repository)
        let sourceIndexBytes = try Data(contentsOf: sourceIndexURL)
        guard let sourceGitlinks = gitlinkPaths(sourceIndex) else {
            throw WorktreeManagerError.invalidPreparationEvidence(
                "Git submodule 路径无法安全解析。"
            )
        }
        guard sourceGitlinks.isEmpty else {
            throw WorktreeManagerError.repositoryContainsSubmodules(repository)
        }
        let unsafeEntries = try unsafeIndexEntries(at: repository)
        guard unsafeEntries.isEmpty else {
            throw WorktreeManagerError.unsupportedIndexFlags(
                unsafeEntries.map(\.statusDescription)
            )
        }
        let filesystemChanges = try unreportedFilesystemChanges(
            at: repository,
            gitAdministrativeNodeMayBeDirectory: true,
            excludeIgnored: true
        )
        guard filesystemChanges.isEmpty else {
            throw WorktreeManagerError.unsupportedFilesystemNodes(filesystemChanges)
        }
        let sourceTrackedTree = try trackedWorktreeTree(
            repository: repository,
            sourceIndexURL: sourceIndexURL,
            sourceIndexBytes: sourceIndexBytes
        )
        let temporaryIndexURL = sourceIndexURL.deletingLastPathComponent()
            .appendingPathComponent("codexboard-index-\(UUID().uuidString)")
        try sourceIndexBytes.write(to: temporaryIndexURL, options: .withoutOverwriting)
        defer {
            try? fileManager.removeItem(at: temporaryIndexURL)
            try? fileManager.removeItem(
                at: URL(fileURLWithPath: temporaryIndexURL.path + ".lock")
            )
        }
        let stashCommitOutput = try runGit(
            ["-C", repository, "stash", "create"],
            environmentOverrides: ["GIT_INDEX_FILE": temporaryIndexURL.path]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let stashCommit = stashCommitOutput.isEmpty ? nil : stashCommitOutput
        let capturedTrackedTree = try runGit([
            "-C", repository, "rev-parse", "--verify",
            "\(stashCommit ?? sourceCommit)^{tree}",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard capturedTrackedTree == sourceTrackedTree else {
            throw WorktreeManagerError.sourceWorkspaceChanged(repository)
        }
        let untrackedFiles = try capturedUntrackedFiles(repository: repository)
        let expectedBaselineTree = try baselineTree(
            repository: repository,
            trackedTree: sourceTrackedTree,
            untrackedFiles: untrackedFiles,
            sourceIndexURL: sourceIndexURL
        )
        let capture = SourceBaselineCapture(
            sourceCommit: sourceCommit,
            stashCommit: stashCommit,
            untrackedFiles: untrackedFiles,
            sourceStatus: sourceStatus,
            sourceIndex: sourceIndex,
            sourceIndexURL: sourceIndexURL,
            sourceIndexBytes: sourceIndexBytes,
            trackedWorktreeTree: sourceTrackedTree,
            expectedBaselineTree: expectedBaselineTree,
            unreportedFilesystemChanges: filesystemChanges
        )
        try verifySourceUnchanged(capture, repository: repository)
        return capture
    }

    private func capturedUntrackedFiles(repository: String) throws -> [CapturedUntrackedFile] {
        let output = try runGitData([
            "-C", repository, "ls-files", "--others", "--exclude-standard", "-z",
        ])
        let pathData = output.split(separator: 0, omittingEmptySubsequences: true)
        guard pathData.count <= maximumUntrackedFiles else {
            throw WorktreeManagerError.untrackedFileLimitExceeded(maximum: maximumUntrackedFiles)
        }

        var captured: [CapturedUntrackedFile] = []
        captured.reserveCapacity(pathData.count)
        var totalBytes: Int64 = 0
        for rawPath in pathData {
            guard let relativePath = String(data: Data(rawPath), encoding: .utf8) else {
                throw WorktreeManagerError.unsafeUntrackedPath("<非 UTF-8 路径>")
            }
            let file = try inspectUntrackedFile(relativePath, repository: repository)
            let (newTotal, overflow) = totalBytes.addingReportingOverflow(file.size)
            guard !overflow, newTotal <= maximumUntrackedBytes else {
                throw WorktreeManagerError.untrackedByteLimitExceeded(
                    maximum: maximumUntrackedBytes
                )
            }
            totalBytes = newTotal
            captured.append(file)
        }
        return captured
    }

    private func inspectUntrackedFile(
        _ relativePath: String,
        repository: String
    ) throws -> CapturedUntrackedFile {
        let path = relativePath as NSString
        let standardized = path.standardizingPath
        guard !path.isAbsolutePath,
              standardized == relativePath,
              !standardized.isEmpty,
              standardized != "..",
              !standardized.hasPrefix("../"),
              !relativePath.contains("\0")
        else {
            throw WorktreeManagerError.unsafeUntrackedPath(relativePath)
        }

        let components = path.pathComponents
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." && $0 != "/" })
        else {
            throw WorktreeManagerError.unsafeUntrackedPath(relativePath)
        }

        var current = URL(fileURLWithPath: repository, isDirectory: true)
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component, isDirectory: index < components.count - 1)
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileManager.attributesOfItem(atPath: current.path)
            } catch {
                throw WorktreeManagerError.untrackedFileChanged(relativePath)
            }
            let type = attributes[.type] as? FileAttributeType
            if index < components.count - 1 {
                guard type == .typeDirectory else {
                    throw WorktreeManagerError.unsupportedUntrackedFile(
                        path: relativePath,
                        type: type?.rawValue ?? "unknown"
                    )
                }
            } else {
                guard type == .typeRegular else {
                    throw WorktreeManagerError.unsupportedUntrackedFile(
                        path: relativePath,
                        type: type?.rawValue ?? "unknown"
                    )
                }
                guard let sizeNumber = attributes[.size] as? NSNumber,
                      sizeNumber.int64Value >= 0
                else {
                    throw WorktreeManagerError.untrackedFileChanged(relativePath)
                }
                return CapturedUntrackedFile(
                    relativePath: relativePath,
                    size: sizeNumber.int64Value,
                    modificationDate: attributes[.modificationDate] as? Date,
                    fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                    contentDigest: try contentDigest(at: current)
                )
            }
        }
        throw WorktreeManagerError.unsafeUntrackedPath(relativePath)
    }

    private func copyUntrackedFiles(
        _ files: [CapturedUntrackedFile],
        from repository: String,
        to destination: URL
    ) throws {
        for file in files {
            let beforeCopy = try inspectUntrackedFile(
                file.relativePath,
                repository: repository
            )
            guard beforeCopy.hasSameIdentity(as: file) else {
                throw WorktreeManagerError.untrackedFileChanged(file.relativePath)
            }

            let relativeComponents = (file.relativePath as NSString).pathComponents
            var parent = destination
            for component in relativeComponents.dropLast() {
                parent.appendPathComponent(component, isDirectory: true)
                if let attributes = try? fileManager.attributesOfItem(atPath: parent.path) {
                    let type = attributes[.type] as? FileAttributeType
                    guard type == .typeDirectory else {
                        throw WorktreeManagerError.unsupportedUntrackedFile(
                            path: file.relativePath,
                            type: type?.rawValue ?? "unknown"
                        )
                    }
                } else {
                    try fileManager.createDirectory(
                        at: parent,
                        withIntermediateDirectories: false
                    )
                }
            }

            let source = URL(fileURLWithPath: repository, isDirectory: true)
                .appendingPathComponent(file.relativePath, isDirectory: false)
            let target = destination.appendingPathComponent(
                file.relativePath,
                isDirectory: false
            )
            if (try? fileManager.attributesOfItem(atPath: target.path)) != nil {
                throw WorktreeManagerError.pathOccupied(target.path)
            }
            try fileManager.copyItem(at: source, to: target)

            let afterCopy = try inspectUntrackedFile(
                file.relativePath,
                repository: repository
            )
            guard afterCopy.hasSameIdentity(as: file) else {
                throw WorktreeManagerError.untrackedFileChanged(file.relativePath)
            }
            let targetAttributes = try fileManager.attributesOfItem(atPath: target.path)
            guard targetAttributes[.type] as? FileAttributeType == .typeRegular,
                  (targetAttributes[.size] as? NSNumber)?.int64Value == file.size,
                  try contentDigest(at: target) == file.contentDigest
            else {
                throw WorktreeManagerError.untrackedFileChanged(file.relativePath)
            }
        }
    }

    private func contentDigest(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return Data(hasher.finalize())
    }

    private func verifySourceUnchanged(
        _ capture: SourceBaselineCapture,
        repository: String
    ) throws {
        let currentStatus = try runGitData([
            "-C", repository, "status", "--porcelain=v1", "-z", "--untracked-files=all",
        ])
        let currentIndex = try runGitData(["-C", repository, "ls-files", "--stage", "-z"])
        let currentIndexBytes = try Data(contentsOf: capture.sourceIndexURL)
        let currentCommit = try runGit([
            "-C", repository, "rev-parse", "--verify", "HEAD^{commit}",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentCommit == capture.sourceCommit,
              currentStatus == capture.sourceStatus,
              currentIndex == capture.sourceIndex,
              currentIndexBytes == capture.sourceIndexBytes
        else {
            throw WorktreeManagerError.sourceWorkspaceChanged(repository)
        }
        for file in capture.untrackedFiles {
            let current = try inspectUntrackedFile(file.relativePath, repository: repository)
            guard current.hasSameIdentity(as: file) else {
                throw WorktreeManagerError.untrackedFileChanged(file.relativePath)
            }
        }
        let currentTrackedTree = try trackedWorktreeTree(
            repository: repository,
            sourceIndexURL: capture.sourceIndexURL,
            sourceIndexBytes: currentIndexBytes
        )
        guard currentTrackedTree == capture.trackedWorktreeTree else {
            throw WorktreeManagerError.sourceWorkspaceChanged(repository)
        }
        let currentFilesystemChanges = try unreportedFilesystemChanges(
            at: repository,
            gitAdministrativeNodeMayBeDirectory: true,
            excludeIgnored: true
        )
        guard currentFilesystemChanges == capture.unreportedFilesystemChanges else {
            throw WorktreeManagerError.sourceWorkspaceChanged(repository)
        }
    }

    private func trackedWorktreeTree(
        repository: String,
        sourceIndexURL: URL,
        sourceIndexBytes: Data
    ) throws -> String {
        let temporaryIndexURL = sourceIndexURL.deletingLastPathComponent()
            .appendingPathComponent("codexboard-tree-index-\(UUID().uuidString)")
        try sourceIndexBytes.write(to: temporaryIndexURL, options: .withoutOverwriting)
        defer {
            try? fileManager.removeItem(at: temporaryIndexURL)
            try? fileManager.removeItem(
                at: URL(fileURLWithPath: temporaryIndexURL.path + ".lock")
            )
        }
        let environment = ["GIT_INDEX_FILE": temporaryIndexURL.path]
        _ = try runGit(
            ["-C", repository, "add", "-u", "--"],
            environmentOverrides: environment
        )
        let tree = try runGit(
            ["-C", repository, "write-tree"],
            environmentOverrides: environment
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidObjectID(tree) else {
            throw WorktreeManagerError.invalidPreparationEvidence(
                "无法生成源工作区的一致内容指纹。"
            )
        }
        return tree
    }

    private func baselineTree(
        repository: String,
        trackedTree: String,
        untrackedFiles: [CapturedUntrackedFile],
        sourceIndexURL: URL
    ) throws -> String {
        let temporaryIndexURL = sourceIndexURL.deletingLastPathComponent()
            .appendingPathComponent("codexboard-baseline-index-\(UUID().uuidString)")
        defer {
            try? fileManager.removeItem(at: temporaryIndexURL)
            try? fileManager.removeItem(
                at: URL(fileURLWithPath: temporaryIndexURL.path + ".lock")
            )
        }
        let environment = ["GIT_INDEX_FILE": temporaryIndexURL.path]
        _ = try runGit(
            ["-C", repository, "read-tree", trackedTree],
            environmentOverrides: environment
        )
        for batchStart in stride(from: 0, to: untrackedFiles.count, by: 100) {
            let batchEnd = min(batchStart + 100, untrackedFiles.count)
            let paths = untrackedFiles[batchStart ..< batchEnd].map(\.relativePath)
            _ = try runGit(
                ["-C", repository, "add", "-f", "--"] + paths,
                environmentOverrides: environment
            )
        }
        let tree = try runGit(
            ["-C", repository, "write-tree"],
            environmentOverrides: environment
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidObjectID(tree) else {
            throw WorktreeManagerError.invalidPreparationEvidence(
                "无法生成完整源工作区的基线内容指纹。"
            )
        }
        return tree
    }

    private func gitIndexURL(repository: String) throws -> URL {
        let rawPath = try runGit(["-C", repository, "rev-parse", "--git-path", "index"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else {
            throw WorktreeManagerError.invalidPreparationEvidence("Git index 路径为空。")
        }
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath)
        }
        return URL(fileURLWithPath: repository, isDirectory: true)
            .appendingPathComponent(rawPath)
            .standardizedFileURL
    }

    private func createBaselineCommit(
        taskID: UUID,
        sourceCommit: String,
        dirtyBaseCaptured: Bool,
        untrackedFiles: [CapturedUntrackedFile],
        expectedBaselineTree: String,
        worktreePath: String
    ) throws -> String {
        _ = try runGit(["-C", worktreePath, "add", "-A"])
        for batchStart in stride(from: 0, to: untrackedFiles.count, by: 100) {
            let batchEnd = min(batchStart + 100, untrackedFiles.count)
            let paths = untrackedFiles[batchStart ..< batchEnd].map(\.relativePath)
            _ = try runGit(["-C", worktreePath, "add", "-f", "--"] + paths)
        }
        let stagedTree = try runGit([
            "-C", worktreePath, "write-tree",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard stagedTree == expectedBaselineTree else {
            throw WorktreeManagerError.invalidPreparationEvidence(
                "目标 Worktree 内容指纹与捕获的源工作区不一致。"
            )
        }
        let message = """
        CodexBoard managed baseline

        CodexBoard-Capability: \(WorktreeCapability.managedV1.token)
        CodexBoard-Owner-Task: \(taskID.uuidString.lowercased())
        CodexBoard-Source-Commit: \(sourceCommit)
        CodexBoard-Dirty-Base: \(dirtyBaseCaptured ? 1 : 0)
        CodexBoard-Untracked-Files: \(untrackedFiles.count)
        """
        _ = try runGit([
            "-c", "user.name=CodexBoard",
            "-c", "user.email=codexboard@localhost.invalid",
            "-C", worktreePath,
            "commit", "--allow-empty", "--no-verify", "-m", message,
        ])
        let baselineCommit = try runGit([
            "-C", worktreePath, "rev-parse", "--verify", "HEAD^{commit}",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        let baselineTree = try runGit([
            "-C", worktreePath, "rev-parse", "--verify", "HEAD^{tree}",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard baselineTree == expectedBaselineTree else {
            throw WorktreeManagerError.invalidPreparationEvidence(
                "基线提交内容指纹与捕获的源工作区不一致。"
            )
        }
        let parent = try runGit([
            "-C", worktreePath, "rev-parse", "--verify", "HEAD^1",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard parent == sourceCommit else {
            throw WorktreeManagerError.invalidPreparationEvidence(
                "基线提交的父提交与源 HEAD 不一致。"
            )
        }
        let remainingChanges = try worktreeChanges(at: worktreePath)
        guard remainingChanges.isEmpty else {
            throw WorktreeManagerError.invalidPreparationEvidence(
                "基线提交后 Worktree 仍有未捕获改动。"
            )
        }
        return baselineCommit
    }

    private func validatedOrRecoveredPreparation(
        taskID: UUID,
        repository: String,
        worktreePath: String,
        configuration: TaskWorkspaceConfiguration,
        requiredCapability: WorktreeCapability
    ) throws -> (preparation: TaskWorktreePreparation, branch: String) {
        let resolvedPath = resolvedURL(worktreePath).path
        guard isDescendant(resolvedURL(worktreePath), of: resolvedManagedRoot)
        else {
            throw WorktreeManagerError.invalidManagedPath(worktreePath)
        }
        let branch = try currentBranch(at: resolvedPath)
        try validateOwnedBranch(branch, taskID: taskID)
        let branchReference = "refs/heads/\(branch)"
        guard try registeredWorktrees(repository: repository).contains(where: {
            $0.path == resolvedPath && $0.branchReference == branchReference
        }) else {
            throw WorktreeManagerError.invalidManagedPath(worktreePath)
        }
        if let expectedBranch = configuration.branch, expectedBranch != branch {
            if configuration.preparation == nil {
                throw WorktreeManagerError.capturedStatePreserved(
                    path: resolvedPath,
                    branch: branch,
                    reason: WorktreeManagerError.branchMismatch(
                        expected: expectedBranch,
                        actual: branch
                    ).localizedDescription
                )
            }
            throw WorktreeManagerError.branchMismatch(expected: expectedBranch, actual: branch)
        }
        let preparation: TaskWorktreePreparation
        if let existing = configuration.preparation {
            try validatePreparation(
                existing,
                taskID: taskID,
                repository: repository,
                requiredCapability: requiredCapability
            )
            preparation = existing
        } else {
            do {
                preparation = try recoverPreparation(
                    taskID: taskID,
                    repository: repository,
                    worktreePath: worktreePath,
                    requiredCapability: requiredCapability
                )
            } catch {
                throw WorktreeManagerError.capturedStatePreserved(
                    path: resolvedPath,
                    branch: branch,
                    reason: error.localizedDescription
                )
            }
        }
        try verifyBaselineIsAncestor(
            preparation.baselineCommit,
            of: branch,
            repository: repository
        )
        return (preparation, branch)
    }

    private func recoverPreparation(
        taskID: UUID,
        repository: String,
        worktreePath: String,
        requiredCapability: WorktreeCapability
    ) throws -> TaskWorktreePreparation {
        let owner = taskID.uuidString.lowercased()
        let baselineCommit = try runGit([
            "-C", worktreePath, "log", "-n", "1", "--format=%H", "--fixed-strings",
            "--grep=CodexBoard-Owner-Task: \(owner)",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baselineCommit.isEmpty else {
            throw WorktreeManagerError.invalidPreparationEvidence(
                "任务分支中找不到 CodexBoard 所有权提交。"
            )
        }
        let message = try runGit(["-C", worktreePath, "show", "-s", "--format=%B", baselineCommit])
        let trailers = baselineTrailers(message)
        guard trailers["CodexBoard-Capability"] == requiredCapability.token,
              trailers["CodexBoard-Owner-Task"] == owner,
              let sourceCommit = trailers["CodexBoard-Source-Commit"],
              let dirtyValue = trailers["CodexBoard-Dirty-Base"],
              dirtyValue == "0" || dirtyValue == "1",
              let untrackedValue = trailers["CodexBoard-Untracked-Files"],
              let untrackedCount = Int(untrackedValue),
              untrackedCount >= 0
        else {
            throw WorktreeManagerError.invalidPreparationEvidence("基线提交元数据缺失或无效。")
        }
        let parent = try runGit([
            "-C", worktreePath, "rev-parse", "--verify", "\(baselineCommit)^1",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard parent == sourceCommit else {
            throw WorktreeManagerError.invalidPreparationEvidence(
                "基线提交的父提交与证据不一致。"
            )
        }
        return TaskWorktreePreparation(
            capability: requiredCapability,
            ownerTaskID: taskID,
            repositoryPath: repository,
            sourceCommit: sourceCommit,
            baselineCommit: baselineCommit,
            dirtyBaseCaptured: dirtyValue == "1",
            untrackedFilesCaptured: untrackedCount,
            preparedAt: try commitDate(commit: baselineCommit, repository: worktreePath)
        )
    }

    private func baselineTrailers(_ message: String) -> [String: String] {
        let keys = [
            "CodexBoard-Capability", "CodexBoard-Owner-Task", "CodexBoard-Source-Commit",
            "CodexBoard-Dirty-Base", "CodexBoard-Untracked-Files",
        ]
        return message.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, line in
            for key in keys {
                let prefix = "\(key): "
                if line.hasPrefix(prefix) {
                    result[key] = String(line.dropFirst(prefix.count))
                }
            }
        }
    }

    private func commitDate(commit: String, repository: String) throws -> Date {
        let value = try runGit(["-C", repository, "show", "-s", "--format=%cI", commit])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else {
            throw WorktreeManagerError.invalidPreparationEvidence("无法解析基线提交时间。")
        }
        return date
    }

    private func validatePreparation(
        _ preparation: TaskWorktreePreparation,
        taskID: UUID,
        repository: String,
        requiredCapability: WorktreeCapability
    ) throws {
        guard preparation.capability == requiredCapability else {
            throw WorktreeManagerError.capabilityMismatch(
                required: requiredCapability,
                actual: preparation.capability
            )
        }
        guard preparation.ownerTaskID == taskID else {
            throw WorktreeManagerError.invalidPreparationEvidence("任务所有者不匹配。")
        }
        guard resolvedURL(preparation.repositoryPath).path == resolvedURL(repository).path else {
            throw WorktreeManagerError.invalidPreparationEvidence("源仓库不匹配。")
        }
        guard isValidObjectID(preparation.sourceCommit),
              isValidObjectID(preparation.baselineCommit)
        else {
            throw WorktreeManagerError.invalidPreparationEvidence("提交证据格式无效。")
        }
    }

    private func isValidObjectID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.unicodeScalars.allSatisfy { scalar in
                ("0" ... "9").contains(Character(scalar))
                    || ("a" ... "f").contains(Character(scalar))
                    || ("A" ... "F").contains(Character(scalar))
            }
    }

    private func validatedManagedWorktree(
        taskID: UUID,
        projectPath: String,
        configuration: TaskWorkspaceConfiguration,
        requiredCapability: WorktreeCapability
    ) throws -> ValidatedManagedWorktree {
        let repository = try repositoryRoot(for: projectPath)
        guard let preparation = configuration.preparation else {
            throw WorktreeManagerError.invalidPreparationEvidence("缺少任务所有权与基线证据。")
        }
        try validatePreparation(
            preparation,
            taskID: taskID,
            repository: repository,
            requiredCapability: requiredCapability
        )
        guard let path = configuration.path else {
            throw WorktreeManagerError.invalidPreparationEvidence("缺少 Worktree 路径。")
        }
        let worktreeURL = resolvedURL(path)
        let expectedURL = resolvedURL(destinationURL(repository: repository, taskID: taskID).path)
        guard worktreeURL.path == expectedURL.path,
              isDescendant(worktreeURL, of: resolvedManagedRoot),
              fileManager.fileExists(atPath: worktreeURL.path),
              try registeredWorktreePaths(repository: repository).contains(worktreeURL.path)
        else {
            throw WorktreeManagerError.invalidManagedPath(worktreeURL.path)
        }
        guard let expectedBranch = configuration.branch else {
            throw WorktreeManagerError.invalidPreparationEvidence("缺少任务分支证据。")
        }
        _ = try validatedBranch(
            expected: expectedBranch,
            worktreePath: worktreeURL.path,
            repository: repository
        )
        try verifyBaselineIsAncestor(
            preparation.baselineCommit,
            of: expectedBranch,
            repository: repository
        )
        return ValidatedManagedWorktree(repository: repository, path: worktreeURL.path)
    }

    private func cleanupUnprovenOwnedWorktree(
        taskID: UUID,
        projectPath: String,
        configuration: TaskWorkspaceConfiguration
    ) throws -> TaskWorkspaceConfiguration {
        let repository = try repositoryRoot(for: projectPath)
        guard let path = configuration.path else { return configuration }
        let destination = destinationURL(repository: repository, taskID: taskID)
        let expectedPath = try validatedDestinationPath(destination, repository: repository)
        let worktreePath = resolvedURL(path).path
        guard worktreePath == expectedPath else {
            throw WorktreeManagerError.invalidManagedPath(worktreePath)
        }

        let registered = try registeredWorktrees(repository: repository)
        guard fileManager.fileExists(atPath: worktreePath) else {
            guard !registered.contains(where: { registration in
                registration.path == worktreePath
                    || registration.branchReference.map {
                        isOwnedBranchReference($0, taskID: taskID)
                    } == true
            }) else {
                throw WorktreeManagerError.invalidManagedPath(
                    "任务 Worktree 仍注册在其他路径，无法确认已清理：\(worktreePath)"
                )
            }
            if let branch = configuration.branch {
                try validateOwnedBranch(branch, taskID: taskID)
            }
            return TaskWorkspaceConfiguration(
                kind: .worktree,
                path: nil,
                branch: configuration.branch,
                baseBranch: configuration.baseBranch,
                preparation: nil
            )
        }

        let validated = try validatedUnprovenOwnedWorktree(
            taskID: taskID,
            projectPath: projectPath,
            configuration: configuration
        )
        let changes = try worktreeChanges(at: validated.path)
        guard changes.isEmpty else {
            throw WorktreeManagerError.dirtyWorktree(changes)
        }
        let branch = try currentBranch(at: validated.path)
        try validateOwnedBranch(branch, taskID: taskID)
        _ = try runGit(["-C", validated.repository, "worktree", "remove", validated.path])
        return TaskWorkspaceConfiguration(
            kind: .worktree,
            path: nil,
            branch: branch,
            baseBranch: configuration.baseBranch,
            preparation: nil
        )
    }

    private func validatedUnprovenOwnedWorktree(
        taskID: UUID,
        projectPath: String,
        configuration: TaskWorkspaceConfiguration
    ) throws -> ValidatedManagedWorktree {
        let repository = try repositoryRoot(for: projectPath)
        guard let path = configuration.path else {
            throw WorktreeManagerError.invalidPreparationEvidence("缺少 Worktree 路径。")
        }
        let destination = destinationURL(repository: repository, taskID: taskID)
        let expectedPath = try validatedDestinationPath(destination, repository: repository)
        let worktreePath = resolvedURL(path).path
        guard worktreePath == expectedPath,
              fileManager.fileExists(atPath: worktreePath)
        else {
            throw WorktreeManagerError.invalidManagedPath(worktreePath)
        }
        let actualBranch = try currentBranch(at: worktreePath)
        if let expectedBranch = configuration.branch, expectedBranch != actualBranch {
            throw WorktreeManagerError.branchMismatch(
                expected: expectedBranch,
                actual: actualBranch
            )
        }
        try validateOwnedBranch(actualBranch, taskID: taskID)
        let branchReference = "refs/heads/\(actualBranch)"
        guard try registeredWorktrees(repository: repository).contains(where: {
            $0.path == worktreePath && $0.branchReference == branchReference
        }) else {
            throw WorktreeManagerError.invalidManagedPath(worktreePath)
        }
        return ValidatedManagedWorktree(repository: repository, path: worktreePath)
    }

    private func isOwnedBranchReference(_ reference: String, taskID: UUID) -> Bool {
        let prefix = "refs/heads/"
        guard reference.hasPrefix(prefix) else { return false }
        return (try? validateOwnedBranch(
            String(reference.dropFirst(prefix.count)),
            taskID: taskID
        )) != nil
    }

    private func validatedBranch(
        expected: String,
        worktreePath: String,
        repository: String
    ) throws -> String {
        guard try registeredWorktreePaths(repository: repository).contains(resolvedURL(worktreePath).path) else {
            throw WorktreeManagerError.invalidManagedPath(worktreePath)
        }
        let actual = try currentBranch(at: worktreePath)
        guard actual == expected else {
            throw WorktreeManagerError.branchMismatch(expected: expected, actual: actual)
        }
        return actual
    }

    private func verifyBaselineIsAncestor(
        _ baselineCommit: String,
        of branch: String,
        repository: String
    ) throws {
        let arguments = [
            "-C", repository, "merge-base", "--is-ancestor", baselineCommit, branch,
        ]
        let result = runGitResult(arguments)
        if result.status == 0 { return }
        if result.status == 1 {
            throw WorktreeManagerError.invalidPreparationEvidence(
                "基线提交不在任务分支历史中。"
            )
        }
        throw gitError(arguments: arguments, result: result)
    }

    private func branchExists(_ branch: String, repository: String) throws -> Bool {
        let arguments = [
            "-C", repository, "show-ref", "--verify", "--quiet", "refs/heads/\(branch)",
        ]
        let result = runGitResult(arguments)
        if result.status == 0 { return true }
        if result.status == 1 { return false }
        throw gitError(arguments: arguments, result: result)
    }

    private func currentBranch(at path: String) throws -> String {
        let branch = try runGit(["-C", path, "branch", "--show-current"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? "HEAD" : branch
    }

    private func taskBranch(taskID: UUID) -> String {
        "codex/task-\(taskID.uuidString.lowercased())"
    }

    private func validateOwnedBranch(_ branch: String, taskID: UUID) throws {
        let fullBranch = taskBranch(taskID: taskID)
        let legacyBranch = "codex/task-\(taskID.uuidString.prefix(8).lowercased())"
        let attemptPrefix = "\(fullBranch)-attempt-"
        let attemptIsOwned: Bool
        if branch.hasPrefix(attemptPrefix),
           let attempt = Int(branch.dropFirst(attemptPrefix.count)),
           attempt >= 2 {
            attemptIsOwned = branch == "\(attemptPrefix)\(attempt)"
        } else {
            attemptIsOwned = false
        }
        guard branch == fullBranch || branch == legacyBranch || attemptIsOwned else {
            throw WorktreeManagerError.invalidPreparationEvidence(
                "任务分支不符合当前任务的所有权命名。"
            )
        }
    }

    private func nextAvailableTaskBranch(
        taskID: UUID,
        repository: String
    ) throws -> String {
        let fullBranch = taskBranch(taskID: taskID)
        if try !branchExists(fullBranch, repository: repository) {
            return fullBranch
        }
        for attempt in 2 ... 10_000 {
            let candidate = "\(fullBranch)-attempt-\(attempt)"
            if try !branchExists(candidate, repository: repository) {
                return candidate
            }
        }
        throw WorktreeManagerError.branchAlreadyExists(
            "\(fullBranch)-attempt-2…10000"
        )
    }

    private func destinationURL(repository: String, taskID: UUID) -> URL {
        let name = URL(fileURLWithPath: repository).lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        let hash = repository.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return managedRoot
            .appendingPathComponent("\(name)-\(String(hash, radix: 16))", isDirectory: true)
            .appendingPathComponent(taskID.uuidString.lowercased(), isDirectory: true)
    }

    private func validatedDestinationPath(
        _ destination: URL,
        repository: String
    ) throws -> String {
        let resolvedRepository = resolvedURL(repository)
        let resolvedDestination = resolvedURL(destination.path)
        guard isDescendant(resolvedDestination, of: resolvedManagedRoot),
              resolvedDestination.path != resolvedRepository.path,
              !isDescendant(resolvedDestination, of: resolvedRepository),
              !isDescendant(resolvedRepository, of: resolvedDestination)
        else {
            throw WorktreeManagerError.invalidManagedPath(destination.path)
        }
        return resolvedDestination.path
    }

    private func validatedAddedWorktreePath(
        _ destination: URL,
        repository: String,
        branch: String
    ) throws -> String {
        let path = try validatedDestinationPath(destination, repository: repository)
        let branchReference = "refs/heads/\(branch)"
        guard try registeredWorktrees(repository: repository).contains(where: {
            $0.path == path && $0.branchReference == branchReference
        }) else {
            throw WorktreeManagerError.invalidManagedPath(path)
        }
        return path
    }

    private var resolvedManagedRoot: URL {
        managedRoot.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func registeredWorktreePaths(repository: String) throws -> Set<String> {
        Set(try registeredWorktrees(repository: repository).map(\.path))
    }

    private func registeredWorktrees(repository: String) throws -> [RegisteredWorktree] {
        let output = try runGitData([
            "-C", repository, "worktree", "list", "--porcelain", "-z",
        ])
        var worktrees: [RegisteredWorktree] = []
        var path: String?
        var branchReference: String?

        func appendCurrent() {
            guard let path else { return }
            worktrees.append(
                RegisteredWorktree(
                    path: resolvedURL(path).path,
                    branchReference: branchReference
                )
            )
        }

        for rawField in output.split(separator: 0, omittingEmptySubsequences: false) {
            if rawField.isEmpty {
                appendCurrent()
                path = nil
                branchReference = nil
                continue
            }
            guard let field = String(data: Data(rawField), encoding: .utf8) else {
                throw WorktreeManagerError.invalidPreparationEvidence(
                    "Git worktree 注册信息包含非 UTF-8 字段。"
                )
            }
            if field.hasPrefix("worktree ") {
                guard path == nil else {
                    throw WorktreeManagerError.invalidPreparationEvidence(
                        "Git worktree 注册信息缺少记录分隔符。"
                    )
                }
                path = String(field.dropFirst("worktree ".count))
            } else if field.hasPrefix("branch ") {
                branchReference = String(field.dropFirst("branch ".count))
            }
        }
        if path != nil {
            appendCurrent()
        }
        return worktrees
    }

    private func resolvedURL(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private func isDescendant(_ candidate: URL, of parent: URL) -> Bool {
        let parentComponents = parent.pathComponents
        let candidateComponents = candidate.pathComponents
        return candidateComponents.count > parentComponents.count
            && candidateComponents.prefix(parentComponents.count).elementsEqual(parentComponents)
    }

    private func rollbackAddedWorktree(
        repository: String,
        destination: URL,
        branch: String,
        deleteBranch: Bool,
        expectedBranchTip: String?
    ) -> PreservedWorktreeState? {
        let branchReference = "refs/heads/\(branch)"
        let registeredPath = (try? registeredWorktrees(repository: repository))?
            .first(where: { $0.branchReference == branchReference })?
            .path
        let path = registeredPath ?? resolvedURL(destination.path).path
        if fileManager.fileExists(atPath: path) {
            do {
                let changes = try worktreeChanges(at: path)
                guard changes.isEmpty else {
                    return PreservedWorktreeState(
                        path: path,
                        reason: "回滚前发现 Worktree 中出现用户状态：\(changes.prefix(5).joined(separator: "、"))"
                    )
                }
            } catch {
                return PreservedWorktreeState(
                    path: path,
                    reason: "回滚前无法证明 Worktree 安全：\(error.localizedDescription)"
                )
            }
        } else if registeredPath != nil {
            return PreservedWorktreeState(
                path: path,
                reason: "Worktree 仍在 Git 注册表中，但路径当前不可访问。"
            )
        } else {
            removeUnregisteredBranchIfUnchanged(
                repository: repository,
                branch: branch,
                expectedTip: expectedBranchTip
            )
            return nil
        }

        let removeResult = runGitResult([
            "-C", repository, "worktree", "remove", path,
        ])
        guard removeResult.status == 0 else {
            return PreservedWorktreeState(
                path: path,
                reason: "Git 拒绝安全回滚：\(gitMessage(removeResult))"
            )
        }
        if deleteBranch {
            removeUnregisteredBranchIfUnchanged(
                repository: repository,
                branch: branch,
                expectedTip: expectedBranchTip
            )
        }
        return nil
    }

    private func preservedWorktreeAfterFailedAdd(
        repository: String,
        destination: URL,
        branch: String
    ) -> PreservedWorktreeState? {
        let branchReference = "refs/heads/\(branch)"
        if let registered = (try? registeredWorktrees(repository: repository))?
            .first(where: { $0.branchReference == branchReference }) {
            return PreservedWorktreeState(
                path: registered.path,
                reason: "git worktree add 失败后仍留下注册记录，已保留现场。"
            )
        }
        let path = resolvedURL(destination.path).path
        guard fileManager.fileExists(atPath: path) else { return nil }
        return PreservedWorktreeState(
            path: path,
            reason: "git worktree add 失败后仍留下目录，已保留现场。"
        )
    }

    private func removeUnregisteredBranchIfUnchanged(
        repository: String,
        branch: String,
        expectedTip: String?
    ) {
        guard let expectedTip,
              (try? registeredWorktrees(repository: repository).contains(where: {
                  $0.branchReference == "refs/heads/\(branch)"
              })) == false,
              let actualTip = try? runGit([
                  "-C", repository, "rev-parse", "--verify", "refs/heads/\(branch)^{commit}",
              ]).trimmingCharacters(in: .whitespacesAndNewlines),
              actualTip == expectedTip
        else { return }
        _ = runGitResult(["-C", repository, "branch", "-d", branch])
    }

    private func runGit(
        _ arguments: [String],
        environmentOverrides: [String: String] = [:]
    ) throws -> String {
        let result = runGitResult(arguments, environmentOverrides: environmentOverrides)
        guard result.status == 0 else {
            throw gitError(arguments: arguments, result: result)
        }
        return result.output
    }

    private func runGitData(_ arguments: [String]) throws -> Data {
        let result = runGitResult(arguments)
        guard result.status == 0 else {
            throw gitError(arguments: arguments, result: result)
        }
        return result.outputData
    }

    private func gitError(
        arguments: [String],
        result: GitCommandResult
    ) -> WorktreeManagerError {
        if result.timedOut {
            return .gitTimedOut(arguments: arguments, seconds: Int(gitTimeout.rounded(.up)))
        }
        return .gitFailed(arguments: arguments, message: gitMessage(result))
    }

    private func gitMessage(_ result: GitCommandResult) -> String {
        let error = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
        if !error.isEmpty { return error }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isRepositoryUnsupported(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("not a git repository")
            || lowercased.contains("cannot change to")
            || lowercased.contains("no such file or directory")
    }

    private func isMissingInitialCommit(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("needed a single revision")
            || lowercased.contains("unknown revision")
            || lowercased.contains("ambiguous argument 'head")
            || lowercased.contains("bad revision 'head")
            || lowercased.contains("does not have any commits yet")
            || lowercased.contains("not a valid object name head")
    }

    private func runGitResult(
        _ arguments: [String],
        environmentOverrides: [String: String] = [:]
    ) -> GitCommandResult {
        let process = Process()
        let captureDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("codexboard-git-\(UUID().uuidString)", isDirectory: true)
        let outputURL = captureDirectory.appendingPathComponent("stdout")
        let errorURL = captureDirectory.appendingPathComponent("stderr")
        do {
            try fileManager.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
            guard fileManager.createFile(atPath: outputURL.path, contents: nil),
                  fileManager.createFile(atPath: errorURL.path, contents: nil)
            else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            return GitCommandResult(
                status: -1,
                outputData: Data(),
                error: error.localizedDescription,
                timedOut: false
            )
        }
        defer { try? fileManager.removeItem(at: captureDirectory) }

        let outputHandle: FileHandle
        let errorHandle: FileHandle
        do {
            outputHandle = try FileHandle(forWritingTo: outputURL)
            errorHandle = try FileHandle(forWritingTo: errorURL)
        } catch {
            return GitCommandResult(
                status: -1,
                outputData: Data(),
                error: error.localizedDescription,
                timedOut: false
            )
        }
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        process.executableURL = gitExecutableURL
        process.arguments = [
            "-c", "core.hooksPath=/dev/null",
            "-c", "commit.gpgSign=false",
            "-c", "tag.gpgSign=false",
        ] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("GIT_") {
            environment.removeValue(forKey: key)
        }
        environment.removeValue(forKey: "SSH_ASKPASS")
        environment.removeValue(forKey: "GCM_INTERACTIVE")
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        for (key, value) in environmentOverrides {
            environment[key] = value
        }
        process.environment = environment
        do {
            try process.run()
        } catch {
            return GitCommandResult(
                status: -1,
                outputData: Data(),
                error: error.localizedDescription,
                timedOut: false
            )
        }

        let deadline = Date().addingTimeInterval(gitTimeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        try? outputHandle.synchronize()
        try? errorHandle.synchronize()
        let outputData = (try? Data(contentsOf: outputURL)) ?? Data()
        let error = String(decoding: (try? Data(contentsOf: errorURL)) ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return GitCommandResult(
            status: process.terminationStatus,
            outputData: outputData,
            error: timedOut && error.isEmpty ? "Git command timed out." : error,
            timedOut: timedOut
        )
    }
}

private struct GitCommandResult {
    let status: Int32
    let outputData: Data
    let error: String
    let timedOut: Bool

    var output: String { String(decoding: outputData, as: UTF8.self) }
}

private struct CapturedUntrackedFile {
    let relativePath: String
    let size: Int64
    let modificationDate: Date?
    let fileNumber: UInt64?
    let contentDigest: Data

    func hasSameIdentity(as other: CapturedUntrackedFile) -> Bool {
        relativePath == other.relativePath
            && size == other.size
            && modificationDate == other.modificationDate
            && fileNumber == other.fileNumber
            && contentDigest == other.contentDigest
    }
}

private struct SourceBaselineCapture {
    let sourceCommit: String
    let stashCommit: String?
    let untrackedFiles: [CapturedUntrackedFile]
    let sourceStatus: Data
    let sourceIndex: Data
    let sourceIndexURL: URL
    let sourceIndexBytes: Data
    let trackedWorktreeTree: String
    let expectedBaselineTree: String
    let unreportedFilesystemChanges: [String]

    var isDirty: Bool { stashCommit != nil || !untrackedFiles.isEmpty }
}

private struct ValidatedManagedWorktree {
    let repository: String
    let path: String
}

private struct RegisteredWorktree {
    let path: String
    let branchReference: String?
}

private struct PreservedWorktreeState {
    let path: String
    let reason: String
}

private struct UnsafeGitIndexEntry {
    let path: String
    let assumeUnchanged: Bool
    let skipWorktree: Bool

    var statusDescription: String {
        var flags: [String] = []
        if assumeUnchanged { flags.append("assume-unchanged") }
        if skipWorktree { flags.append("skip-worktree") }
        return "INDEX \(path.debugDescription) [\(flags.joined(separator: ", "))]"
    }
}
