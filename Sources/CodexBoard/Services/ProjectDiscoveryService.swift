import Darwin
import Foundation

struct ProjectDiscoveryService: Sendable {
    private let gitExecutableURL: URL
    private let gitProbeTimeout: TimeInterval

    init(
        gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        gitProbeTimeout: TimeInterval = 1.5
    ) {
        self.gitExecutableURL = gitExecutableURL
        self.gitProbeTimeout = max(gitProbeTimeout, 0.01)
    }

    func discover(
        threads: [CodexThreadSummary],
        manualPaths: [String],
        hostID: String = CodexHost.localID,
        isRemote: Bool = false,
        remotePathInfo: [String: CodexProjectPathInfo] = [:]
    ) async -> [ProjectRecord] {
        await Task.detached(priority: .utility) {
            Self.discoverSynchronously(
                threads: threads,
                manualPaths: manualPaths,
                hostID: hostID,
                isRemote: isRemote,
                remotePathInfo: remotePathInfo,
                gitExecutableURL: gitExecutableURL,
                gitProbeTimeout: gitProbeTimeout
            )
        }.value
    }

    private struct PathProbe {
        let canonicalWorkingDirectory: String
        let projectPath: String
        let existsOnDisk: Bool
        let isGitRepository: Bool
    }

    private struct ProjectAccumulator {
        let hostID: String
        let path: String
        var observedWorkingDirectoryDates: [String: Date] = [:]
        var manualPaths: Set<String> = []
        var latestActivityAt: Date?
        var threadCount = 0
        var activeThreadCount = 0
        var isGitRepository = false
        var existsOnDisk = false
        var isManual = false

        mutating func add(thread: CodexThreadSummary, probe: PathProbe) {
            threadCount += 1
            if thread.isActive {
                activeThreadCount += 1
            }
            if latestActivityAt.map({ thread.updatedAt > $0 }) ?? true {
                latestActivityAt = thread.updatedAt
            }
            if let observedAt = observedWorkingDirectoryDates[probe.canonicalWorkingDirectory] {
                if thread.updatedAt > observedAt {
                    observedWorkingDirectoryDates[probe.canonicalWorkingDirectory] = thread.updatedAt
                }
            } else {
                observedWorkingDirectoryDates[probe.canonicalWorkingDirectory] = thread.updatedAt
            }
            mergeMetadata(from: probe)
        }

        mutating func addManualPath(_ inputPath: String, probe: PathProbe) {
            isManual = true
            manualPaths.insert(inputPath)
            mergeMetadata(from: probe)
        }

        private mutating func mergeMetadata(from probe: PathProbe) {
            existsOnDisk = existsOnDisk || probe.existsOnDisk
            isGitRepository = isGitRepository || probe.isGitRepository
        }

        func record() -> ProjectRecord {
            let observedWorkingDirectories = observedWorkingDirectoryDates
                .sorted { lhs, rhs in
                    if lhs.value != rhs.value {
                        return lhs.value > rhs.value
                    }
                    return lhs.key < rhs.key
                }
                .map(\.key)

            let url = URL(fileURLWithPath: path, isDirectory: true)
            let lastPathComponent = url.lastPathComponent
            return ProjectRecord(
                hostID: hostID,
                name: lastPathComponent.isEmpty ? path : lastPathComponent,
                path: path,
                observedWorkingDirectories: observedWorkingDirectories,
                manualPaths: manualPaths.sorted(),
                latestActivityAt: latestActivityAt,
                threadCount: threadCount,
                activeThreadCount: activeThreadCount,
                isGitRepository: isGitRepository,
                existsOnDisk: existsOnDisk,
                isManual: isManual
            )
        }
    }

    private static func discoverSynchronously(
        threads: [CodexThreadSummary],
        manualPaths: [String],
        hostID: String,
        isRemote: Bool,
        remotePathInfo: [String: CodexProjectPathInfo],
        gitExecutableURL: URL,
        gitProbeTimeout: TimeInterval
    ) -> [ProjectRecord] {
        let normalizedThreadInputs = threads.compactMap { thread -> (CodexThreadSummary, String)? in
            guard let path = normalizedPath(thread.cwd, isRemote: isRemote) else { return nil }
            return (thread, path)
        }
        let normalizedManualInputs = manualPaths.compactMap {
            normalizedPath($0, isRemote: isRemote)
        }
        let inputPaths = Set(
            normalizedThreadInputs.map(\.1) + normalizedManualInputs
        )

        // Deliberately probe only the paths supplied by app-server or the user. Git
        // performs its normal parent lookup for that cwd; this service never walks
        // the filesystem or reads Codex rollout/session JSONL files.
        var probes: [String: PathProbe] = [:]
        probes.reserveCapacity(inputPaths.count)
        for path in inputPaths {
            if isRemote {
                // A remote path must never be checked with the controller Mac's
                // FileManager or Git. Only path information obtained through
                // that host's app-server can mark it usable or collapse it to a
                // canonical Git/worktree root; offline paths stay visible but
                // unavailable.
                let info = remotePathInfo[path]
                probes[path] = PathProbe(
                    canonicalWorkingDirectory: info?.canonicalWorkingDirectory ?? path,
                    projectPath: info?.projectPath ?? path,
                    existsOnDisk: info?.exists ?? false,
                    isGitRepository: info?.isGitRepository ?? false
                )
            } else {
                probes[path] = probe(
                    path: path,
                    gitExecutableURL: gitExecutableURL,
                    gitProbeTimeout: gitProbeTimeout
                )
            }
        }

        var projects: [String: ProjectAccumulator] = [:]
        for (thread, inputPath) in normalizedThreadInputs {
            guard let probe = probes[inputPath] else { continue }
            var accumulator = projects[probe.projectPath]
                ?? ProjectAccumulator(hostID: hostID, path: probe.projectPath)
            accumulator.add(thread: thread, probe: probe)
            projects[probe.projectPath] = accumulator
        }

        for inputPath in normalizedManualInputs {
            guard let probe = probes[inputPath] else { continue }
            var accumulator = projects[probe.projectPath]
                ?? ProjectAccumulator(hostID: hostID, path: probe.projectPath)
            accumulator.addManualPath(inputPath, probe: probe)
            projects[probe.projectPath] = accumulator
        }

        return projects.values
            .map { $0.record() }
            .sorted(by: projectSortOrder)
    }

    private static func normalizedPath(_ rawPath: String, isRemote: Bool) -> String? {
        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }

        if isRemote {
            guard (trimmedPath as NSString).isAbsolutePath else { return nil }
            return (trimmedPath as NSString).standardizingPath
        }

        let expandedPath = (trimmedPath as NSString).expandingTildeInPath
        let absoluteURL: URL
        if (expandedPath as NSString).isAbsolutePath {
            absoluteURL = URL(fileURLWithPath: expandedPath, isDirectory: true)
        } else {
            absoluteURL = URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            ).appendingPathComponent(expandedPath, isDirectory: true)
        }

        return absoluteURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private static func probe(
        path: String,
        gitExecutableURL: URL,
        gitProbeTimeout: TimeInterval
    ) -> PathProbe {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let isUsableDirectory = fileManager.fileExists(
            atPath: path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue

        // Most historical Codex working directories are plain folders. Looking
        // for a nearby .git marker first avoids launching Git for every record
        // and, importantly, avoids an unbounded getcwd() on stale File Provider
        // paths. The subprocess still validates real repositories/worktrees.
        guard isUsableDirectory,
              hasGitMarker(inOrAbove: path),
              let gitRoot = gitTopLevel(
                for: path,
                executableURL: gitExecutableURL,
                timeout: gitProbeTimeout
              ),
              isSameOrDescendant(path, of: gitRoot)
        else {
            return PathProbe(
                canonicalWorkingDirectory: path,
                projectPath: path,
                existsOnDisk: isUsableDirectory,
                isGitRepository: false
            )
        }

        return PathProbe(
            canonicalWorkingDirectory: path,
            projectPath: gitRoot,
            existsOnDisk: true,
            isGitRepository: true
        )
    }

    private static func hasGitMarker(inOrAbove path: String) -> Bool {
        var candidate = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        while true {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent(".git").path
            ) {
                return true
            }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            guard parent.path != candidate.path else { return false }
            candidate = parent
        }
    }

    private static func gitTopLevel(
        for workingDirectory: String,
        executableURL: URL,
        timeout: TimeInterval
    ) -> String? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "-C",
            workingDirectory,
            "rev-parse",
            "--show-toplevel"
        ]
        var environment = ProcessInfo.processInfo.environment
        for key in [
            "GIT_DIR",
            "GIT_WORK_TREE",
            "GIT_INDEX_FILE",
            "GIT_COMMON_DIR",
            "GIT_OBJECT_DIRECTORY",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES",
            "GIT_CEILING_DIRECTORIES"
        ] {
            environment.removeValue(forKey: key)
        }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment

        let standardOutput = Pipe()
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard !process.isRunning else {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.15)
            while process.isRunning, Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            return nil
        }

        guard process.terminationReason == .exit,
              process.terminationStatus == 0
        else { return nil }

        let data = standardOutput.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty,
              (output as NSString).isAbsolutePath
        else { return nil }

        let canonicalRoot = URL(fileURLWithPath: output, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: canonicalRoot,
            isDirectory: &isDirectory
        ), isDirectory.boolValue
        else { return nil }

        return canonicalRoot
    }

    private static func isSameOrDescendant(_ path: String, of ancestor: String) -> Bool {
        let pathComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let ancestorComponents = URL(fileURLWithPath: ancestor).standardizedFileURL.pathComponents
        guard ancestorComponents.count <= pathComponents.count else { return false }
        return pathComponents.prefix(ancestorComponents.count).elementsEqual(ancestorComponents)
    }

    private static func projectSortOrder(_ lhs: ProjectRecord, _ rhs: ProjectRecord) -> Bool {
        switch (lhs.latestActivityAt, rhs.latestActivityAt) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.path < rhs.path
        }
    }
}
