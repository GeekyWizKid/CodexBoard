import Foundation

struct WorktreeStatus: Hashable, Sendable {
    let isClean: Bool
    let changes: [String]
}

protocol WorktreeManaging: Sendable {
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
}

enum WorktreeManagerError: LocalizedError {
    case projectIsNotGitRepository(String)
    case pathOccupied(String)
    case invalidManagedPath(String)
    case branchMismatch(expected: String, actual: String)
    case dirtyWorktree([String])
    case gitFailed(arguments: [String], message: String)

    var errorDescription: String? {
        switch self {
        case let .projectIsNotGitRepository(path):
            "无法创建 Worktree：\(path) 不是可用的 Git 仓库。"
        case let .pathOccupied(path):
            "Worktree 目标路径已被占用：\(path)"
        case let .invalidManagedPath(path):
            "拒绝使用或清理不受 CodexBoard 管理的 Worktree：\(path)"
        case let .branchMismatch(expected, actual):
            "Worktree 分支不匹配：预期 \(expected)，实际 \(actual)。"
        case let .dirtyWorktree(changes):
            "Worktree 仍有未提交改动，已保留现场：\(changes.prefix(5).joined(separator: "、"))"
        case let .gitFailed(arguments, message):
            "Git 命令失败（git \(arguments.joined(separator: " "))）：\(message)"
        }
    }
}

actor WorktreeManager: WorktreeManaging {
    private let managedRoot: URL
    private let gitExecutableURL: URL
    private let fileManager: FileManager

    init(
        managedRoot: URL? = nil,
        gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        fileManager: FileManager = .default
    ) {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        self.managedRoot = managedRoot
            ?? applicationSupport.appendingPathComponent("CodexBoard/worktrees", isDirectory: true)
        self.gitExecutableURL = gitExecutableURL
        self.fileManager = fileManager
    }

    func prepare(
        taskID: UUID,
        projectPath: String,
        configuration: TaskWorkspaceConfiguration
    ) async throws -> TaskWorkspaceConfiguration {
        guard configuration.kind == .worktree else { return .project }
        let repository = try repositoryRoot(for: projectPath)

        if let persistedPath = configuration.path {
            let url = URL(fileURLWithPath: persistedPath, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard isDescendant(url, of: resolvedManagedRoot) else {
                throw WorktreeManagerError.invalidManagedPath(url.path)
            }
            guard fileManager.fileExists(atPath: url.path) else {
                throw WorktreeManagerError.pathOccupied("已记录的 Worktree 不存在：\(url.path)")
            }
            guard registeredWorktreePaths(repository: repository).contains(url.path) else {
                throw WorktreeManagerError.invalidManagedPath(url.path)
            }
            let actualBranch = try currentBranch(at: url.path)
            if let expected = configuration.branch, expected != actualBranch {
                throw WorktreeManagerError.branchMismatch(expected: expected, actual: actualBranch)
            }
            return TaskWorkspaceConfiguration(
                kind: .worktree,
                path: url.path,
                branch: actualBranch,
                baseBranch: configuration.baseBranch
            )
        }

        let baseBranch: String
        if let configuredBase = configuration.baseBranch {
            baseBranch = configuredBase
        } else {
            baseBranch = try currentBranch(at: repository)
        }
        let branch = configuration.branch ?? "codex/task-\(taskID.uuidString.prefix(8).lowercased())"
        let destination = destinationURL(repository: repository, taskID: taskID)

        if fileManager.fileExists(atPath: destination.path) {
            throw WorktreeManagerError.pathOccupied(destination.path)
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let branchExists = runGitResult(
            ["-C", repository, "show-ref", "--verify", "--quiet", "refs/heads/\(branch)"]
        ).status == 0
        if branchExists {
            _ = try runGit(["-C", repository, "worktree", "add", destination.path, branch])
        } else {
            _ = try runGit(["-C", repository, "worktree", "add", "-b", branch, destination.path, baseBranch])
        }

        return TaskWorkspaceConfiguration(
            kind: .worktree,
            path: destination.path,
            branch: branch,
            baseBranch: baseBranch
        )
    }

    func status(configuration: TaskWorkspaceConfiguration) async throws -> WorktreeStatus {
        guard configuration.kind == .worktree, let path = configuration.path else {
            return WorktreeStatus(isClean: true, changes: [])
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard isDescendant(url, of: resolvedManagedRoot) else {
            throw WorktreeManagerError.invalidManagedPath(url.path)
        }
        let output = try runGit(["-C", url.path, "status", "--porcelain", "--untracked-files=normal"])
        let changes = output.split(whereSeparator: \.isNewline).map(String.init)
        return WorktreeStatus(isClean: changes.isEmpty, changes: changes)
    }

    func cleanup(
        projectPath: String,
        configuration: TaskWorkspaceConfiguration
    ) async throws -> TaskWorkspaceConfiguration {
        guard configuration.kind == .worktree, let path = configuration.path else {
            return configuration
        }
        let worktreeURL = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard isDescendant(worktreeURL, of: resolvedManagedRoot) else {
            throw WorktreeManagerError.invalidManagedPath(worktreeURL.path)
        }

        let repository = try repositoryRoot(for: projectPath)

        if fileManager.fileExists(atPath: worktreeURL.path) {
            guard registeredWorktreePaths(repository: repository).contains(worktreeURL.path) else {
                throw WorktreeManagerError.invalidManagedPath(worktreeURL.path)
            }
            let currentStatus = try await status(configuration: configuration)
            guard currentStatus.isClean else {
                throw WorktreeManagerError.dirtyWorktree(currentStatus.changes)
            }
            _ = try runGit(["-C", repository, "worktree", "remove", worktreeURL.path])
        }
        _ = runGitResult(["-C", repository, "worktree", "prune"])

        return TaskWorkspaceConfiguration(
            kind: .worktree,
            path: nil,
            branch: configuration.branch,
            baseBranch: configuration.baseBranch
        )
    }

    private func repositoryRoot(for projectPath: String) throws -> String {
        do {
            let output = try runGit(["-C", projectPath, "rev-parse", "--show-toplevel"])
            let root = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !root.isEmpty else { throw WorktreeManagerError.projectIsNotGitRepository(projectPath) }
            return URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
        } catch let error as WorktreeManagerError {
            switch error {
            case .gitFailed:
                throw WorktreeManagerError.projectIsNotGitRepository(projectPath)
            default:
                throw error
            }
        }
    }

    private func currentBranch(at path: String) throws -> String {
        let branch = try runGit(["-C", path, "branch", "--show-current"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? "HEAD" : branch
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

    private var resolvedManagedRoot: URL {
        managedRoot.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func registeredWorktreePaths(repository: String) -> Set<String> {
        guard let output = try? runGit(["-C", repository, "worktree", "list", "--porcelain"]) else {
            return []
        }
        return Set(output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let prefix = "worktree "
            guard line.hasPrefix(prefix) else { return nil }
            return URL(fileURLWithPath: String(line.dropFirst(prefix.count)), isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        })
    }

    private func isDescendant(_ candidate: URL, of parent: URL) -> Bool {
        let parentComponents = parent.pathComponents
        let candidateComponents = candidate.pathComponents
        return candidateComponents.count > parentComponents.count
            && candidateComponents.prefix(parentComponents.count).elementsEqual(parentComponents)
    }

    private func runGit(_ arguments: [String]) throws -> String {
        let result = runGitResult(arguments)
        guard result.status == 0 else {
            throw WorktreeManagerError.gitFailed(
                arguments: arguments,
                message: result.error.isEmpty ? result.output : result.error
            )
        }
        return result.output
    }

    private func runGitResult(_ arguments: [String]) -> GitCommandResult {
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
            return GitCommandResult(status: -1, output: "", error: error.localizedDescription)
        }
        defer { try? fileManager.removeItem(at: captureDirectory) }

        let outputHandle: FileHandle
        let errorHandle: FileHandle
        do {
            outputHandle = try FileHandle(forWritingTo: outputURL)
            errorHandle = try FileHandle(forWritingTo: errorURL)
        } catch {
            return GitCommandResult(status: -1, output: "", error: error.localizedDescription)
        }
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        process.executableURL = gitExecutableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return GitCommandResult(status: -1, output: "", error: error.localizedDescription)
        }
        try? outputHandle.synchronize()
        try? errorHandle.synchronize()
        let output = String(decoding: (try? Data(contentsOf: outputURL)) ?? Data(), as: UTF8.self)
        let error = String(decoding: (try? Data(contentsOf: errorURL)) ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return GitCommandResult(status: process.terminationStatus, output: output, error: error)
    }
}

private struct GitCommandResult {
    let status: Int32
    let output: String
    let error: String
}
