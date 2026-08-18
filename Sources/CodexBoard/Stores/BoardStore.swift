import AppKit
import Combine
import Foundation

typealias CodexTaskClientFactory = @MainActor (CodexHost) -> any CodexTaskClient

@MainActor
final class BoardStore: ObservableObject {
    private struct HostRefreshResult: Sendable {
        let hostID: String
        let projects: [ProjectRecord]
        let connectionState: CodexConnectionState
        let errorDescription: String?
    }

    @Published private(set) var projects: [ProjectRecord] = []
    @Published private(set) var tasks: [BoardTask] = []
    @Published private(set) var hosts: [CodexHost] = [.local]
    @Published private(set) var hostConnectionStates: [String: CodexConnectionState] = [
        CodexHost.localID: .disconnected
    ]
    @Published private(set) var sshHostSuggestions: [String] = []
    @Published var preferences = BoardPreferences()
    @Published var selectedProjectID: String? {
        didSet {
            guard selectedProjectID != oldValue,
                  let selectedTaskID,
                  tasks.first(where: { $0.id == selectedTaskID })?.projectID != selectedProjectID
            else { return }
            self.selectedTaskID = nil
        }
    }
    @Published var selectedTaskID: UUID?
    @Published private(set) var isRefreshingProjects = false
    @Published private(set) var accountReady = false
    @Published private(set) var statusMessage = "正在启动…"
    @Published private(set) var lastError: String?

    // Kept as the local client for source compatibility with existing tests and
    // integrations. Remote work is routed through the host-scoped client pool.
    let client: any CodexTaskClient
    private let persistence: BoardPersistence
    private let discovery: ProjectDiscoveryService
    private let sshDiscovery: SSHHostDiscoveryService
    private let clientFactory: CodexTaskClientFactory
    private var clients: [String: any CodexTaskClient]
    private var manualProjects: [ManualProjectReference] = []
    private var eventTasks: [String: Task<Void, Never>] = [:]
    private var saveTask: Task<Void, Never>?
    private var didStart = false
    private var shouldRefreshProjectsAgain = false
    private var hostConfigurationGeneration = 0

    init(
        client: any CodexTaskClient = CodexAppServerClient(),
        persistence: BoardPersistence = BoardPersistence(),
        discovery: ProjectDiscoveryService = ProjectDiscoveryService(),
        sshDiscovery: SSHHostDiscoveryService = SSHHostDiscoveryService(),
        clientFactory: CodexTaskClientFactory? = nil
    ) {
        self.client = client
        self.persistence = persistence
        self.discovery = discovery
        self.sshDiscovery = sshDiscovery
        self.clients = [CodexHost.localID: client]
        self.clientFactory = clientFactory ?? { host in
            switch host.kind {
            case .local:
                return client
            case .ssh:
                return CodexAppServerClient(
                    launchMode: .ssh(hostAlias: host.sshAlias ?? "")
                )
            }
        }
    }

    deinit {
        eventTasks.values.forEach { $0.cancel() }
        saveTask?.cancel()
    }

    var selectedProject: ProjectRecord? {
        selectedProjectID.flatMap { id in projects.first(where: { $0.id == id }) }
    }

    var selectedTask: BoardTask? {
        selectedTaskID.flatMap { id in tasks.first(where: { $0.id == id }) }
    }

    var visibleProjects: [ProjectRecord] {
        projects.filter {
            preferences.showMissingProjects || !isLocalHost($0.hostID) || $0.existsOnDisk
        }
    }

    var enabledHosts: [CodexHost] {
        hosts.filter(\.isEnabled)
    }

    var connectedHostCount: Int {
        enabledHosts.count { hostConnectionState(for: $0.id).isConnected }
    }

    var filteredTasks: [BoardTask] {
        guard let selectedProjectID else { return tasks }
        return tasks.filter { $0.projectID == selectedProjectID }
    }

    var activeExecutionCount: Int {
        tasks.count(where: { $0.stage == .executing })
    }

    var runningTasks: [BoardTask] {
        tasks
            .filter { $0.stage.isActive }
            .sorted { lhs, rhs in
                if lhs.stage != rhs.stage {
                    return lhs.stage == .executing
                }
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    var runningTaskCount: Int {
        tasks.count(where: { $0.stage.isActive })
    }

    func projectName(for task: BoardTask) -> String {
        projects.first(where: { $0.id == task.projectID })?.name
            ?? URL(fileURLWithPath: task.projectID).lastPathComponent
    }

    func host(for hostID: String) -> CodexHost? {
        hosts.first(where: { $0.id == hostID })
    }

    func hostName(for hostID: String) -> String {
        host(for: hostID)?.name ?? hostID
    }

    func isLocalHost(_ hostID: String) -> Bool {
        hostID == CodexHost.localID
    }

    func hostConnectionState(for hostID: String) -> CodexConnectionState {
        hostConnectionStates[hostID] ?? .disconnected
    }

    func isProjectRunnable(_ project: ProjectRecord) -> Bool {
        project.path != "/"
            && project.existsOnDisk
            && host(for: project.hostID)?.isEnabled == true
    }

    func focusTask(_ taskID: UUID) {
        guard let task = tasks.first(where: { $0.id == taskID }) else { return }
        selectedProjectID = task.projectID
        selectedTaskID = taskID
    }

    func tasks(in stage: TaskStage) -> [BoardTask] {
        filteredTasks
            .filter { $0.stage == stage }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        subscribeToEvents(hostID: CodexHost.localID, client: client)
        Task { @MainActor [weak self] in
            await self?.loadAndConnect()
        }
    }

    func refreshProjects() async {
        guard !isRefreshingProjects else {
            shouldRefreshProjectsAgain = true
            return
        }
        isRefreshingProjects = true
        let refreshGeneration = hostConfigurationGeneration
        statusMessage = "正在扫描 \(enabledHosts.count) 台 Codex 主机…"
        defer {
            isRefreshingProjects = false
            if shouldRefreshProjectsAgain {
                shouldRefreshProjectsAgain = false
                Task { @MainActor [weak self] in await self?.refreshProjects() }
            }
        }

        let hostSnapshot = hosts
        let manualProjectSnapshot = manualProjects
        for host in hostSnapshot {
            hostConnectionStates[host.id] = host.isEnabled ? .connecting : .disconnected
        }
        let operations = hostSnapshot.map { host in
            let manualPaths = manualProjectSnapshot
                .filter { $0.hostID == host.id }
                .map(\.path)
            return Task { @MainActor [weak self] in
                guard let self else {
                    return HostRefreshResult(
                        hostID: host.id,
                        projects: [],
                        connectionState: .disconnected,
                        errorDescription: nil
                    )
                }
                return await self.refreshHost(host, manualPaths: manualPaths)
            }
        }
        var results: [HostRefreshResult] = []
        results.reserveCapacity(operations.count)
        for operation in operations {
            results.append(await operation.value)
        }

        guard refreshGeneration == hostConfigurationGeneration else {
            shouldRefreshProjectsAgain = true
            return
        }
        var refreshedProjects: [ProjectRecord] = []
        var errors: [String] = []
        for result in results {
            guard let currentHost = host(for: result.hostID) else { continue }
            hostConnectionStates[result.hostID] = result.connectionState
            refreshedProjects.append(contentsOf: result.projects)
            if let errorDescription = result.errorDescription {
                errors.append("\(currentHost.name)：\(errorDescription)")
            }
        }
        projects = refreshedProjects.sorted(by: projectSortOrder)
        accountReady = connectedHostCount > 0
        selectInitialProjectIfNeeded()
        if errors.isEmpty {
            lastError = nil
            statusMessage = "已连接 \(connectedHostCount) 台主机，载入 \(projects.count) 个项目"
        } else {
            lastError = errors.joined(separator: "\n")
            statusMessage = "已连接 \(connectedHostCount)/\(enabledHosts.count) 台主机"
        }
    }

    func addManualProject(path: String, hostID: String = CodexHost.localID) {
        guard let host = host(for: hostID),
              let normalized = normalizeProjectPath(path, isRemote: host.kind == .ssh)
        else {
            lastError = "远程项目必须使用绝对路径。"
            return
        }
        let reference = ManualProjectReference(hostID: hostID, path: normalized)
        guard !manualProjects.contains(reference) else { return }
        manualProjects.append(reference)
        scheduleSave()
        Task { @MainActor [weak self] in await self?.refreshProjects() }
    }

    func removeManualProject(_ project: ProjectRecord) {
        guard project.isManual else { return }
        let targets = Set(project.manualPaths + [project.path])
        let isRemote = host(for: project.hostID)?.kind == .ssh
        manualProjects.removeAll { reference in
            guard reference.hostID == project.hostID,
                  let normalized = normalizeProjectPath(reference.path, isRemote: isRemote)
            else { return false }
            return targets.contains(normalized)
        }
        scheduleSave()
        Task { @MainActor [weak self] in await self?.refreshProjects() }
    }

    @discardableResult
    func addSSHHost(alias: String, name: String = "") -> Bool {
        let normalizedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try AppServerTransport.validateSSHHostAlias(normalizedAlias)
        } catch {
            lastError = error.localizedDescription
            return false
        }
        guard !hosts.contains(where: {
            $0.sshAlias?.localizedCaseInsensitiveCompare(normalizedAlias) == .orderedSame
        }) else {
            lastError = "SSH 主机 \(normalizedAlias) 已经存在。"
            return false
        }

        let hostID = "ssh:\(normalizedAlias.lowercased())"
        guard !hosts.contains(where: { $0.id == hostID }) else { return false }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = CodexHost(
            id: hostID,
            name: cleanName.isEmpty ? normalizedAlias : cleanName,
            kind: .ssh,
            sshAlias: normalizedAlias,
            isEnabled: true,
            maxConcurrentExecutions: 1
        )
        hosts.append(host)
        hostConfigurationGeneration += 1
        hostConnectionStates[host.id] = .disconnected
        lastError = nil
        scheduleSave()
        Task { @MainActor [weak self] in await self?.refreshProjects() }
        return true
    }

    @discardableResult
    func setHostEnabled(id hostID: String, enabled: Bool) -> Bool {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return false }
        if !enabled, tasks.contains(where: { $0.hostID == hostID && $0.stage.isActive }) {
            lastError = "主机 \(hosts[index].name) 仍有任务运行，不能停用。"
            return false
        }
        hosts[index].isEnabled = enabled
        hostConfigurationGeneration += 1
        if !enabled {
            clients[hostID]?.disconnect()
            hostConnectionStates[hostID] = .disconnected
        }
        scheduleSave()
        Task { @MainActor [weak self] in await self?.refreshProjects() }
        return true
    }

    func setHostConcurrency(id hostID: String, maximum: Int) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        hosts[index].maxConcurrentExecutions = maximum
        scheduleSave()
        scheduleExecutionQueue()
    }

    @discardableResult
    func removeHost(id hostID: String) -> Bool {
        guard hostID != CodexHost.localID,
              hosts.contains(where: { $0.id == hostID }),
              !tasks.contains(where: { $0.hostID == hostID }),
              !manualProjects.contains(where: { $0.hostID == hostID })
        else { return false }

        hosts.removeAll { $0.id == hostID }
        hostConfigurationGeneration += 1
        hostConnectionStates.removeValue(forKey: hostID)
        eventTasks.removeValue(forKey: hostID)?.cancel()
        clients[hostID]?.disconnect()
        clients.removeValue(forKey: hostID)
        projects.removeAll { $0.hostID == hostID }
        scheduleSave()
        return true
    }

    func testHost(id hostID: String) async {
        guard let host = host(for: hostID), host.isEnabled else { return }
        let generation = hostConfigurationGeneration
        hostConnectionStates[hostID] = .connecting
        let hostClient = clientForHost(host)
        do {
            try await hostClient.connect()
            guard try await hostClient.verifyAccount() else {
                throw CodexClientError.invalidResponse("\(host.name) 尚未登录 Codex")
            }
            _ = try await hostClient.listThreads(cursor: nil, archived: false)
            guard generation == hostConfigurationGeneration,
                  self.host(for: hostID)?.isEnabled == true
            else { return }
            hostConnectionStates[hostID] = .connected
            lastError = nil
        } catch {
            guard generation == hostConfigurationGeneration,
                  self.host(for: hostID)?.isEnabled == true
            else { return }
            hostConnectionStates[hostID] = .failed(error.localizedDescription)
            lastError = "\(host.name)：\(error.localizedDescription)"
        }
        accountReady = connectedHostCount > 0
    }

    func refreshSSHSuggestions() async {
        let sshDiscovery = sshDiscovery
        let discovered = await Task.detached(priority: .utility) {
            sshDiscovery.discoverHosts()
        }.value
        sshHostSuggestions = discovered.filter { alias in
            (try? AppServerTransport.validateSSHHostAlias(alias)) != nil
        }
    }

    @discardableResult
    func createTask(
        projectID: String,
        title: String,
        sourceKind: TaskSourceKind,
        sourceText: String,
        autoRun: Bool
    ) -> UUID? {
        let body = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty,
              let project = projects.first(where: { $0.id == projectID }),
              project.path != "/",
              project.existsOnDisk,
              host(for: project.hostID)?.isEnabled == true
        else { return nil }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let derivedTitle = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? sourceKind.title
        var task = BoardTask(
            projectID: projectID,
            hostID: project.hostID,
            title: cleanTitle.isEmpty ? String(derivedTitle.prefix(80)) : cleanTitle,
            sourceKind: sourceKind,
            sourceText: body,
            autoRun: autoRun
        )
        task.logs.append(TaskLogEntry(message: "任务已加入看板。"))
        tasks.append(task)
        let reference = ManualProjectReference(hostID: project.hostID, path: project.path)
        if !manualProjects.contains(reference) {
            // Persist the path alongside the task so it remains visible when a
            // remote host is temporarily offline on the next launch.
            manualProjects.append(reference)
        }
        selectedProjectID = projectID
        selectedTaskID = task.id
        scheduleSave()
        Task { @MainActor [weak self] in await self?.startPlanning(taskID: task.id) }
        return task.id
    }

    func startPlanning(taskID: UUID) async {
        guard let index = taskIndex(taskID), let project = project(forTaskAt: index) else { return }
        guard let host = host(for: tasks[index].hostID), host.isEnabled else {
            failTask(at: index, message: "任务主机已停用或不再存在。")
            return
        }
        guard project.path != "/" else {
            failTask(at: index, message: "拒绝把文件系统根目录作为任务工作区。")
            return
        }
        guard project.existsOnDisk else {
            failTask(at: index, message: "项目目录不存在：\(project.path)")
            return
        }
        guard !tasks[index].stage.isActive else { return }

        tasks[index].stage = .planning
        tasks[index].executionApproved = false
        tasks[index].planText = ""
        tasks[index].hasFinalPlan = false
        tasks[index].structuredPlan = []
        tasks[index].planningTurnID = nil
        tasks[index].executionTurnID = nil
        tasks[index].liveMessage = "正在连接 \(host.name) Codex…"
        tasks[index].lastError = nil
        tasks[index].updatedAt = Date()
        appendLog(at: index, "开始只读规划。")
        guard await saveImmediately() else {
            if let failureIndex = taskIndex(taskID) {
                failTask(
                    at: failureIndex,
                    message: "无法持久化任务状态；为避免产生不可恢复的远端工作，未启动规划。"
                )
            }
            return
        }

        let hostClient = clientForHost(host)
        do {
            try await hostClient.connect()
            hostConnectionStates[host.id] = .connected
            let startedThread: CodexStartedThread
            if let existingThread = tasks[index].threadID {
                startedThread = try await hostClient.resumeThread(
                    threadID: existingThread,
                    cwd: project.path
                )
            } else {
                startedThread = try await hostClient.startThread(
                    cwd: project.path,
                    model: preferences.modelOverride.nilIfEmpty
                )
                try? await hostClient.setThreadName(
                    threadID: startedThread.threadID,
                    name: "CodexBoard · \(tasks[index].title)"
                )
            }
            guard let currentIndex = taskIndex(taskID) else { return }
            tasks[currentIndex].threadID = startedThread.threadID
            tasks[currentIndex].sessionID = startedThread.sessionID
            tasks[currentIndex].model = startedThread.model
            tasks[currentIndex].liveMessage = "Codex 正在检查项目并制定方案…"
            guard await saveImmediately() else {
                failTask(
                    at: currentIndex,
                    message: "Codex thread 已创建，但无法持久化其标识；未启动规划 Turn。"
                )
                return
            }

            let prompt = TaskPromptBuilder.planningPrompt(for: tasks[currentIndex], projectPath: project.path)
            let turn = try await hostClient.startPlanningTurn(
                threadID: startedThread.threadID,
                cwd: project.path,
                prompt: prompt,
                model: startedThread.model,
                effort: preferences.planningEffort
            )
            guard let finalIndex = taskIndex(taskID) else { return }
            tasks[finalIndex].planningTurnID = turn.turnID
            appendLog(at: finalIndex, "规划会话已启动：\(shortID(turn.turnID))")
            guard await saveImmediately() else {
                try? await hostClient.interrupt(
                    threadID: startedThread.threadID,
                    turnID: turn.turnID
                )
                if let failureIndex = taskIndex(taskID) {
                    failTask(
                        at: failureIndex,
                        message: "规划 Turn 已启动但无法持久化其标识；已发送停止请求，请检查远端 thread。"
                    )
                }
                return
            }
        } catch {
            reflectTransportState(of: hostClient, for: host, fallbackError: error)
            if let failureIndex = taskIndex(taskID) {
                failTask(at: failureIndex, message: error.localizedDescription)
            }
        }
    }

    func confirmPlan(taskID: UUID) {
        guard let index = taskIndex(taskID),
              tasks[index].stage == .awaitingApproval,
              tasks[index].hasFinalPlan
        else { return }
        tasks[index].executionApproved = true
        tasks[index].updatedAt = Date()
        appendLog(at: index, "方案已确认，等待执行槽位。", level: .success)
        scheduleSave()
        scheduleExecutionQueue()
    }

    func revisePlan(taskID: UUID) {
        guard let index = taskIndex(taskID), !tasks[index].stage.isActive else { return }
        tasks[index].stage = .inbox
        tasks[index].executionApproved = false
        tasks[index].updatedAt = Date()
        appendLog(at: index, "方案退回，准备重新规划。", level: .warning)
        scheduleSave()
        Task { @MainActor [weak self] in await self?.startPlanning(taskID: taskID) }
    }

    func continueExecution(taskID: UUID) {
        Task { @MainActor [weak self] in
            await self?.reconcileAndContinueExecution(taskID: taskID)
        }
    }

    private func reconcileAndContinueExecution(taskID: UUID) async {
        guard let index = taskIndex(taskID),
              !tasks[index].stage.isActive,
              tasks[index].hasFinalPlan,
              !tasks[index].planText.isEmpty
        else { return }

        let taskSnapshot = tasks[index]
        guard let host = host(for: taskSnapshot.hostID), host.isEnabled else {
            failTask(at: index, message: "任务主机已停用或不再存在。")
            return
        }

        if let threadID = taskSnapshot.threadID {
            do {
                let hostClient = clientForHost(host)
                try await hostClient.connect()
                let detail = try await hostClient.readThread(
                    threadID: threadID,
                    includeTurns: true
                )
                guard let currentIndex = taskIndex(taskID) else { return }
                let knownTurnID = taskSnapshot.executionTurnID
                let candidateTurn = knownTurnID.flatMap { turnID in
                    detail.turns.first(where: { $0.id == turnID })
                } ?? detail.turns.last(where: { $0.id != taskSnapshot.planningTurnID })

                if let knownTurnID, candidateTurn?.id != knownTurnID {
                    failTask(
                        at: currentIndex,
                        message: "无法在远端 thread 中确认上次执行 Turn \(shortID(knownTurnID))；为避免重复副作用，未启动新 Turn。"
                    )
                    return
                }

                if let candidateTurn {
                    tasks[currentIndex].executionTurnID = candidateTurn.id
                    switch normalizedTurnStatus(candidateTurn.status) {
                    case "completed":
                        if let recoveredText = candidateTurn.items.reversed().compactMap({ item in
                            item.type == "agentMessage" ? item.text : nil
                        }).first, !recoveredText.isEmpty {
                            tasks[currentIndex].resultText = recoveredText
                        }
                        appendLog(
                            at: currentIndex,
                            "远端执行已完成；已通过 thread/read 对账，未重复启动 Turn。",
                            level: .success
                        )
                        completeTurn(
                            at: currentIndex,
                            turnID: candidateTurn.id,
                            status: "completed",
                            error: nil
                        )
                        return

                    case "inprogress", "running", "active", "pending", "queued":
                        tasks[currentIndex].stage = .executing
                        tasks[currentIndex].executionApproved = false
                        tasks[currentIndex].lastError = nil
                        tasks[currentIndex].liveMessage = "正在重新连接远端执行…"
                        tasks[currentIndex].updatedAt = Date()
                        scheduleSave()
                        do {
                            let resumed = try await hostClient.resumeThread(
                                threadID: threadID,
                                cwd: detail.summary.cwd
                            )
                            guard let resumedIndex = taskIndex(taskID) else { return }
                            tasks[resumedIndex].sessionID = resumed.sessionID
                            tasks[resumedIndex].model = resumed.model
                            tasks[resumedIndex].liveMessage = "已重新连接正在运行的远端 Turn"
                            appendLog(
                                at: resumedIndex,
                                "已通过 thread/read 确认远端 Turn 仍在运行，没有重复执行。",
                                level: .success
                            )
                            scheduleSave()
                        } catch {
                            if let failureIndex = taskIndex(taskID) {
                                failTask(
                                    at: failureIndex,
                                    message: "已确认远端 Turn 仍在运行，但重新订阅失败：\(error.localizedDescription)"
                                )
                            }
                        }
                        return

                    case "failed", "interrupted", "cancelled", "canceled":
                        appendLog(
                            at: currentIndex,
                            "远端上次 Turn 状态为 \(candidateTurn.status)；将从当前工作区启动新的执行 Turn。",
                            level: .warning
                        )

                    default:
                        failTask(
                            at: currentIndex,
                            message: "远端 Turn 状态无法安全判断：\(candidateTurn.status)。未启动新 Turn。"
                        )
                        return
                    }
                }
            } catch {
                if let failureIndex = taskIndex(taskID) {
                    failTask(
                        at: failureIndex,
                        message: "无法读取远端 thread 以确认上次执行状态：\(error.localizedDescription) 未启动新 Turn。"
                    )
                }
                return
            }
        }

        guard let finalIndex = taskIndex(taskID) else { return }
        enqueueContinuedExecution(at: finalIndex)
    }

    private func enqueueContinuedExecution(at index: Int) {
        tasks[index].executionTurnID = nil
        tasks[index].stage = .awaitingApproval
        tasks[index].executionApproved = true
        tasks[index].lastError = nil
        tasks[index].updatedAt = Date()
        appendLog(at: index, "已完成远端状态对账，从当前工作区继续执行。")
        scheduleSave()
        scheduleExecutionQueue()
    }

    private func normalizedTurnStatus(_ status: String) -> String {
        status.lowercased().filter(\.isLetter)
    }

    func cancel(taskID: UUID) async {
        guard let index = taskIndex(taskID),
              let threadID = tasks[index].threadID,
              let turnID = tasks[index].stage == .planning
                ? tasks[index].planningTurnID
                : tasks[index].executionTurnID
        else { return }
        guard let host = host(for: tasks[index].hostID) else { return }
        do {
            try await clientForHost(host).interrupt(threadID: threadID, turnID: turnID)
            appendLog(at: index, "已发送停止请求。", level: .warning)
        } catch {
            appendLog(at: index, "停止失败：\(error.localizedDescription)", level: .error)
        }
        scheduleSave()
    }

    func deleteTask(taskID: UUID) {
        tasks.removeAll { $0.id == taskID && !$0.stage.isActive }
        if selectedTaskID == taskID { selectedTaskID = nil }
        scheduleSave()
    }

    @discardableResult
    func moveTask(taskID: UUID, to stage: TaskStage) -> Bool {
        guard let index = taskIndex(taskID), !tasks[index].stage.isActive, stage.allowsManualDrop else { return false }
        if stage == .awaitingApproval
            && (!tasks[index].hasFinalPlan || tasks[index].planText.isEmpty) {
            return false
        }
        tasks[index].stage = stage
        tasks[index].executionApproved = false
        tasks[index].updatedAt = Date()
        appendLog(at: index, "手动移至“\(stage.title)”。")
        scheduleSave()
        return true
    }

    func updatePreferences(_ mutate: (inout BoardPreferences) -> Void) {
        mutate(&preferences)
        scheduleSave()
        scheduleExecutionQueue()
    }

    func revealProject(_ project: ProjectRecord) {
        guard isLocalHost(project.hostID), project.existsOnDisk else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
    }

    func openTaskInCodex(_ task: BoardTask) {
        guard isLocalHost(task.hostID),
              let threadID = task.threadID,
              let url = URL(string: "codex://thread/\(threadID)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func loadAndConnect() async {
        var persistedActiveTaskIDs: [UUID] = []
        do {
            let snapshot = try await persistence.load()
            tasks = snapshot.tasks
            persistedActiveTaskIDs = tasks.filter { $0.stage.isActive }.map(\.id)
            hosts = snapshot.hosts
            manualProjects = snapshot.manualProjects
            preferences = snapshot.preferences
            for host in hosts where hostConnectionStates[host.id] == nil {
                hostConnectionStates[host.id] = .disconnected
            }
            let configuredHostIDs = Set(hosts.map(\.id))
            hostConnectionStates = hostConnectionStates.filter {
                configuredHostIDs.contains($0.key)
            }
            for task in tasks where task.hostID == CodexHost.localID {
                let reference = ManualProjectReference(hostID: task.hostID, path: task.projectID)
                if !manualProjects.contains(reference) {
                    manualProjects.append(reference)
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
        await refreshSSHSuggestions()
        await refreshProjects()
        await reconcilePersistedActiveTasks(persistedActiveTaskIDs)
        scheduleExecutionQueue()
    }

    private func reconcilePersistedActiveTasks(_ taskIDs: [UUID]) async {
        for taskID in taskIDs {
            guard let index = taskIndex(taskID), tasks[index].stage.isActive else { continue }
            let taskSnapshot = tasks[index]
            let turnID = taskSnapshot.stage == .planning
                ? taskSnapshot.planningTurnID
                : taskSnapshot.executionTurnID
            guard let host = host(for: taskSnapshot.hostID), host.isEnabled,
                  let threadID = taskSnapshot.threadID,
                  let turnID
            else {
                failTask(
                    at: index,
                    message: "无法确认应用退出时的远端执行状态；任务已暂停，未启动新 Turn。"
                )
                continue
            }

            do {
                let hostClient = clientForHost(host)
                try await hostClient.connect()
                let detail = try await hostClient.readThread(
                    threadID: threadID,
                    includeTurns: true
                )
                guard let currentIndex = taskIndex(taskID),
                      let turn = detail.turns.first(where: { $0.id == turnID })
                else {
                    if let failureIndex = taskIndex(taskID) {
                        failTask(
                            at: failureIndex,
                            message: "thread/read 未返回上次 Turn \(shortID(turnID))；任务已暂停以避免重复副作用。"
                        )
                    }
                    continue
                }

                switch normalizedTurnStatus(turn.status) {
                case "completed":
                    if taskSnapshot.stage == .planning {
                        if let planText = turn.items.reversed().compactMap({ item in
                            item.type == "plan" ? item.text : nil
                        }).first, !planText.isEmpty {
                            tasks[currentIndex].planText = planText
                            tasks[currentIndex].hasFinalPlan = true
                        }
                    } else if let finalText = turn.items.reversed().compactMap({ item in
                        item.type == "agentMessage" ? item.text : nil
                    }).first, !finalText.isEmpty {
                        tasks[currentIndex].resultText = finalText
                    }
                    appendLog(
                        at: currentIndex,
                        "启动时已通过 thread/read 对账到上次 Turn 完成。",
                        level: .success
                    )
                    completeTurn(
                        at: currentIndex,
                        turnID: turn.id,
                        status: "completed",
                        error: nil
                    )

                case "inprogress", "running", "active", "pending", "queued":
                    let resumed = try await hostClient.resumeThread(
                        threadID: threadID,
                        cwd: detail.summary.cwd
                    )
                    guard let resumedIndex = taskIndex(taskID) else { continue }
                    tasks[resumedIndex].sessionID = resumed.sessionID
                    tasks[resumedIndex].model = resumed.model
                    tasks[resumedIndex].lastError = nil
                    tasks[resumedIndex].liveMessage = "已恢复对正在运行 Turn 的订阅"
                    appendLog(
                        at: resumedIndex,
                        "启动时确认上次 Turn 仍在运行，已重新订阅而未重复执行。",
                        level: .success
                    )
                    scheduleSave()

                case "failed", "interrupted", "cancelled", "canceled":
                    failTask(
                        at: currentIndex,
                        message: "应用退出时的 Turn 状态为 \(turn.status)；请检查工作区后再继续。"
                    )

                default:
                    failTask(
                        at: currentIndex,
                        message: "无法安全判断应用退出时的 Turn 状态：\(turn.status)。未启动新 Turn。"
                    )
                }
            } catch {
                if let failureIndex = taskIndex(taskID) {
                    failTask(
                        at: failureIndex,
                        message: "启动恢复对账失败：\(error.localizedDescription) 未启动新 Turn。"
                    )
                }
            }
        }
    }

    private func clientForHost(_ host: CodexHost) -> any CodexTaskClient {
        if let existing = clients[host.id] {
            if didStart { subscribeToEvents(hostID: host.id, client: existing) }
            return existing
        }
        let newClient = clientFactory(host)
        clients[host.id] = newClient
        if didStart { subscribeToEvents(hostID: host.id, client: newClient) }
        return newClient
    }

    private func reflectTransportState(
        of client: any CodexTaskClient,
        for host: CodexHost,
        fallbackError: Error
    ) {
        switch client.connectionState {
        case let .failed(message):
            hostConnectionStates[host.id] = .failed(message)
        case .disconnected:
            hostConnectionStates[host.id] = .failed(fallbackError.localizedDescription)
        case .connecting, .connected:
            // Model, path, sandbox and turn-level RPC errors belong to the task;
            // they do not imply that every project on this host is offline.
            break
        }
        accountReady = connectedHostCount > 0
    }

    private func subscribeToEvents(hostID: String, client: any CodexTaskClient) {
        guard eventTasks[hostID] == nil else { return }
        let events = client.events
        eventTasks[hostID] = Task { @MainActor [weak self] in
            for await event in events {
                guard !Task.isCancelled else { break }
                self?.handle(event, hostID: hostID)
            }
        }
    }

    private func refreshHost(
        _ host: CodexHost,
        manualPaths: [String]
    ) async -> HostRefreshResult {
        guard host.isEnabled else {
            let projects = await discovery.discover(
                threads: [],
                manualPaths: manualPaths,
                hostID: host.id,
                isRemote: host.kind == .ssh
            )
            return HostRefreshResult(
                hostID: host.id,
                projects: projects,
                connectionState: .disconnected,
                errorDescription: nil
            )
        }

        do {
            let hostClient = clientForHost(host)
            try await hostClient.connect()
            guard try await hostClient.verifyAccount() else {
                throw CodexClientError.invalidResponse("尚未登录 Codex")
            }
            let threads = try await listAllThreads(using: hostClient)
            let remotePathInfo: [String: CodexProjectPathInfo]
            if host.kind == .ssh {
                remotePathInfo = await inspectRemoteProjectPaths(
                    threadPaths: threads.map(\.cwd),
                    manualPaths: manualPaths,
                    using: hostClient
                )
            } else {
                remotePathInfo = [:]
            }
            let projects = await discovery.discover(
                threads: threads,
                manualPaths: manualPaths,
                hostID: host.id,
                isRemote: host.kind == .ssh,
                remotePathInfo: remotePathInfo
            )
            return HostRefreshResult(
                hostID: host.id,
                projects: projects,
                connectionState: .connected,
                errorDescription: nil
            )
        } catch {
            let message = error.localizedDescription
            let projects = await discovery.discover(
                threads: [],
                manualPaths: manualPaths,
                hostID: host.id,
                isRemote: host.kind == .ssh
            )
            return HostRefreshResult(
                hostID: host.id,
                projects: projects,
                connectionState: .failed(message),
                errorDescription: message
            )
        }
    }

    private func listAllThreads(using client: any CodexTaskClient) async throws -> [CodexThreadSummary] {
        var threads: [CodexThreadSummary] = []
        for archived in [false, true] {
            var cursor: String?
            repeat {
                let page = try await client.listThreads(cursor: cursor, archived: archived)
                threads.append(contentsOf: page.threads)
                cursor = page.nextCursor
            } while cursor != nil
        }
        return threads
    }

    private func inspectRemoteProjectPaths(
        threadPaths: [String],
        manualPaths: [String],
        using client: any CodexTaskClient
    ) async -> [String: CodexProjectPathInfo] {
        let normalizedPaths = Set((threadPaths + manualPaths).compactMap { rawPath -> String? in
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (trimmed as NSString).isAbsolutePath else { return nil }
            return (trimmed as NSString).standardizingPath
        })
        var information: [String: CodexProjectPathInfo] = [:]
        information.reserveCapacity(normalizedPaths.count)
        for path in normalizedPaths {
            guard path != "/" else {
                information[path] = CodexProjectPathInfo(
                    canonicalWorkingDirectory: path,
                    projectPath: path,
                    exists: false,
                    isGitRepository: false
                )
                continue
            }
            do {
                information[path] = try await client.inspectProjectPath(path)
            } catch {
                information[path] = CodexProjectPathInfo(
                    canonicalWorkingDirectory: path,
                    projectPath: path,
                    exists: false,
                    isGitRepository: false
                )
            }
        }
        return information
    }

    private func normalizeProjectPath(_ path: String, isRemote: Bool) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isRemote {
            guard (trimmed as NSString).isAbsolutePath else { return nil }
            let standardized = (trimmed as NSString).standardizingPath
            guard standardized != "/" else { return nil }
            return standardized
        }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private func projectSortOrder(_ lhs: ProjectRecord, _ rhs: ProjectRecord) -> Bool {
        switch (lhs.latestActivityAt, rhs.latestActivityAt) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            if lhs.hostID != rhs.hostID { return lhs.hostID < rhs.hostID }
            return lhs.path < rhs.path
        }
    }

    private func scheduleExecutionQueue() {
        let available = max(0, preferences.maxConcurrentExecutions - activeExecutionCount)
        guard available > 0 else { return }
        var activeByHost = Dictionary(grouping: tasks.filter { $0.stage == .executing }, by: \.hostID)
            .mapValues(\.count)
        var occupiedProjects = Set(
            tasks.lazy
                .filter {
                    $0.stage == .executing
                        || ($0.stage == .needsAttention && $0.hasFinalPlan && $0.threadID != nil)
                }
                .map(\.projectID)
        )
        var queued: [Int] = []
        let candidates = tasks.indices
            .filter {
                tasks[$0].stage == .awaitingApproval
                    && tasks[$0].executionApproved
                    && tasks[$0].hasFinalPlan
                    && !tasks[$0].planText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { tasks[$0].updatedAt < tasks[$1].updatedAt }
        for index in candidates {
            guard let candidateHost = host(for: tasks[index].hostID),
                  candidateHost.isEnabled,
                  activeByHost[candidateHost.id, default: 0] < candidateHost.maxConcurrentExecutions
            else { continue }
            guard !occupiedProjects.contains(tasks[index].projectID) else { continue }
            occupiedProjects.insert(tasks[index].projectID)
            activeByHost[candidateHost.id, default: 0] += 1
            queued.append(index)
            if queued.count == available { break }
        }
        for index in queued {
            let taskID = tasks[index].id
            tasks[index].stage = .executing
            tasks[index].liveMessage = "正在准备执行…"
            tasks[index].updatedAt = Date()
            appendLog(at: index, "开始执行已确认方案。")
            Task { @MainActor [weak self] in await self?.performExecution(taskID: taskID) }
        }
        scheduleSave()
    }

    private func performExecution(taskID: UUID) async {
        guard let index = taskIndex(taskID), let project = project(forTaskAt: index), let threadID = tasks[index].threadID else {
            if let index = taskIndex(taskID) { failTask(at: index, message: "缺少可恢复的 Codex thread。") }
            return
        }
        guard let host = host(for: tasks[index].hostID), host.isEnabled else {
            failTask(at: index, message: "任务主机已停用或不再存在。")
            scheduleExecutionQueue()
            return
        }
        guard await saveImmediately() else {
            if let failureIndex = taskIndex(taskID) {
                failTask(
                    at: failureIndex,
                    message: "无法持久化已排队的执行状态；未启动执行 Turn。"
                )
                scheduleExecutionQueue()
            }
            return
        }
        let hostClient = clientForHost(host)
        do {
            try await hostClient.connect()
            hostConnectionStates[host.id] = .connected
            let resumed = try await hostClient.resumeThread(threadID: threadID, cwd: project.path)
            guard let currentIndex = taskIndex(taskID) else { return }
            tasks[currentIndex].sessionID = resumed.sessionID
            tasks[currentIndex].model = resumed.model
            tasks[currentIndex].resultText = ""
            tasks[currentIndex].liveMessage = "Codex 正在实施方案…"
            guard await saveImmediately() else {
                failTask(
                    at: currentIndex,
                    message: "无法持久化恢复后的 session；未启动执行 Turn。"
                )
                scheduleExecutionQueue()
                return
            }
            let prompt = TaskPromptBuilder.executionPrompt(for: tasks[currentIndex], projectPath: project.path)
            let turn = try await hostClient.startExecutionTurn(
                threadID: threadID,
                cwd: project.path,
                prompt: prompt,
                model: resumed.model,
                effort: preferences.executionEffort,
                allowNetwork: preferences.allowNetworkAccess
            )
            guard let finalIndex = taskIndex(taskID) else { return }
            tasks[finalIndex].executionTurnID = turn.turnID
            appendLog(at: finalIndex, "执行会话已启动：\(shortID(turn.turnID))")
            guard await saveImmediately() else {
                try? await hostClient.interrupt(threadID: threadID, turnID: turn.turnID)
                if let failureIndex = taskIndex(taskID) {
                    failTask(
                        at: failureIndex,
                        message: "执行 Turn 已启动但无法持久化其标识；已发送停止请求，请检查工作区和远端 thread。"
                    )
                    scheduleExecutionQueue()
                }
                return
            }
        } catch {
            reflectTransportState(of: hostClient, for: host, fallbackError: error)
            if let failureIndex = taskIndex(taskID) {
                failTask(at: failureIndex, message: error.localizedDescription)
                scheduleExecutionQueue()
            }
        }
    }

    private func handle(_ event: CodexEvent, hostID: String) {
        switch event {
        case let .agentDelta(threadID, turnID, delta):
            guard let index = taskIndex(threadID: threadID, turnID: turnID, hostID: hostID) else { return }
            if tasks[index].stage == .planning {
                tasks[index].planText += delta
            } else if tasks[index].stage == .executing {
                tasks[index].resultText += delta
            }
            scheduleSave()
        case let .agentFinal(threadID, turnID, text):
            guard let index = taskIndex(threadID: threadID, turnID: turnID, hostID: hostID) else { return }
            if tasks[index].stage == .planning, tasks[index].planText.isEmpty {
                tasks[index].planText = text
            } else if tasks[index].stage == .executing {
                tasks[index].resultText = text
            }
            scheduleSave()
        case let .planFinal(threadID, turnID, text):
            guard let index = taskIndex(threadID: threadID, turnID: turnID, hostID: hostID) else { return }
            tasks[index].planText = text
            tasks[index].hasFinalPlan = true
            scheduleSave()
        case let .planUpdated(threadID, turnID, explanation, steps):
            guard let index = taskIndex(threadID: threadID, turnID: turnID, hostID: hostID) else { return }
            tasks[index].structuredPlan = steps
            if let explanation, !explanation.isEmpty { tasks[index].liveMessage = explanation }
            scheduleSave()
        case let .activity(threadID, turnID, message):
            guard let index = taskIndex(threadID: threadID, turnID: turnID, hostID: hostID) else { return }
            tasks[index].liveMessage = message
        case let .warning(threadID, turnID, message):
            guard let threadID,
                  let index = taskIndex(threadID: threadID, turnID: turnID, hostID: hostID) else {
                lastError = "\(hostName(for: hostID))：\(message)"
                return
            }
            appendLog(at: index, message, level: .warning)
            tasks[index].lastError = message
            scheduleSave()
        case let .turnCompleted(threadID, turnID, status, error):
            guard let index = taskIndex(threadID: threadID, turnID: turnID, hostID: hostID) else { return }
            completeTurn(at: index, turnID: turnID, status: status, error: error)
        case .threadStatus:
            break
        case let .connectionLost(message):
            hostConnectionStates[hostID] = .failed(message)
            accountReady = connectedHostCount > 0
            for index in tasks.indices
                where tasks[index].hostID == hostID && tasks[index].stage.isActive {
                failTask(
                    at: index,
                    message: "\(hostName(for: hostID)) 的 Codex 连接已断开：\(message) 请检查工作区后再继续。"
                )
            }
            scheduleExecutionQueue()
        }
    }

    private func completeTurn(at index: Int, turnID: String, status: String, error: String?) {
        let isPlanning = tasks[index].planningTurnID == turnID || tasks[index].stage == .planning
        guard status == "completed" else {
            let reason = error ?? (status == "interrupted" ? "任务已停止。" : "Codex turn 状态：\(status)")
            failTask(at: index, message: reason)
            scheduleExecutionQueue()
            return
        }

        if isPlanning {
            if tasks[index].planText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !tasks[index].structuredPlan.isEmpty {
                tasks[index].planText = tasks[index].structuredPlan.enumerated()
                    .map { "\($0.offset + 1). \($0.element.step)" }
                    .joined(separator: "\n")
            }
            guard tasks[index].hasFinalPlan,
                  !tasks[index].planText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                failTask(at: index, message: "规划轮已结束，但没有收到可确认的最终方案。")
                return
            }
            tasks[index].stage = .awaitingApproval
            tasks[index].executionApproved = tasks[index].autoRun
            tasks[index].liveMessage = tasks[index].autoRun ? "方案完成，已进入自动执行队列" : "方案完成，等待确认"
            appendLog(at: index, tasks[index].autoRun ? "方案完成；全自动模式已跳过确认。" : "方案已生成，等待确认。", level: .success)
            tasks[index].updatedAt = Date()
            scheduleSave()
            scheduleExecutionQueue()
        } else {
            tasks[index].stage = .completed
            tasks[index].executionApproved = false
            tasks[index].liveMessage = "已完成"
            tasks[index].lastError = nil
            tasks[index].updatedAt = Date()
            appendLog(at: index, "Codex 已完成实施与验证。", level: .success)
            scheduleSave()
            scheduleExecutionQueue()
            Task { @MainActor [weak self] in await self?.refreshProjects() }
        }
    }

    private func failTask(at index: Int, message: String) {
        tasks[index].stage = .needsAttention
        tasks[index].executionApproved = false
        tasks[index].lastError = message
        tasks[index].liveMessage = "需要处理"
        tasks[index].updatedAt = Date()
        appendLog(at: index, message, level: .error)
        scheduleSave()
    }

    private func appendLog(at index: Int, _ message: String, level: TaskLogEntry.Level = .info) {
        tasks[index].logs.append(TaskLogEntry(level: level, message: message))
        if tasks[index].logs.count > 200 {
            tasks[index].logs.removeFirst(tasks[index].logs.count - 200)
        }
    }

    private func taskIndex(_ id: UUID) -> Int? {
        tasks.firstIndex(where: { $0.id == id })
    }

    private func taskIndex(threadID: String, turnID: String?, hostID: String) -> Int? {
        tasks.firstIndex { task in
            guard task.hostID == hostID, task.threadID == threadID else { return false }
            guard let turnID else { return true }
            return task.planningTurnID == turnID || task.executionTurnID == turnID
                || (task.stage == .planning && task.planningTurnID == nil)
                || (task.stage == .executing && task.executionTurnID == nil)
        }
    }

    private func project(forTaskAt index: Int) -> ProjectRecord? {
        projects.first(where: { $0.id == tasks[index].projectID })
    }

    private func selectInitialProjectIfNeeded() {
        if let selectedProjectID, projects.contains(where: { $0.id == selectedProjectID }) { return }
        selectedProjectID = projects.first(where: { project in
            tasks.contains(where: { $0.projectID == project.id })
        })?.id ?? visibleProjects.first?.id
    }

    private func scheduleSave() {
        guard didStart else { return }
        saveTask?.cancel()
        let snapshot = currentSnapshot()
        let persistence = persistence
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                try await persistence.save(snapshot)
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    @discardableResult
    private func saveImmediately() async -> Bool {
        guard didStart else { return false }
        saveTask?.cancel()
        saveTask = nil
        do {
            try await persistence.save(currentSnapshot())
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func currentSnapshot() -> BoardSnapshot {
        BoardSnapshot(
            version: BoardSnapshot.currentVersion,
            tasks: tasks,
            hosts: hosts,
            manualProjects: manualProjects,
            preferences: preferences
        )
    }

    private func shortID(_ value: String) -> String {
        String(value.prefix(8))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension CodexConnectionState {
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
