import AppKit
import Foundation
import Observation

enum BoardStoreError: LocalizedError {
    case invalidProject
    case emptyTask
    case worktreeRequiresGit
    case invalidDependencies
    case remoteAttachmentsUnsupported

    var errorDescription: String? {
        switch self {
        case .invalidProject: "所选项目不存在或已不可用。"
        case .emptyTask: "请输入任务内容或至少添加一个附件。"
        case .worktreeRequiresGit: "独立 Worktree 只能用于 Git 项目。"
        case .invalidDependencies: "前置任务必须存在于同一个项目中。"
        case .remoteAttachmentsUnsupported:
            "远程任务不能直接使用这台 Mac 上的附件；请先把文件上传到远程项目，再在任务描述中填写远程路径。"
        }
    }
}

typealias CodexTaskClientFactory = @MainActor (CodexHost) -> any CodexTaskClient
typealias WorktreeManagerFactory = @MainActor (CodexHost, any CodexTaskClient) -> any WorktreeManaging

private enum BoardStoreOAuthError: LocalizedError {
    case cannotOpenBrowser

    var errorDescription: String? { "无法打开 OAuth 授权页面。" }
}

private struct PendingStreamUpdate {
    var planDelta = ""
    var resultDelta = ""
    var liveMessage: String?
    var turnDiffID: String?
    var turnDiff: String?

    var changesPersistedContent: Bool {
        !planDelta.isEmpty || !resultDelta.isEmpty || turnDiffID != nil
    }
}

private struct InteractionAttentionKey: Hashable {
    let hostID: String
    let taskID: UUID
    let requestID: CodexRequestID
}

private struct HostRequestKey: Hashable {
    let hostID: String
    let requestID: CodexRequestID
}

private struct HostServerKey: Hashable {
    let hostID: String
    let serverName: String
}

private enum DrainReconciliationAction {
    case stop
    case retry(after: Duration)
}

private struct ExecutionSchedulingDemand {
    let taskIndex: Int
    let isReady: Bool
    let orderDate: Date
}

private struct WorktreeCapabilityTaskSnapshot {
    let id: UUID
    let projectID: String
    let hostID: String
    let stage: TaskStage
    let workspace: TaskWorkspaceConfiguration
    let executionRunID: UUID

    init?(task: BoardTask, executionRunID: UUID) {
        guard task.runs.contains(where: {
            $0.id == executionRunID && $0.phase == .execution && $0.outcome.isActive
        }) else { return nil }
        id = task.id
        projectID = task.projectID
        hostID = task.hostID
        stage = task.stage
        workspace = task.workspace
        self.executionRunID = executionRunID
    }

    func matches(_ task: BoardTask) -> Bool {
        task.id == id
            && task.projectID == projectID
            && task.hostID == hostID
            && task.stage == stage
            && task.workspace == workspace
            && task.runs.contains(where: {
                $0.id == executionRunID && $0.phase == .execution && $0.outcome.isActive
            })
    }
}

@MainActor
@Observable
final class BoardStore {
    private struct HostRefreshResult: Sendable {
        let hostID: String
        let projects: [ProjectRecord]
        let connectionState: CodexConnectionState
        let errorDescription: String?
    }

    private(set) var projects: [ProjectRecord] = []
    private(set) var tasks: [BoardTask] = [] {
        didSet { synchronizeTaskProjections() }
    }
    private(set) var taskCards: [BoardTaskCard] = []
    private(set) var selectedTask: BoardTask?
    private(set) var hosts: [CodexHost] = [.local]
    private(set) var hostConnectionStates: [String: CodexConnectionState] = [
        CodexHost.localID: .disconnected
    ]
    private(set) var sshHostSuggestions: [String] = []
    var preferences = BoardPreferences()
    var selectedProjectID: String? {
        didSet {
            guard selectedProjectID != oldValue else { return }
            capabilityRefreshTask?.cancel()
            modelRefreshGeneration &+= 1
            capabilityRefreshGeneration &+= 1
            modelCatalogHostID = nil
            modelCatalogProjectID = nil
            capabilityProjectID = nil
            availableModels = []
            availableSkills = []
            availableApps = []
            isLoadingModels = false
            isLoadingCapabilities = false
            modelCatalogError = nil
            capabilityCatalogError = nil
            if let selectedTaskID,
               tasks.first(where: { $0.id == selectedTaskID })?.projectID != selectedProjectID {
                self.selectedTaskID = nil
            }
            if let selectedProjectID {
                scheduleCapabilityRefresh(projectID: selectedProjectID, forceRefresh: false)
            }
        }
    }
    var selectedTaskID: UUID? {
        didSet {
            guard selectedTaskID != oldValue else { return }
            synchronizeSelectedTask()
        }
    }
    private(set) var isRefreshingProjects = false
    private(set) var accountReady = false
    private(set) var statusMessage = "正在启动…"
    private(set) var lastError: String?
    private(set) var availableModels: [CodexModel] = []
    private(set) var isLoadingModels = false
    private(set) var modelCatalogError: String?
    private(set) var availableSkills: [CodexSkillMetadata] = []
    private(set) var availableApps: [CodexApp] = []
    private(set) var isLoadingCapabilities = false
    private(set) var capabilityCatalogError: String?
    private(set) var pendingInteractionsByTaskID: [UUID: [CodexInteractionRequest]] = [:]
    private(set) var respondingRequestIDs = Set<CodexRequestID>()
    private(set) var attentionNotices: [TaskAttentionNotice] = []
    private(set) var taskFocusRequest: TaskFocusRequest?
    private(set) var mcpServers: [CodexMCPServerStatus] = []
    private(set) var isLoadingMCPServers = false
    private(set) var mcpServerError: String?
    private(set) var oauthServersInProgress = Set<String>()
    private(set) var worktreeCapabilityAvailabilityByProjectID: [String: WorktreeCapabilityAvailability] = [:]
    private(set) var worktreeCapabilityProbingProjectIDs = Set<String>()

    @ObservationIgnored
    // Kept as the local client for source compatibility with existing tests and
    // integrations. Remote work is routed through the host-scoped client pool.
    let client: any CodexTaskClient
    @ObservationIgnored
    private let persistence: any BoardPersisting
    @ObservationIgnored
    private let discovery: ProjectDiscoveryService
    @ObservationIgnored
    private let attachmentStorage: AttachmentStorage
    @ObservationIgnored
    private let worktreeManager: any WorktreeManaging
    @ObservationIgnored
    private let worktreeManagerFactory: WorktreeManagerFactory
    @ObservationIgnored
    private var worktreeManagers: [String: any WorktreeManaging]
    @ObservationIgnored
    private var worktreeCapabilityProbeGenerationByProjectID: [String: UInt64] = [:]
    @ObservationIgnored
    private let externalURLOpener: (URL) -> Bool
    @ObservationIgnored
    private let sshDiscovery: SSHHostDiscoveryService
    @ObservationIgnored
    private let clientFactory: CodexTaskClientFactory
    @ObservationIgnored
    private var clients: [String: any CodexTaskClient]
    @ObservationIgnored
    private var manualProjects: [ManualProjectReference] = []
    @ObservationIgnored
    private var hiddenProjectPaths = Set<String>()
    @ObservationIgnored
    private var eventTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored
    private var saveTask: Task<Void, Never>?
    @ObservationIgnored
    private var capabilityRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var capabilityRefreshGeneration = 0
    @ObservationIgnored
    private var capabilityProjectID: String?
    @ObservationIgnored
    private var modelRefreshGeneration = 0
    @ObservationIgnored
    private var modelCatalogHostID: String?
    @ObservationIgnored
    private var modelCatalogProjectID: String?
    @ObservationIgnored
    private var mcpRefreshGeneration = 0
    @ObservationIgnored
    private var pendingAttachmentDeletions: [BoardTask] = []
    @ObservationIgnored
    private var pendingStreamUpdates: [UUID: PendingStreamUpdate] = [:]
    @ObservationIgnored
    private var streamFlushTask: Task<Void, Never>?
    @ObservationIgnored
    private var saveRevision = 0
    @ObservationIgnored
    private var savedRevision = 0
    @ObservationIgnored
    private var isSaving = false
    @ObservationIgnored
    private var saveImmediatelyAfterCurrentWrite = false
    @ObservationIgnored
    private var didStart = false
    @ObservationIgnored
    private var pendingPlanningTaskIDs = Set<UUID>()
    @ObservationIgnored
    private var planningStartupQueue: [UUID] = []
    @ObservationIgnored
    private var planningStartupWorker: Task<Void, Never>?
    @ObservationIgnored
    private var planningStartupWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    @ObservationIgnored
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored
    private var drainTasksByRunID: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored
    private let drainCoordinator = MultiAgentDrainCoordinator()
    @ObservationIgnored
    private let drainStabilityDelay: Duration
    @ObservationIgnored
    private var cancellationIntentTaskIDs = Set<UUID>()
    @ObservationIgnored
    private var cancellationRequestInFlightTaskIDs = Set<UUID>()
    @ObservationIgnored
    private var worktreeCleanupInFlightTaskIDs = Set<UUID>()
    @ObservationIgnored
    private var interactionAttentionIDs: [InteractionAttentionKey: UUID] = [:]
    @ObservationIgnored
    private var respondingRequests = Set<HostRequestKey>()
    @ObservationIgnored
    private var oauthRequestsInProgress = Set<HostServerKey>()
    @ObservationIgnored
    private var durableAttentionIDs: [UUID: UUID] = [:]
    @ObservationIgnored
    private var shouldRefreshProjectsAgain = false
    @ObservationIgnored
    private var hostConfigurationGeneration = 0

    init(
        client: any CodexTaskClient = CodexAppServerClient(),
        persistence: any BoardPersisting = BoardPersistence(),
        discovery: ProjectDiscoveryService = ProjectDiscoveryService(),
        attachmentStorage: AttachmentStorage = AttachmentStorage(),
        worktreeManager: any WorktreeManaging = WorktreeManager(),
        worktreeManagerFactory: WorktreeManagerFactory? = nil,
        externalURLOpener: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        sshDiscovery: SSHHostDiscoveryService = SSHHostDiscoveryService(),
        clientFactory: CodexTaskClientFactory? = nil,
        drainStabilityDelay: Duration = .milliseconds(500)
    ) {
        self.client = client
        self.persistence = persistence
        self.discovery = discovery
        self.attachmentStorage = attachmentStorage
        self.worktreeManager = worktreeManager
        self.worktreeManagerFactory = worktreeManagerFactory ?? { _, client in
            RemoteWorktreeManager(client: client)
        }
        self.worktreeManagers = [CodexHost.localID: worktreeManager]
        self.externalURLOpener = externalURLOpener
        self.sshDiscovery = sshDiscovery
        self.drainStabilityDelay = drainStabilityDelay
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
        capabilityRefreshTask?.cancel()
        streamFlushTask?.cancel()
        planningStartupWorker?.cancel()
        planningStartupWaiters.values
            .flatMap { $0 }
            .forEach { $0.resume() }
        retryTasks.values.forEach { $0.cancel() }
        drainTasksByRunID.values.forEach { $0.cancel() }
    }

    var selectedProject: ProjectRecord? {
        selectedProjectID.flatMap { id in projects.first(where: { $0.id == id }) }
    }

    var visibleProjects: [ProjectRecord] {
        projects.filter { project in
            (project.isManual || !hiddenProjectPaths.contains(project.id))
                && (preferences.showMissingProjects || !isLocalHost(project.hostID) || project.existsOnDisk)
        }
    }

    var enabledHosts: [CodexHost] {
        hosts.filter(\.isEnabled)
    }

    var connectedHostCount: Int {
        enabledHosts.count { hostConnectionState(for: $0.id).isConnected }
    }

    var filteredTaskCards: [BoardTaskCard] {
        guard let selectedProjectID else { return taskCards }
        return taskCards.filter { $0.projectID == selectedProjectID }
    }

    var activeExecutionCount: Int {
        taskCards.count(where: { $0.stage == .executing })
    }

    var runningTasks: [BoardTaskCard] {
        taskCards
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
        taskCards.count(where: { $0.stage.isActive })
    }

    var defaultTaskModel: CodexModel? {
        if let override = preferences.modelOverride.nilIfEmpty,
           let model = availableModels.first(where: { $0.model == override || $0.id == override }) {
            return model
        }
        return availableModels.first(where: \.isDefault) ?? availableModels.first
    }

    func defaultTaskEffort(for modelName: String) -> ReasoningEffort {
        guard let model = availableModels.first(where: { $0.model == modelName }) else {
            return preferences.planningEffort
        }
        if model.supportedReasoningEfforts.contains(where: { $0.effort == preferences.planningEffort }) {
            return preferences.planningEffort
        }
        return model.defaultReasoningEffort
    }

    func projectName(for task: BoardTask) -> String {
        projects.first(where: { $0.id == task.projectID })?.name
            ?? URL(fileURLWithPath: task.projectID).lastPathComponent
    }

    func projectName(for task: BoardTaskCard) -> String {
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

    func worktreeCapabilityAvailability(
        for projectID: String
    ) -> WorktreeCapabilityAvailability {
        guard let project = projects.first(where: { $0.id == projectID }) else {
            return .unavailable(reason: "项目尚未载入。")
        }
        guard let projectHost = host(for: project.hostID) else {
            return .unavailable(reason: "项目所属主机已不存在。")
        }
        guard projectHost.isEnabled else {
            return .unavailable(reason: "项目所属主机已停用。")
        }
        guard project.path != "/", project.existsOnDisk else {
            return .unavailable(reason: "项目路径尚未在对应主机验证。")
        }
        guard project.isGitRepository else {
            return .unsupported(reason: "所选项目不是 Git 仓库。")
        }
        if let cached = worktreeCapabilityAvailabilityByProjectID[projectID] {
            return cached
        }
        if isLocalHost(project.hostID) {
            return .unavailable(reason: "尚未完成本机 Git HEAD 与 Worktree 能力探测。")
        }
        return .unavailable(reason: "尚未从对应主机确认 Worktree 能力。")
    }

    func isProbingWorktreeCapability(for projectID: String) -> Bool {
        worktreeCapabilityProbingProjectIDs.contains(projectID)
    }

    func hasResolvedWorktreeCapability(for projectID: String) -> Bool {
        worktreeCapabilityAvailabilityByProjectID[projectID] != nil
    }

    @discardableResult
    func refreshWorktreeCapability(
        projectID: String
    ) async -> WorktreeCapabilityAvailability? {
        let generation = beginWorktreeCapabilityProbe(projectID: projectID)
        defer {
            finishWorktreeCapabilityProbe(projectID: projectID, generation: generation)
        }
        guard !Task.isCancelled else { return nil }
        guard let project = projects.first(where: { $0.id == projectID }) else {
            return publishWorktreeCapability(
                .unavailable(reason: "项目尚未载入。"),
                projectID: projectID,
                generation: generation
            )
        }
        guard let projectHost = host(for: project.hostID) else {
            return publishWorktreeCapability(
                .unavailable(reason: "项目所属主机已不存在。"),
                projectID: projectID,
                generation: generation
            )
        }
        guard projectHost.isEnabled else {
            return publishWorktreeCapability(
                .unavailable(reason: "项目所属主机已停用。"),
                projectID: projectID,
                generation: generation
            )
        }
        guard project.path != "/", project.existsOnDisk else {
            return publishWorktreeCapability(
                .unavailable(reason: "项目路径尚未在对应主机验证。"),
                projectID: projectID,
                generation: generation
            )
        }
        guard project.isGitRepository else {
            return publishWorktreeCapability(
                .unsupported(reason: "所选项目不是 Git 仓库。"),
                projectID: projectID,
                generation: generation
            )
        }
        let availability = await worktreeManager(for: projectHost).capability(
            projectPath: project.path,
            requiredCapability: .managedV1
        )
        guard !Task.isCancelled,
              worktreeCapabilityProbeGenerationByProjectID[projectID] == generation,
              let current = projects.first(where: { $0.id == projectID }),
              current.hostID == project.hostID,
              current.path == project.path,
              current.existsOnDisk,
              current.isGitRepository,
              let currentHost = host(for: current.hostID),
              currentHost.isEnabled
        else { return nil }
        return publishWorktreeCapability(
            availability,
            projectID: projectID,
            generation: generation
        )
    }

    func dependencyCandidates(for projectID: String) -> [BoardTask] {
        tasks
            .filter { $0.projectID == projectID }
            .sorted { lhs, rhs in
                if lhs.stage == .completed, rhs.stage != .completed { return false }
                if lhs.stage != .completed, rhs.stage == .completed { return true }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    func dependencies(for task: BoardTask) -> [BoardTask] {
        var order: [UUID: Int] = [:]
        for (index, dependencyID) in task.dependencyIDs.enumerated() where order[dependencyID] == nil {
            order[dependencyID] = index
        }
        return tasks
            .filter { order[$0.id] != nil }
            .sorted { order[$0.id, default: .max] < order[$1.id, default: .max] }
    }

    func blockingDependencyCount(for task: BoardTask) -> Int {
        let completedIDs = Set(tasks.lazy.filter { $0.stage == .completed }.map(\.id))
        return Set(task.dependencyIDs).count { !completedIDs.contains($0) }
    }

    func interactions(for taskID: UUID) -> [CodexInteractionRequest] {
        pendingInteractionsByTaskID[taskID] ?? []
    }

    func hasPendingInteraction(for taskID: UUID) -> Bool {
        !(pendingInteractionsByTaskID[taskID]?.isEmpty ?? true)
    }

    func isResponding(taskID: UUID, requestID: CodexRequestID) -> Bool {
        guard let hostID = tasks.first(where: { $0.id == taskID })?.hostID else { return false }
        return respondingRequests.contains(HostRequestKey(hostID: hostID, requestID: requestID))
    }

    func respondToInteraction(
        taskID: UUID,
        requestID: CodexRequestID,
        response: CodexInteractionResponse
    ) async {
        guard let request = pendingInteractionsByTaskID[taskID]?.first(where: { $0.id == requestID })
        else { return }
        guard let task = tasks.first(where: { $0.id == taskID }),
              task.threadID == request.threadID
        else {
            removeInteraction(taskID: taskID, requestID: requestID)
            return
        }
        let responseKey = HostRequestKey(hostID: task.hostID, requestID: requestID)
        guard !respondingRequests.contains(responseKey) else { return }

        setResponding(true, key: responseKey)
        defer { setResponding(false, key: responseKey) }
        do {
            guard let host = host(for: task.hostID), host.isEnabled else {
                throw CodexClientError.invalidResponse("任务主机已停用或不再存在")
            }
            try await clientForHost(host).respond(to: requestID, with: response)
            removeInteraction(taskID: taskID, requestID: requestID)
            if let index = taskIndex(taskID), tasks[index].stage.isActive {
                tasks[index].lastError = nil
                tasks[index].liveMessage = hasPendingInteraction(for: taskID)
                    ? "Codex 仍在等待人工确认…"
                    : (tasks[index].stage == .planning ? "Codex 继续制定方案…" : "Codex 继续实施方案…")
                tasks[index].updatedAt = Date()
            }
        } catch {
            guard pendingInteractionsByTaskID[taskID]?.contains(where: { $0.id == requestID }) == true,
                  let index = taskIndex(taskID)
            else { return }
            tasks[index].lastError = "交互响应失败，请重试。"
            tasks[index].liveMessage = "等待人工确认"
            tasks[index].updatedAt = Date()
            appendLog(at: index, "交互响应未送达，请重试。", level: .error)
        }
        scheduleSave()
    }

    func dependents(of taskID: UUID) -> [BoardTask] {
        tasks.filter { $0.dependencyIDs.contains(taskID) }
    }

    func focusTask(_ taskID: UUID) {
        guard let task = taskCards.first(where: { $0.id == taskID }) else { return }
        selectedProjectID = task.projectID
        selectedTaskID = taskID
        taskFocusRequest = TaskFocusRequest(taskID: taskID, stage: task.stage, nonce: UUID())
    }

    @discardableResult
    func focusAttentionTask(_ taskID: UUID) -> Bool {
        guard attentionNotices.contains(where: { $0.taskID == taskID }) else { return false }
        focusTask(taskID)
        return true
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
            invalidateWorktreeCapabilities(for: host.id)
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
        let refreshedProjectIDs = Set(projects.map(\.id))
        worktreeCapabilityAvailabilityByProjectID = worktreeCapabilityAvailabilityByProjectID.filter {
            refreshedProjectIDs.contains($0.key)
        }
        accountReady = connectedHostCount > 0
        selectInitialProjectIfNeeded()
        if errors.isEmpty {
            lastError = nil
            statusMessage = "已连接 \(connectedHostCount) 台主机，载入 \(projects.count) 个项目"
        } else {
            lastError = errors.joined(separator: "\n")
            statusMessage = "已连接 \(connectedHostCount)/\(enabledHosts.count) 台主机"
        }
        reconcileManualProjectVisibility()
        if let selectedProjectID {
            scheduleCapabilityRefresh(projectID: selectedProjectID, forceRefresh: false)
            if projects.first(where: { $0.id == selectedProjectID }).map({
                !isLocalHost($0.hostID)
            }) == true {
                Task { @MainActor [weak self] in
                    await self?.refreshWorktreeCapability(projectID: selectedProjectID)
                }
            }
        }
    }

    func refreshModels(for projectID: String? = nil) async {
        let targetProjectID = projectID ?? selectedProjectID
        if let targetProjectID, selectedProjectID != targetProjectID {
            return
        }
        let hostID = targetProjectID.flatMap { id in
            projects.first(where: { $0.id == id })?.hostID
        } ?? CodexHost.localID
        modelRefreshGeneration &+= 1
        let generation = modelRefreshGeneration
        guard let host = host(for: hostID), host.isEnabled else {
            availableModels = []
            modelCatalogHostID = nil
            modelCatalogProjectID = nil
            modelCatalogError = "所选项目的主机已停用或不再存在。"
            return
        }
        isLoadingModels = true
        modelCatalogError = nil
        defer {
            if modelRefreshGeneration == generation {
                isLoadingModels = false
            }
        }
        do {
            let hostClient = clientForHost(host)
            try await hostClient.connect()
            let models = try await hostClient.listModels()
            guard !Task.isCancelled,
                  modelRefreshGeneration == generation,
                  selectedProjectID == targetProjectID
            else { return }
            availableModels = models
            modelCatalogHostID = hostID
            modelCatalogProjectID = targetProjectID
            modelCatalogError = models.isEmpty ? "\(host.name) Codex 未返回可用模型。" : nil
        } catch {
            guard modelRefreshGeneration == generation,
                  selectedProjectID == targetProjectID
            else { return }
            availableModels = []
            modelCatalogHostID = nil
            modelCatalogProjectID = nil
            modelCatalogError = error.localizedDescription
        }
    }

    func refreshCapabilities(projectID: String, forceRefresh: Bool = false) async {
        guard let project = projects.first(where: { $0.id == projectID }) else {
            if capabilityProjectID == projectID {
                availableSkills = []
                capabilityCatalogError = BoardStoreError.invalidProject.localizedDescription
            }
            return
        }

        capabilityRefreshGeneration &+= 1
        let generation = capabilityRefreshGeneration
        let projectChanged = capabilityProjectID != projectID
        capabilityProjectID = projectID
        if projectChanged {
            availableSkills = []
            availableApps = []
        }
        isLoadingCapabilities = true
        capabilityCatalogError = nil
        defer {
            if capabilityRefreshGeneration == generation {
                isLoadingCapabilities = false
            }
        }

        guard let host = host(for: project.hostID), host.isEnabled else {
            capabilityCatalogError = "所选项目的主机已停用或不再存在。"
            return
        }
        let hostClient = clientForHost(host)
        do {
            try await hostClient.connect()
        } catch {
            guard capabilityRefreshGeneration == generation else { return }
            capabilityCatalogError = error.localizedDescription
            return
        }

        var nextSkills: [CodexSkillMetadata]?
        var nextApps: [CodexApp]?
        var errors: [String] = []
        do {
            let skillsByCWD = try await hostClient.listSkills(
                cwds: [project.path],
                forceReload: forceRefresh
            )
            nextSkills = skillsForProject(path: project.path, in: skillsByCWD)
        } catch {
            errors.append("Skills：\(error.localizedDescription)")
        }
        guard !Task.isCancelled, capabilityRefreshGeneration == generation else { return }
        do {
            nextApps = try await hostClient.listApps(forceRefresh: forceRefresh)
        } catch {
            errors.append("Apps：\(error.localizedDescription)")
        }
        guard !Task.isCancelled, capabilityRefreshGeneration == generation else { return }

        if let nextSkills {
            availableSkills = stableUniqueSkills(nextSkills.filter(\.enabled))
        }
        if let nextApps {
            availableApps = stableUniqueApps(nextApps)
        }
        capabilityCatalogError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    func refreshMCPServers() async {
        mcpRefreshGeneration &+= 1
        let generation = mcpRefreshGeneration
        isLoadingMCPServers = true
        mcpServerError = nil
        defer {
            if mcpRefreshGeneration == generation {
                isLoadingMCPServers = false
            }
        }
        do {
            let hostID = selectedTask?.hostID ?? selectedProject?.hostID ?? CodexHost.localID
            guard let host = host(for: hostID), host.isEnabled else {
                throw CodexClientError.invalidResponse("所选项目的主机已停用或不再存在")
            }
            let hostClient = clientForHost(host)
            try await hostClient.connect()
            let threadID = selectedTask?.threadID
            let servers = try await hostClient.listMCPServers(threadID: threadID)
            guard !Task.isCancelled, mcpRefreshGeneration == generation else { return }
            mcpServers = stableUniqueMCPServers(servers)
        } catch {
            guard mcpRefreshGeneration == generation else { return }
            mcpServerError = error.localizedDescription
        }
    }

    func beginMCPOAuth(serverName: String) async {
        let cleanName = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostID = selectedTask?.hostID ?? selectedProject?.hostID ?? CodexHost.localID
        let oauthKey = HostServerKey(hostID: hostID, serverName: cleanName)
        guard !cleanName.isEmpty, !oauthRequestsInProgress.contains(oauthKey) else { return }
        setOAuthInProgress(true, key: oauthKey)
        mcpServerError = nil
        do {
            guard let host = host(for: hostID), host.isEnabled else {
                throw CodexClientError.invalidResponse("所选项目的主机已停用或不再存在")
            }
            let hostClient = clientForHost(host)
            try await hostClient.connect()
            let url = try await hostClient.beginMCPOAuth(
                serverName: cleanName,
                threadID: selectedTask?.threadID
            )
            guard openInteractionURL(url) else {
                throw BoardStoreOAuthError.cannotOpenBrowser
            }
        } catch {
            setOAuthInProgress(false, key: oauthKey)
            mcpServerError = error.localizedDescription
        }
    }

    func isMCPOAuthInProgress(serverName: String) -> Bool {
        let hostID = selectedTask?.hostID ?? selectedProject?.hostID ?? CodexHost.localID
        return oauthRequestsInProgress.contains(
            HostServerKey(hostID: hostID, serverName: serverName)
        )
    }

    @discardableResult
    func openInteractionURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        return externalURLOpener(url)
    }

    func addManualProject(path: String, hostID: String = CodexHost.localID) {
        guard let host = host(for: hostID),
              let normalized = normalizeProjectPath(path, isRemote: host.kind == .ssh)
        else {
            lastError = "远程项目必须使用绝对路径。"
            return
        }
        let reference = ManualProjectReference(hostID: hostID, path: normalized)
        manualProjects.removeAll { $0 == reference }
        manualProjects.insert(reference, at: 0)
        hiddenProjectPaths.remove(normalized)
        if let projectID = projects.first(where: {
            $0.hostID == hostID && $0.path == normalized
        })?.id {
            hiddenProjectPaths.remove(projectID)
        }
        scheduleSave()
        Task { @MainActor [weak self] in await self?.refreshProjects() }
    }

    func removeProjectFromSidebar(_ project: ProjectRecord) {
        hiddenProjectPaths.insert(project.id)
        manualProjects.removeAll { reference in
            reference.hostID == project.hostID
                && Self.isSameOrDescendant(
                    reference.path,
                    of: project.path,
                    isRemote: !isLocalHost(project.hostID)
                )
        }
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index].isManual = false
            projects[index].manualPriority = nil
        }
        if selectedProjectID == project.id {
            selectedProjectID = visibleProjects.first?.id
        }
        scheduleSave()
    }

    func removeManualProject(_ project: ProjectRecord) {
        guard project.isManual else { return }
        removeProjectFromSidebar(project)
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
        invalidateWorktreeCapabilities(for: hostID)
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
        invalidateWorktreeCapabilities(for: hostID)
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
        invalidateWorktreeCapabilities(for: hostID)
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
        attachmentDrafts: [TaskAttachmentDraft] = [],
        autoRun: Bool,
        model: String? = nil,
        effort: ReasoningEffort? = nil,
        fastMode: Bool = false,
        selectedSkills: [TaskSkillSelection] = [],
        selectedApps: [TaskAppSelection] = [],
        workspaceKind: TaskWorkspaceKind = .project,
        dependencyIDs: [UUID] = []
    ) async throws -> UUID {
        let body = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !attachmentDrafts.isEmpty else { throw BoardStoreError.emptyTask }
        guard let project = projects.first(where: { $0.id == projectID }),
              project.path != "/",
              project.existsOnDisk,
              let projectHost = host(for: project.hostID),
              projectHost.isEnabled
        else {
            throw BoardStoreError.invalidProject
        }
        if projectHost.kind == .ssh {
            guard attachmentDrafts.isEmpty else {
                throw BoardStoreError.remoteAttachmentsUnsupported
            }
        }
        guard workspaceKind != .worktree || project.isGitRepository else {
            throw BoardStoreError.worktreeRequiresGit
        }
        if workspaceKind == .worktree {
            _ = try await requireWorktreeCapability(project: project, host: projectHost)
        }
        let uniqueDependencyIDs = dependencyIDs.reduce(into: [UUID]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        guard uniqueDependencyIDs.allSatisfy({ dependencyID in
            tasks.contains(where: { $0.id == dependencyID && $0.projectID == projectID })
        }) else { throw BoardStoreError.invalidDependencies }
        let taskID = UUID()
        let attachments = try await attachmentStorage.materialize(attachmentDrafts, taskID: taskID)
        guard projects.contains(where: { $0.id == projectID }) else {
            await attachmentStorage.removeManagedAttachments(taskID: taskID, attachments: attachments)
            throw BoardStoreError.invalidProject
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let derivedTitle = body.split(whereSeparator: \.isNewline).first.map(String.init)
            ?? attachments.first?.displayName
            ?? sourceKind.title
        var task = BoardTask(
            id: taskID,
            projectID: projectID,
            hostID: project.hostID,
            title: cleanTitle.isEmpty ? String(derivedTitle.prefix(80)) : cleanTitle,
            sourceKind: sourceKind,
            sourceText: body,
            attachments: attachments,
            selectedSkills: stableUniqueSkillSelections(selectedSkills),
            selectedApps: safeUniqueAppSelections(selectedApps),
            autoRun: autoRun,
            requestedModel: resolvedModel(model),
            reasoningEffort: effort ?? preferences.planningEffort,
            fastMode: fastMode,
            workspace: TaskWorkspaceConfiguration(kind: workspaceKind),
            dependencyIDs: uniqueDependencyIDs
        )
        let blockingCount = blockingDependencyCount(for: task)
        if blockingCount > 0 {
            task.liveMessage = "等待 \(blockingCount) 个前置任务验收"
            task.logs.append(TaskLogEntry(message: autoRun
                ? "任务已加入看板，等待前置任务完成后自动开始规划。"
                : "任务已加入看板；前置任务完成后仍需手动开始规划。"))
        } else if autoRun {
            task.logs.append(TaskLogEntry(message: "任务已加入看板，准备自动规划。"))
        } else {
            task.liveMessage = "等待开始规划"
            task.logs.append(TaskLogEntry(message: "任务已加入看板，等待手动开始规划。"))
        }
        tasks.append(task)
        let reference = ManualProjectReference(hostID: project.hostID, path: project.path)
        if !manualProjects.contains(reference) {
            // Persist the path alongside the task so it remains visible when a
            // remote host is temporarily offline on the next launch.
            manualProjects.append(reference)
        }
        selectedProjectID = projectID
        selectedTaskID = task.id
        scheduleSave(immediate: true)
        if autoRun && blockingCount == 0 {
            enqueuePlanning(taskID: task.id)
        }
        return task.id
    }

    /// Synchronous convenience used by live-task capture, where there are no
    /// local attachment drafts to materialize before the card is enqueued.
    @discardableResult
    func createLiveTask(
        projectID: String,
        title: String,
        sourceKind: TaskSourceKind,
        sourceText: String,
        autoRun: Bool
    ) -> UUID? {
        let body = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty,
              let project = projects.first(where: { $0.id == projectID }),
              isProjectRunnable(project)
        else {
            lastError = BoardStoreError.invalidProject.localizedDescription
            return nil
        }

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let derivedTitle = body.split(whereSeparator: \.isNewline).first.map(String.init)
            ?? sourceKind.title
        var task = BoardTask(
            projectID: project.id,
            hostID: project.hostID,
            title: cleanTitle.isEmpty ? String(derivedTitle.prefix(80)) : cleanTitle,
            sourceKind: sourceKind,
            sourceText: body,
            autoRun: autoRun,
            requestedModel: resolvedModel(nil),
            reasoningEffort: preferences.planningEffort,
            workspace: TaskWorkspaceConfiguration(kind: .project)
        )
        task.liveMessage = autoRun ? "准备自动规划" : "等待开始规划"
        task.logs.append(TaskLogEntry(message: autoRun
            ? "任务已加入看板，准备自动规划。"
            : "任务已加入看板，等待手动开始规划。"))
        tasks.append(task)

        let reference = ManualProjectReference(hostID: project.hostID, path: project.path)
        if !manualProjects.contains(reference) {
            manualProjects.append(reference)
        }
        selectedProjectID = project.id
        selectedTaskID = task.id
        scheduleSave(immediate: true)
        if autoRun {
            enqueuePlanning(taskID: task.id)
        }
        return task.id
    }

    func startPlanning(taskID: UUID) async {
        await withCheckedContinuation { continuation in
            planningStartupWaiters[taskID, default: []].append(continuation)
            enqueuePlanning(taskID: taskID)
        }
    }

    private func performPlanningStart(taskID: UUID) async {
        guard let initialIndex = taskIndex(taskID), let project = project(forTaskAt: initialIndex) else { return }
        guard tasks[initialIndex].stage == .inbox,
              !worktreeCleanupInFlightTaskIDs.contains(taskID)
        else { return }
        guard let host = host(for: tasks[initialIndex].hostID), host.isEnabled else {
            failTask(at: initialIndex, message: "任务主机已停用或不再存在。")
            return
        }
        discardPendingStreamUpdate(for: taskID)
        let blockerCount = blockingDependencyCount(for: tasks[initialIndex])
        guard blockerCount == 0 else {
            tasks[initialIndex].stage = .inbox
            tasks[initialIndex].liveMessage = "等待 \(blockerCount) 个前置任务验收"
            tasks[initialIndex].updatedAt = Date()
            scheduleSave()
            return
        }
        guard project.existsOnDisk else {
            failTask(at: initialIndex, message: "项目目录不存在：\(project.path)", kind: .workspace)
            return
        }
        guard project.path != "/" else {
            failTask(at: initialIndex, message: "拒绝把文件系统根目录作为任务工作区。", kind: .workspace)
            return
        }
        if host.kind == .ssh, !tasks[initialIndex].attachments.isEmpty {
            failTask(
                at: initialIndex,
                message: BoardStoreError.remoteAttachmentsUnsupported.localizedDescription,
                kind: .workspace
            )
            return
        }
        // Claim the task before the first suspension point so a rapid double
        // click cannot create duplicate Codex threads or planning turns.
        tasks[initialIndex].stage = .planning
        tasks[initialIndex].executionApproved = false
        tasks[initialIndex].planText = ""
        tasks[initialIndex].hasFinalPlan = false
        tasks[initialIndex].structuredPlan = []
        tasks[initialIndex].planningTurnID = nil
        tasks[initialIndex].executionTurnID = nil
        tasks[initialIndex].liveMessage = "正在连接 \(host.name) Codex…"
        tasks[initialIndex].lastError = nil
        tasks[initialIndex].updatedAt = Date()
        appendLog(at: initialIndex, "开始只读规划。")
        let planningRunID = beginRun(at: initialIndex, phase: .planning)
        let planningAttachments = tasks[initialIndex].attachments
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
            if host.kind == .local {
                try await attachmentStorage.validate(planningAttachments)
            }
        } catch {
            if let failureIndex = taskIndex(taskID) {
                failTask(at: failureIndex, message: error.localizedDescription, kind: .workspace)
            }
            return
        }

        guard taskIndex(taskID).map({ tasks[$0].stage == .planning }) == true else { return }

        do {
            try await hostClient.connect()
            hostConnectionStates[host.id] = .connected
            guard let connectionIndex = taskIndex(taskID),
                  tasks[connectionIndex].stage == .planning
            else { return }
            let existingThreadID = tasks[connectionIndex].threadID
            let requestedModel = tasks[connectionIndex].requestedModel
            let fastMode = tasks[connectionIndex].fastMode
            let taskTitle = tasks[connectionIndex].title
            let isNewThread = existingThreadID == nil
            let startedThread: CodexStartedThread
            if let existingThreadID {
                startedThread = try await hostClient.resumeThread(
                    threadID: existingThreadID,
                    cwd: project.path
                )
            } else {
                startedThread = try await hostClient.startThread(
                    cwd: project.path,
                    model: requestedModel,
                    serviceTier: fastMode ? CodexServiceTier.fast : CodexServiceTier.standard
                )
            }
            guard let currentIndex = taskIndex(taskID) else { return }
            tasks[currentIndex].threadID = startedThread.threadID
            tasks[currentIndex].sessionID = startedThread.sessionID
            if tasks[currentIndex].requestedModel.isEmpty {
                tasks[currentIndex].requestedModel = startedThread.model
            }
            tasks[currentIndex].actualModel = startedThread.model
            tasks[currentIndex].liveMessage = "Codex 正在检查项目并制定方案…"
            updateRun(at: currentIndex, runID: planningRunID) { run in
                run.threadID = startedThread.threadID
                run.sessionID = startedThread.sessionID
                run.model = startedThread.model
            }
            guard await saveImmediately() else {
                if let failureIndex = taskIndex(taskID), tasks[failureIndex].stage == .planning {
                    failTask(
                        at: failureIndex,
                        message: "Codex thread 已创建但无法持久化其标识；未启动规划 Turn。"
                    )
                }
                return
            }
            guard let persistedThreadIndex = taskIndex(taskID),
                  tasks[persistedThreadIndex].stage == .planning,
                  tasks[persistedThreadIndex].runs.contains(where: {
                      $0.id == planningRunID && $0.outcome.isActive
                  })
            else { return }
            if isNewThread {
                try? await hostClient.setThreadName(
                    threadID: startedThread.threadID,
                    name: "CodexBoard · \(taskTitle)"
                )
            }

            let runtimeSafeApps = await runtimeSafeApps(
                selectedApps: tasks[persistedThreadIndex].selectedApps,
                taskID: taskID
            )
            guard let inputIndex = taskIndex(taskID),
                  tasks[inputIndex].stage == .planning
            else { return }
            if cancellationIntentTaskIDs.contains(taskID) {
                failTask(
                    at: inputIndex,
                    message: "任务已停止。",
                    runOutcome: .interrupted,
                    kind: .interrupted
                )
                return
            }
            var runtimeTask = tasks[inputIndex]
            runtimeTask.selectedApps = runtimeSafeApps
            let input = TaskPromptBuilder.planningInput(
                for: runtimeTask,
                projectPath: project.path,
                dependencies: dependencyHandoffs(for: tasks[inputIndex])
            )
            let planningPolicy = taskRunPolicySnapshot(
                for: tasks[inputIndex],
                phase: .planning,
                cwd: project.path
            )
            updateRun(at: inputIndex, runID: planningRunID) { run in
                run.policySnapshot = planningPolicy
            }
            let planningModel = tasks[inputIndex].requestedModel
            let planningEffort = tasks[inputIndex].reasoningEffort
            let planningServiceTier = tasks[inputIndex].fastMode
                ? CodexServiceTier.fast
                : CodexServiceTier.standard
            guard await saveImmediately() else {
                if let failureIndex = taskIndex(taskID) {
                    failTask(
                        at: failureIndex,
                        message: "无法持久化规划运行策略；未启动规划 Turn。"
                    )
                }
                return
            }
            guard let persistedIndex = taskIndex(taskID),
                  tasks[persistedIndex].stage == .planning,
                  tasks[persistedIndex].runs.contains(where: {
                      $0.id == planningRunID && $0.outcome.isActive
                  })
            else { return }
            if cancellationIntentTaskIDs.contains(taskID) {
                failTask(
                    at: persistedIndex,
                    message: "任务已停止。",
                    runOutcome: .interrupted,
                    kind: .interrupted
                )
                return
            }
            let turn = try await hostClient.startPlanningTurn(
                threadID: startedThread.threadID,
                cwd: project.path,
                input: input,
                model: planningModel,
                effort: planningEffort,
                serviceTier: planningServiceTier
            )
            guard let finalIndex = taskIndex(taskID),
                  tasks[finalIndex].stage == .planning,
                  !cancellationIntentTaskIDs.contains(taskID)
            else {
                try? await hostClient.interrupt(threadID: startedThread.threadID, turnID: turn.turnID)
                if let cancelledIndex = taskIndex(taskID),
                   tasks[cancelledIndex].stage == .planning {
                    failTask(
                        at: cancelledIndex,
                        message: "任务已停止。",
                        runOutcome: .interrupted,
                        kind: .interrupted
                    )
                }
                return
            }
            tasks[finalIndex].planningTurnID = turn.turnID
            updateRun(at: finalIndex, runID: planningRunID) { run in
                run.turnID = turn.turnID
            }
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
                failTask(
                    at: failureIndex,
                    message: error.localizedDescription,
                    kind: classifyFailure(error.localizedDescription),
                    retryPhase: .planning,
                    automaticRetryAllowed: !isAmbiguousLifecycleTimeout(error)
                )
            }
        }
    }

    func confirmPlan(taskID: UUID) {
        guard let index = taskIndex(taskID),
              tasks[index].stage == .awaitingApproval,
              tasks[index].hasFinalPlan,
              !tasks[index].planText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        resolvePlanAttention(taskID: taskID)
        tasks[index].executionApproved = true
        tasks[index].updatedAt = Date()
        appendLog(at: index, "方案已确认，等待执行槽位。", level: .success)
        scheduleSave(immediate: true)
        scheduleExecutionQueue()
    }

    @discardableResult
    func updatePlan(taskID: UUID, planText: String) -> Bool {
        guard let index = taskIndex(taskID),
              tasks[index].stage == .awaitingApproval,
              tasks[index].hasFinalPlan,
              !planText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }

        tasks[index].planText = planText
        tasks[index].structuredPlan = []
        tasks[index].executionApproved = false
        tasks[index].updatedAt = Date()
        addPlanAttention(taskID: taskID, createdAt: tasks[index].updatedAt)
        focusTask(taskID)
        appendLog(at: index, "方案已手动修改，需要重新确认。", level: .warning)
        scheduleSave(immediate: true)
        return true
    }

    func revisePlan(taskID: UUID) {
        guard let index = taskIndex(taskID), !tasks[index].stage.isActive else { return }
        resolveDurableAttention(at: index)
        retryTasks[taskID]?.cancel()
        retryTasks[taskID] = nil
        tasks[index].stage = .inbox
        tasks[index].executionApproved = false
        tasks[index].failureState = nil
        tasks[index].updatedAt = Date()
        appendLog(at: index, "方案退回，准备重新规划。", level: .warning)
        scheduleSave(immediate: true)
        enqueuePlanning(taskID: taskID)
    }

    func continueExecution(taskID: UUID) {
        guard !worktreeCleanupInFlightTaskIDs.contains(taskID) else { return }
        Task { @MainActor [weak self] in
            await self?.reconcileAndContinueExecution(taskID: taskID)
        }
    }

    private func reconcileAndContinueExecution(taskID: UUID) async {
        guard let index = taskIndex(taskID),
              !tasks[index].stage.isActive,
              !worktreeCleanupInFlightTaskIDs.contains(taskID),
              tasks[index].hasFinalPlan,
              !tasks[index].planText.isEmpty
        else { return }
        resolvePlanAttention(taskID: taskID)
        retryTasks[taskID]?.cancel()
        retryTasks[taskID] = nil

        let taskSnapshot = tasks[index]
        guard let host = host(for: taskSnapshot.hostID), host.isEnabled else {
            failTask(at: index, message: "任务主机已停用或不再存在。")
            return
        }

        if let threadID = taskSnapshot.threadID {
            do {
                let hostClient = clientForHost(host)
                try await hostClient.connect()
                guard !worktreeCleanupInFlightTaskIDs.contains(taskID) else { return }
                let detail = try await hostClient.readThread(
                    threadID: threadID,
                    includeTurns: true
                )
                guard let currentIndex = taskIndex(taskID),
                      !worktreeCleanupInFlightTaskIDs.contains(taskID)
                else { return }
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
                        // A disconnect closes the in-memory run before the user
                        // asks us to reconcile it. thread/read is authoritative:
                        // reopen that exact run briefly so the normal completion
                        // path can attach delivery evidence and enter review.
                        if let runIndex = tasks[currentIndex].runs.lastIndex(where: {
                            $0.phase == .execution
                                && ($0.turnID == candidateTurn.id || $0.turnID == nil)
                        }) {
                            tasks[currentIndex].runs[runIndex].outcome = .running
                            tasks[currentIndex].runs[runIndex].endedAt = nil
                            tasks[currentIndex].runs[runIndex].error = nil
                            tasks[currentIndex].runs[runIndex].failure = nil
                        }
                        tasks[currentIndex].stage = .executing
                        tasks[currentIndex].failureState = nil
                        resolveFailureAttention(taskID: taskID)
                        completeTurn(
                            at: currentIndex,
                            turnID: candidateTurn.id,
                            status: "completed",
                            error: nil
                        )
                        return

                    case "inprogress", "running", "active", "pending", "queued":
                        restoreExecutionRunForConfirmedTurn(
                            at: currentIndex,
                            turnID: candidateTurn.id
                        )
                        tasks[currentIndex].stage = .executing
                        tasks[currentIndex].executionApproved = false
                        tasks[currentIndex].failureState = nil
                        tasks[currentIndex].lastError = nil
                        resolveFailureAttention(taskID: taskID)
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
                            tasks[resumedIndex].actualModel = resumed.model
                            if tasks[resumedIndex].requestedModel.isEmpty {
                                tasks[resumedIndex].requestedModel = resumed.model
                            }
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
                if !worktreeCleanupInFlightTaskIDs.contains(taskID),
                   let failureIndex = taskIndex(taskID) {
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
        guard !worktreeCleanupInFlightTaskIDs.contains(tasks[index].id) else { return }
        resolveFailureAttention(taskID: tasks[index].id)
        tasks[index].executionTurnID = nil
        tasks[index].failureState = nil
        tasks[index].stage = .awaitingApproval
        tasks[index].executionApproved = true
        tasks[index].lastError = nil
        tasks[index].updatedAt = Date()
        appendLog(at: index, "已完成远端状态对账，从当前工作区继续执行。")
        scheduleSave(immediate: true)
        scheduleExecutionQueue()
    }

    private func normalizedTurnStatus(_ status: String) -> String {
        status.lowercased().filter(\.isLetter)
    }

    func acceptReview(taskID: UUID) {
        guard let index = taskIndex(taskID), tasks[index].stage == .review else { return }
        updateLatestExecutionRun(at: index) { run in
            guard run.outcome == .awaitingReview else { return }
            run.outcome = .accepted
            run.reviewedAt = Date()
        }
        tasks[index].stage = .completed
        tasks[index].executionApproved = false
        tasks[index].reviewFeedback = nil
        tasks[index].liveMessage = "验收通过"
        tasks[index].lastError = nil
        tasks[index].updatedAt = Date()
        appendLog(at: index, "交付证据已验收，任务完成。", level: .success)
        scheduleSave(immediate: true)
        scheduleExecutionQueue()
        scheduleEligiblePlanningTasks()
        Task { @MainActor [weak self] in await self?.refreshProjects() }
    }

    @discardableResult
    func requestChanges(taskID: UUID, feedback: String) -> Bool {
        let cleanFeedback = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanFeedback.isEmpty,
              let index = taskIndex(taskID),
              !worktreeCleanupInFlightTaskIDs.contains(taskID),
              tasks[index].stage == .review
        else { return false }

        updateLatestExecutionRun(at: index) { run in
            guard run.outcome == .awaitingReview else { return }
            run.outcome = .changesRequested
            run.reviewNote = cleanFeedback
            run.reviewedAt = Date()
        }
        tasks[index].reviewFeedback = cleanFeedback
        tasks[index].stage = .awaitingApproval
        tasks[index].executionApproved = true
        tasks[index].liveMessage = "验收反馈已记录，等待重新执行"
        tasks[index].updatedAt = Date()
        appendLog(at: index, "验收要求修改：\(cleanFeedback)", level: .warning)
        scheduleSave(immediate: true)
        scheduleExecutionQueue()
        return true
    }

    func cancel(taskID: UUID) async {
        flushPendingStreamUpdates()
        guard let initialIndex = taskIndex(taskID), tasks[initialIndex].stage.isActive else { return }
        cancellationIntentTaskIDs.insert(taskID)
        guard cancellationRequestInFlightTaskIDs.insert(taskID).inserted else { return }
        defer { cancellationRequestInFlightTaskIDs.remove(taskID) }

        let phase: TaskRunPhase = tasks[initialIndex].stage == .planning ? .planning : .execution
        guard let runIndex = tasks[initialIndex].runs.lastIndex(where: {
            $0.phase == phase && $0.outcome.isActive
        }) else { return }
        let runID = tasks[initialIndex].runs[runIndex].id
        let hostID = tasks[initialIndex].hostID
        let now = Date()
        let threadID = tasks[initialIndex].runs[runIndex].threadID ?? tasks[initialIndex].threadID
        let activeTurnID = tasks[initialIndex].stage == .planning
            ? tasks[initialIndex].planningTurnID
            : tasks[initialIndex].executionTurnID
        let turnID = tasks[initialIndex].runs[runIndex].turnID
            ?? activeTurnID
            ?? pendingInteractionsByTaskID[taskID]?.compactMap(\.turnID).first
        var drain = tasks[initialIndex].runs[runIndex].multiAgentDrain ?? TaskRunDrainState(
            phase: .cancelling,
            knownThreadIDs: threadID.map { [$0] } ?? [],
            startedAt: now
        )
        drain.phase = .cancelling
        if drain.cancellationRequestedAt == nil { drain.cancellationRequestedAt = now }
        if let threadID {
            drain.knownThreadIDs = Array(Set(drain.knownThreadIDs + [threadID])).sorted()
            tasks[initialIndex].runs[runIndex].threadID = threadID
        }
        if let turnID { tasks[initialIndex].runs[runIndex].turnID = turnID }
        tasks[initialIndex].runs[runIndex].multiAgentDrain = drain
        tasks[initialIndex].liveMessage = "正在持久化停止意图…"
        tasks[initialIndex].updatedAt = now
        scheduleSave(immediate: true)
        guard await saveImmediately() else {
            if let index = taskIndex(taskID) {
                appendLog(at: index, "停止意图无法持久化，未发送远端中断请求。", level: .error)
            }
            return
        }
        guard activeDrainLocation(taskID: taskID, runID: runID) != nil else { return }

        guard let threadID else {
            if let index = taskIndex(taskID) {
                appendLog(at: index, "将在 Turn 启动完成后立即停止。", level: .warning)
                scheduleSave(immediate: true)
            }
            return
        }

        await cancelPendingInteractions(for: taskID)
        guard activeDrainLocation(taskID: taskID, runID: runID) != nil else { return }
        guard let turnID else {
            if let index = taskIndex(taskID) {
                appendLog(at: index, "停止请求正在等待 Turn 启动完成，请稍后重试。", level: .warning)
                scheduleSave(immediate: true)
            }
            return
        }
        do {
            guard let host = host(for: hostID), host.isEnabled else {
                throw CodexClientError.invalidResponse("任务主机已停用或不再存在")
            }
            try await clientForHost(host).interrupt(threadID: threadID, turnID: turnID)
            clearInteractions(for: taskID)
            if let index = taskIndex(taskID) {
                appendLog(at: index, "已发送停止请求。", level: .warning)
            }
        } catch {
            if let index = taskIndex(taskID) {
                appendLog(at: index, "停止失败：\(error.localizedDescription)", level: .error)
            }
        }
        scheduleSave(immediate: true)
        scheduleDrainReconciliation(taskID: taskID, runID: runID)
    }

    func deleteTask(taskID: UUID) {
        discardPendingStreamUpdate(for: taskID)
        guard let index = taskIndex(taskID), !tasks[index].stage.isActive else { return }
        guard tasks[index].workspace.path == nil else {
            lastError = "这张任务卡仍管理着独立 Worktree；请先在任务详情中安全清理，再删除卡片。"
            return
        }
        let dependentCount = dependents(of: taskID).count
        guard dependentCount == 0 else {
            lastError = "仍有 \(dependentCount) 个任务依赖这张卡片，请先解除依赖。"
            return
        }
        retryTasks[taskID]?.cancel()
        retryTasks[taskID] = nil
        clearInteractions(for: taskID)
        resolveDurableAttention(at: index)
        let deletedTask = tasks.remove(at: index)
        if selectedTaskID == taskID { selectedTaskID = nil }
        if deletedTask.attachments.contains(where: \.isManaged) {
            pendingAttachmentDeletions.append(deletedTask)
        }
        scheduleSave(immediate: true)
    }

    @discardableResult
    func moveTask(taskID: UUID, to stage: TaskStage) -> Bool {
        guard let index = taskIndex(taskID), !tasks[index].stage.isActive, stage.allowsManualDrop else { return false }
        if tasks[index].stage == .review {
            guard stage == .completed else { return false }
            acceptReview(taskID: taskID)
            return true
        }
        if stage == .awaitingApproval
            && (!tasks[index].hasFinalPlan || tasks[index].planText.isEmpty) {
            return false
        }
        tasks[index].stage = stage
        tasks[index].executionApproved = false
        if stage != .awaitingApproval {
            resolveDurableAttention(at: index)
        } else {
            addPlanAttention(taskID: taskID, createdAt: Date())
            focusTask(taskID)
        }
        tasks[index].updatedAt = Date()
        appendLog(at: index, "手动移至“\(stage.title)”。")
        scheduleSave(immediate: true)
        if stage == .completed {
            scheduleEligiblePlanningTasks()
        }
        return true
    }

    func updatePreferences(_ mutate: (inout BoardPreferences) -> Void) {
        mutate(&preferences)
        scheduleSave(immediate: true)
        scheduleExecutionQueue()
    }

    func revealProject(_ project: ProjectRecord) {
        guard isLocalHost(project.hostID), project.existsOnDisk else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
    }

    func revealAttachment(_ attachment: TaskAttachment, for task: BoardTask) {
        guard isLocalHost(task.hostID) else { return }
        let url = URL(fileURLWithPath: attachment.path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func deliveryArtifactURL(_ artifact: TaskDeliveryArtifact, for task: BoardTask) -> URL? {
        guard isLocalHost(task.hostID),
              let project = projects.first(where: { $0.id == task.projectID })
        else { return nil }
        let workspacePath = task.workspace.path.flatMap { path in
            FileManager.default.fileExists(atPath: path) ? path : nil
        }
        let baseURL = URL(fileURLWithPath: workspacePath ?? project.path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rawPath = artifact.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return nil }
        let candidate = (rawPath as NSString).isAbsolutePath
            ? URL(fileURLWithPath: rawPath)
            : baseURL.appendingPathComponent(rawPath)
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let baseComponents = baseURL.pathComponents
        let candidateComponents = resolved.pathComponents
        guard candidateComponents.count >= baseComponents.count,
              candidateComponents.prefix(baseComponents.count).elementsEqual(baseComponents),
              FileManager.default.fileExists(atPath: resolved.path)
        else { return nil }
        return resolved
    }

    func openDeliveryArtifact(_ artifact: TaskDeliveryArtifact, for task: BoardTask) {
        guard let url = deliveryArtifactURL(artifact, for: task) else { return }
        NSWorkspace.shared.open(url)
    }

    func revealDeliveryArtifact(_ artifact: TaskDeliveryArtifact, for task: BoardTask) {
        guard let url = deliveryArtifactURL(artifact, for: task) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealWorkspace(for task: BoardTask) {
        guard isLocalHost(task.hostID),
              let path = task.workspace.path,
              FileManager.default.fileExists(atPath: path)
        else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func cleanupWorktree(taskID: UUID) async {
        guard let index = taskIndex(taskID),
              !tasks[index].stage.isActive,
              tasks[index].workspace.kind == .worktree,
              let project = project(forTaskAt: index),
              let projectHost = host(for: tasks[index].hostID),
              worktreeCleanupInFlightTaskIDs.insert(taskID).inserted
        else { return }
        let configuration = tasks[index].workspace
        defer {
            worktreeCleanupInFlightTaskIDs.remove(taskID)
            schedulePlanningStartupWorker()
            scheduleExecutionQueue()
        }
        do {
            let cleaned = try await worktreeManager(for: projectHost).cleanup(
                taskID: taskID,
                projectPath: project.path,
                configuration: configuration,
                requiredCapability: .managedV1
            )
            guard let currentIndex = taskIndex(taskID),
                  !tasks[currentIndex].stage.isActive,
                  tasks[currentIndex].workspace == configuration
            else { return }
            tasks[currentIndex].workspace = cleaned
            appendLog(at: currentIndex, "独立 Worktree 已清理；任务分支仍保留。", level: .success)
            guard await saveImmediately() else {
                guard let failureIndex = taskIndex(taskID),
                      !tasks[failureIndex].stage.isActive,
                      tasks[failureIndex].workspace == cleaned
                else { return }
                tasks[failureIndex].lastError = "Worktree 已清理，但无法持久化清理结果；请勿立即退出应用。"
                appendLog(at: failureIndex, tasks[failureIndex].lastError ?? "持久化失败", level: .error)
                return
            }
        } catch {
            guard let currentIndex = taskIndex(taskID),
                  !tasks[currentIndex].stage.isActive,
                  tasks[currentIndex].workspace == configuration
            else { return }
            tasks[currentIndex].lastError = error.localizedDescription
            appendLog(at: currentIndex, error.localizedDescription, level: .error)
            scheduleSave(immediate: true)
        }
    }

    func openTaskInCodex(_ task: BoardTask) {
        guard isLocalHost(task.hostID),
              let threadID = task.threadID,
              let url = URL(string: "codex://thread/\(threadID)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func scheduleCapabilityRefresh(projectID: String, forceRefresh: Bool) {
        capabilityRefreshTask?.cancel()
        capabilityRefreshTask = Task { @MainActor [weak self] in
            guard let self, self.selectedProjectID == projectID else { return }
            await self.refreshModels(for: projectID)
            guard !Task.isCancelled, self.selectedProjectID == projectID else { return }
            await self.refreshCapabilities(projectID: projectID, forceRefresh: forceRefresh)
        }
    }

    private func loadAndConnect() async {
        var persistedActiveTaskIDs: [UUID] = []
        do {
            let snapshot = try await persistence.load()
            tasks = snapshot.tasks
            persistedActiveTaskIDs = tasks.filter { $0.stage.isActive }.map(\.id)
            hosts = snapshot.hosts
            manualProjects = snapshot.manualProjects
            hiddenProjectPaths = Set(snapshot.hiddenProjectPaths)
            preferences = snapshot.preferences
            for host in hosts where hostConnectionStates[host.id] == nil {
                hostConnectionStates[host.id] = .disconnected
            }
            let configuredHostIDs = Set(hosts.map(\.id))
            hostConnectionStates = hostConnectionStates.filter {
                configuredHostIDs.contains($0.key)
            }
        } catch {
            lastError = error.localizedDescription
        }
        await refreshSSHSuggestions()
        await refreshProjects()
        await reconcilePersistedActiveTasks(persistedActiveTaskIDs)
        normalizePendingRetriesAfterRestart()
        rebuildDurableAttentions()
        scheduleEligiblePlanningTasks()
        scheduleExecutionQueue()
    }

    private func enqueuePlanning(taskID: UUID) {
        if pendingPlanningTaskIDs.insert(taskID).inserted {
            planningStartupQueue.append(taskID)
        }
        schedulePlanningStartupWorker()
    }

    private func schedulePlanningStartupWorker() {
        guard planningStartupWorker == nil,
              planningStartupQueue.contains(where: {
                  !worktreeCleanupInFlightTaskIDs.contains($0)
              })
        else { return }
        planningStartupWorker = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  let queueIndex = self.planningStartupQueue.firstIndex(where: {
                      !self.worktreeCleanupInFlightTaskIDs.contains($0)
                  }) {
                let taskID = self.planningStartupQueue.remove(at: queueIndex)
                await self.performPlanningStart(taskID: taskID)
                self.pendingPlanningTaskIDs.remove(taskID)
                let waiters = self.planningStartupWaiters.removeValue(forKey: taskID) ?? []
                waiters.forEach { $0.resume() }
            }
            if Task.isCancelled {
                let remainingTaskIDs = self.planningStartupQueue
                self.planningStartupQueue.removeAll()
                for taskID in remainingTaskIDs {
                    self.pendingPlanningTaskIDs.remove(taskID)
                    let waiters = self.planningStartupWaiters.removeValue(forKey: taskID) ?? []
                    waiters.forEach { $0.resume() }
                }
            }
            self.planningStartupWorker = nil
            if self.planningStartupQueue.contains(where: {
                !self.worktreeCleanupInFlightTaskIDs.contains($0)
            }) {
                self.schedulePlanningStartupWorker()
            }
        }
    }

    private func scheduleEligiblePlanningTasks() {
        var updatedWaitingMessage = false
        for index in tasks.indices
        where tasks[index].stage == .inbox && blockingDependencyCount(for: tasks[index]) == 0 {
            if tasks[index].autoRun {
                enqueuePlanning(taskID: tasks[index].id)
            } else if tasks[index].liveMessage != "等待开始规划" {
                tasks[index].liveMessage = "等待开始规划"
                tasks[index].updatedAt = Date()
                updatedWaitingMessage = true
            }
        }
        if updatedWaitingMessage {
            scheduleSave()
        }
    }

    private func dependencyHandoffs(for task: BoardTask) -> [TaskDependencyHandoff] {
        dependencies(for: task).compactMap { dependency in
            guard dependency.stage == .completed else { return nil }
            let evidence = dependency.latestDeliveryEvidence
            let summary = evidence?.summary.nilIfBlank
                ?? dependency.latestExecutionRun?.summary.nilIfBlank
                ?? conciseRunSummary(TaskDeliveryEvidenceParser.humanReadableResult(from: dependency.resultText))
            return TaskDependencyHandoff(
                id: dependency.id,
                title: dependency.title,
                summary: summary,
                changedFiles: evidence?.changedFiles ?? [],
                testSummary: evidence?.testSummary ?? "",
                commitSHA: evidence?.commitSHA,
                pullRequestURL: evidence?.pullRequestURL
            )
        }
    }

    private func reconcilePersistedActiveTasks(_ taskIDs: [UUID]) async {
        for taskID in taskIDs {
            guard let index = taskIndex(taskID), tasks[index].stage.isActive else { continue }
            let taskSnapshot = tasks[index]
            let runPhase: TaskRunPhase = taskSnapshot.stage == .planning ? .planning : .execution
            let turnID = taskSnapshot.stage == .planning
                ? taskSnapshot.planningTurnID
                : taskSnapshot.executionTurnID
            let persistedRun = taskSnapshot.runs.last(where: {
                $0.phase == runPhase && $0.outcome.isActive
                    && ($0.turnID == turnID || $0.turnID == nil || turnID == nil)
            })
            if let persistedRun,
               persistedRun.multiAgentDrain?.cancellationRequestedAt != nil,
               turnID == nil {
                cancellationIntentTaskIDs.insert(taskID)
                failTask(
                    at: index,
                    message: "任务已停止。",
                    runOutcome: .interrupted,
                    kind: .interrupted,
                    automaticRetryAllowed: false
                )
                continue
            }
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

            if let persistedRun, let drain = persistedRun.multiAgentDrain {
                if drain.phase == .drained, let terminalStatus = drain.rootTerminalStatus {
                    finalizeDrainedTurn(
                        at: index,
                        turnID: turnID,
                        status: terminalStatus,
                        error: drain.rootTerminalError
                    )
                    continue
                }
                if drain.rootTerminalStatus != nil || drain.cancellationRequestedAt != nil {
                    scheduleDrainReconciliation(taskID: taskID, runID: persistedRun.id)
                    continue
                }
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
                restoreRunForConfirmedTurn(
                    at: currentIndex,
                    phase: runPhase,
                    turnID: turn.id
                )

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
                    if taskSnapshot.stage == .executing {
                        restoreExecutionRunForConfirmedTurn(
                            at: currentIndex,
                            turnID: turn.id
                        )
                    }
                    tasks[currentIndex].failureState = nil
                    resolveFailureAttention(taskID: taskID)
                    let resumed = try await hostClient.resumeThread(
                        threadID: threadID,
                        cwd: detail.summary.cwd
                    )
                    guard let resumedIndex = taskIndex(taskID) else { continue }
                    tasks[resumedIndex].sessionID = resumed.sessionID
                    tasks[resumedIndex].actualModel = resumed.model
                    if tasks[resumedIndex].requestedModel.isEmpty {
                        tasks[resumedIndex].requestedModel = resumed.model
                    }
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

    private func normalizePendingRetriesAfterRestart() {
        var changed = false
        for index in tasks.indices where tasks[index].failureState?.nextRetryAt != nil {
            tasks[index].failureState?.nextRetryAt = nil
            tasks[index].failureState?.circuitOpen = true
            tasks[index].liveMessage = "已熔断，等待人工处理"
            appendLog(at: index, "应用重启后未自动恢复失败重试；请先检查现场。", level: .warning)
            changed = true
        }
        if changed {
            scheduleSave()
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

    private func worktreeManager(for host: CodexHost) -> any WorktreeManaging {
        if let existing = worktreeManagers[host.id] { return existing }
        let manager = worktreeManagerFactory(host, clientForHost(host))
        worktreeManagers[host.id] = manager
        return manager
    }

    @discardableResult
    private func requireWorktreeCapability(
        taskID: UUID? = nil,
        executionRunID: UUID? = nil,
        project: ProjectRecord,
        host: CodexHost
    ) async throws -> WorktreeCapability {
        let taskSnapshot: WorktreeCapabilityTaskSnapshot?
        if let taskID, let executionRunID,
           let task = tasks.first(where: { $0.id == taskID }),
           let snapshot = WorktreeCapabilityTaskSnapshot(
               task: task,
               executionRunID: executionRunID
           ) {
            taskSnapshot = snapshot
        } else if taskID == nil, executionRunID == nil {
            taskSnapshot = nil
        } else {
            throw WorktreeManagerError.capabilityUnavailable(
                "能力探测已取消、过期，或项目归属已经变化。"
            )
        }

        guard isCurrentWorktreeCapabilityContext(
            project: project,
            host: host,
            taskSnapshot: taskSnapshot
        ) else {
            throw WorktreeManagerError.capabilityUnavailable(
                "能力探测已取消、过期，或项目归属已经变化。"
            )
        }
        let manager = worktreeManager(for: host)
        let availability = await manager.capability(
            projectPath: project.path,
            requiredCapability: .managedV1
        )
        guard !Task.isCancelled,
              isCurrentWorktreeCapabilityContext(
                  project: project,
                  host: host,
                  taskSnapshot: taskSnapshot
              )
        else {
            throw WorktreeManagerError.capabilityUnavailable(
                "能力探测已取消、过期，或项目归属已经变化。"
            )
        }
        switch availability {
        case let .supported(capability) where capability == .managedV1:
            return capability
        case let .supported(capability):
            throw WorktreeManagerError.capabilityMismatch(
                required: .managedV1,
                actual: capability
            )
        case let .unsupported(reason):
            throw WorktreeManagerError.capabilityUnsupported(reason)
        case let .unavailable(reason):
            throw WorktreeManagerError.capabilityUnavailable(reason)
        }
    }

    private func isCurrentWorktreeCapabilityContext(
        project: ProjectRecord,
        host: CodexHost,
        taskSnapshot: WorktreeCapabilityTaskSnapshot?
    ) -> Bool {
        guard host.id == project.hostID,
              host.isEnabled,
              project.path != "/",
              project.existsOnDisk,
              project.isGitRepository,
              let currentProject = projects.first(where: { $0.id == project.id }),
              currentProject.hostID == project.hostID,
              currentProject.path == project.path,
              currentProject.existsOnDisk,
              currentProject.isGitRepository,
              let currentHost = self.host(for: host.id),
              currentHost.isEnabled,
              currentHost.kind == host.kind,
              currentHost.sshAlias == host.sshAlias
        else { return false }

        guard let taskSnapshot else { return true }
        guard taskSnapshot.projectID == project.id,
              taskSnapshot.hostID == host.id,
              let currentTask = tasks.first(where: { $0.id == taskSnapshot.id })
        else { return false }
        return taskSnapshot.matches(currentTask)
    }

    private func beginWorktreeCapabilityProbe(projectID: String) -> UInt64 {
        let generation = (worktreeCapabilityProbeGenerationByProjectID[projectID] ?? 0) &+ 1
        worktreeCapabilityProbeGenerationByProjectID[projectID] = generation
        worktreeCapabilityProbingProjectIDs.insert(projectID)
        return generation
    }

    private func finishWorktreeCapabilityProbe(projectID: String, generation: UInt64) {
        guard worktreeCapabilityProbeGenerationByProjectID[projectID] == generation else { return }
        worktreeCapabilityProbingProjectIDs.remove(projectID)
    }

    private func publishWorktreeCapability(
        _ availability: WorktreeCapabilityAvailability,
        projectID: String,
        generation: UInt64
    ) -> WorktreeCapabilityAvailability? {
        guard !Task.isCancelled,
              worktreeCapabilityProbeGenerationByProjectID[projectID] == generation
        else { return nil }
        worktreeCapabilityAvailabilityByProjectID[projectID] = availability
        return availability
    }

    private func invalidateWorktreeCapabilities(for hostID: String) {
        let projectIDs = Set(projects.lazy.filter { $0.hostID == hostID }.map(\.id))
        for projectID in projectIDs {
            worktreeCapabilityProbeGenerationByProjectID[projectID, default: 0] &+= 1
        }
        worktreeCapabilityProbingProjectIDs.subtract(projectIDs)
        worktreeCapabilityAvailabilityByProjectID = worktreeCapabilityAvailabilityByProjectID.filter {
            !projectIDs.contains($0.key)
        }
        worktreeManagers.removeValue(forKey: hostID)
        if hostID == CodexHost.localID {
            worktreeManagers[hostID] = worktreeManager
        }
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
                ignoredPaths: managedWorktreePaths(for: host.id),
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
                ignoredPaths: managedWorktreePaths(for: host.id),
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
                ignoredPaths: managedWorktreePaths(for: host.id),
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
        switch (lhs.manualPriority, rhs.manualPriority) {
        case let (lhsPriority?, rhsPriority?) where lhsPriority != rhsPriority:
            return lhsPriority < rhsPriority
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }
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

    /*
     A completed root planning turn that is still draining reserves its place
     in the execution queue. This keeps resource ordering stable without
     moving the card out of its active phase before every descendant stops.
     */
    private func scheduleExecutionQueue() {
        let available = max(0, preferences.maxConcurrentExecutions - activeExecutionCount)
        guard available > 0 else { return }
        var activeByHost = Dictionary(grouping: tasks.filter { $0.stage == .executing }, by: \.hostID)
            .mapValues(\.count)
        var occupiedProjects = Set(
            tasks.lazy
                .filter {
                    $0.workspace.kind == .project
                        && ($0.stage == .executing
                            || ($0.stage == .needsAttention && $0.hasFinalPlan && $0.threadID != nil))
                }
                .map(\.projectID)
        )
        var queued: [Int] = []
        var reserved = 0
        let readyDemands = tasks.indices
            .filter {
                tasks[$0].stage == .awaitingApproval
                    && tasks[$0].executionApproved
                    && !cancellationIntentTaskIDs.contains(tasks[$0].id)
                    && !worktreeCleanupInFlightTaskIDs.contains(tasks[$0].id)
                    && tasks[$0].hasFinalPlan
                    && !tasks[$0].planText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .map {
                ExecutionSchedulingDemand(
                    taskIndex: $0,
                    isReady: true,
                    orderDate: tasks[$0].updatedAt
                )
            }
        let reservationDemands = tasks.indices.compactMap { index -> ExecutionSchedulingDemand? in
            guard tasks[index].stage == .planning,
                  tasks[index].autoRun,
                  !cancellationIntentTaskIDs.contains(tasks[index].id),
                  !worktreeCleanupInFlightTaskIDs.contains(tasks[index].id),
                  let run = tasks[index].runs.last(where: {
                      $0.phase == .planning && $0.outcome.isActive
                  }),
                  let drain = run.multiAgentDrain,
                  drain.phase == .draining,
                  drain.cancellationRequestedAt == nil,
                  tasks[index].hasFinalPlan,
                  !tasks[index].planText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  drain.rootTerminalStatus.map({ normalizedTurnStatus($0) == "completed" }) == true
            else { return nil }
            return ExecutionSchedulingDemand(
                taskIndex: index,
                isReady: false,
                orderDate: drain.rootTerminalObservedAt ?? tasks[index].updatedAt
            )
        }
        let demands = (readyDemands + reservationDemands).sorted { lhs, rhs in
            if lhs.orderDate != rhs.orderDate { return lhs.orderDate < rhs.orderDate }
            let lhsTask = tasks[lhs.taskIndex]
            let rhsTask = tasks[rhs.taskIndex]
            if lhsTask.createdAt != rhsTask.createdAt { return lhsTask.createdAt < rhsTask.createdAt }
            return lhs.taskIndex < rhs.taskIndex
        }
        for demand in demands {
            let index = demand.taskIndex
            guard queued.count + reserved < available else {
                if demand.isReady {
                    tasks[index].liveMessage = "等待可用执行槽位"
                }
                continue
            }
            guard let candidateHost = host(for: tasks[index].hostID), candidateHost.isEnabled else {
                if demand.isReady {
                    tasks[index].liveMessage = "等待任务主机恢复"
                }
                continue
            }
            guard activeByHost[candidateHost.id, default: 0] < candidateHost.maxConcurrentExecutions else {
                if demand.isReady {
                    tasks[index].liveMessage = "等待 \(candidateHost.name) 的执行槽位"
                }
                continue
            }
            if tasks[index].workspace.kind == .project {
                guard !occupiedProjects.contains(tasks[index].projectID) else {
                    if demand.isReady {
                        tasks[index].liveMessage = "等待同项目的主目录任务结束"
                    }
                    continue
                }
                occupiedProjects.insert(tasks[index].projectID)
            }
            activeByHost[candidateHost.id, default: 0] += 1
            if demand.isReady {
                queued.append(index)
            } else {
                reserved += 1
            }
        }
        for index in queued {
            let taskID = tasks[index].id
            tasks[index].stage = .executing
            tasks[index].liveMessage = "正在准备执行…"
            tasks[index].updatedAt = Date()
            appendLog(at: index, "开始执行已确认方案。")
            let runID = beginRun(at: index, phase: .execution)
            Task { @MainActor [weak self] in
                await self?.performExecution(taskID: taskID, runID: runID)
            }
        }
        scheduleSave()
    }

    private func performExecution(taskID: UUID, runID: UUID) async {
        discardPendingStreamUpdate(for: taskID)
        guard let index = taskIndex(taskID),
              let project = project(forTaskAt: index),
              let threadID = tasks[index].threadID
        else {
            if let index = taskIndex(taskID) {
                failTask(at: index, message: "缺少可恢复的 Codex thread。", kind: .workspace)
            }
            return
        }
        let taskSnapshot = tasks[index]
        guard let host = host(for: taskSnapshot.hostID), host.isEnabled else {
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
            if host.kind == .ssh, !taskSnapshot.attachments.isEmpty {
                throw BoardStoreError.remoteAttachmentsUnsupported
            }
            try await hostClient.connect()
            hostConnectionStates[host.id] = .connected
            guard let workspaceIndex = taskIndex(taskID),
                  tasks[workspaceIndex].stage == .executing,
                  tasks[workspaceIndex].runs.contains(where: {
                      $0.id == runID && $0.outcome.isActive
                  })
            else { return }

            if host.kind == .local {
                let executionAttachments = tasks[workspaceIndex].attachments
                try await attachmentStorage.validate(executionAttachments)
            }
            guard let preparationIndex = taskIndex(taskID),
                  tasks[preparationIndex].stage == .executing
            else { return }

            let executionPath: String
            if tasks[preparationIndex].workspace.kind == .worktree {
                let requiredCapability = try await requireWorktreeCapability(
                    taskID: taskID,
                    executionRunID: runID,
                    project: project,
                    host: host
                )
                guard let capabilityIndex = taskIndex(taskID),
                      tasks[capabilityIndex].stage == .executing
                else { return }
                let manager = worktreeManager(for: host)
                let preparedWorkspace = try await manager.prepare(
                    taskID: taskID,
                    projectPath: project.path,
                    configuration: tasks[capabilityIndex].workspace,
                    requiredCapability: requiredCapability
                )
                let preparedPath = try validatedPreparedWorktreePath(
                    preparedWorkspace,
                    taskID: taskID,
                    project: project,
                    host: host,
                    requiredCapability: requiredCapability
                )
                guard let preparedIndex = taskIndex(taskID) else { return }
                var canonicalWorkspace = preparedWorkspace
                canonicalWorkspace.path = preparedPath
                tasks[preparedIndex].workspace = canonicalWorkspace
                executionPath = preparedPath
                let preparedPolicy = taskRunPolicySnapshot(
                    for: tasks[preparedIndex],
                    phase: .execution,
                    cwd: preparedPath
                )
                updateRun(at: preparedIndex, runID: runID) { run in
                    run.policySnapshot = preparedPolicy
                }
                appendLog(
                    at: preparedIndex,
                    "使用独立 Worktree：\(preparedWorkspace.branch ?? executionPath)",
                    level: .success
                )
                guard await saveImmediately() else {
                    if let failureIndex = taskIndex(taskID) {
                        failTask(
                            at: failureIndex,
                            message: "Worktree 已创建但无法持久化其路径和来源证据；未恢复执行 thread。",
                            kind: .workspace
                        )
                        scheduleExecutionQueue()
                    }
                    return
                }
            } else {
                executionPath = project.path
            }

            guard let resumeIndex = taskIndex(taskID),
                  tasks[resumeIndex].stage == .executing,
                  tasks[resumeIndex].runs.contains(where: {
                      $0.id == runID && $0.outcome.isActive
                  })
            else { return }
            if cancellationIntentTaskIDs.contains(taskID) {
                failTask(
                    at: resumeIndex,
                    message: "任务已停止。",
                    runOutcome: .interrupted,
                    kind: .interrupted
                )
                scheduleExecutionQueue()
                return
            }
            let resumed = try await hostClient.resumeThread(threadID: threadID, cwd: executionPath)
            guard let currentIndex = taskIndex(taskID) else { return }
            tasks[currentIndex].sessionID = resumed.sessionID
            if tasks[currentIndex].requestedModel.isEmpty {
                tasks[currentIndex].requestedModel = resumed.model
            }
            tasks[currentIndex].actualModel = resumed.model
            tasks[currentIndex].resultText = ""
            tasks[currentIndex].liveMessage = "Codex 正在实施方案…"
            updateRun(at: currentIndex, runID: runID) { run in
                run.threadID = resumed.threadID
                run.sessionID = resumed.sessionID
                run.model = resumed.model
            }
            guard await saveImmediately() else {
                if let failureIndex = taskIndex(taskID) {
                    failTask(
                        at: failureIndex,
                        message: "无法持久化恢复后的 session；未启动执行 Turn。"
                    )
                    scheduleExecutionQueue()
                }
                return
            }
            guard let persistedSessionIndex = taskIndex(taskID),
                  tasks[persistedSessionIndex].stage == .executing,
                  tasks[persistedSessionIndex].runs.contains(where: {
                      $0.id == runID && $0.outcome.isActive
                  })
            else { return }
            let runtimeSafeApps = await runtimeSafeApps(
                selectedApps: tasks[persistedSessionIndex].selectedApps,
                taskID: taskID
            )
            guard let inputIndex = taskIndex(taskID),
                  tasks[inputIndex].stage == .executing
            else { return }
            if cancellationIntentTaskIDs.contains(taskID) {
                failTask(
                    at: inputIndex,
                    message: "任务已停止。",
                    runOutcome: .interrupted,
                    kind: .interrupted
                )
                scheduleExecutionQueue()
                return
            }
            let existingPolicy = tasks[inputIndex].runs
                .first(where: { $0.id == runID })?
                .policySnapshot
            let executionPolicy = existingPolicy ?? taskRunPolicySnapshot(
                for: tasks[inputIndex],
                phase: .execution,
                cwd: executionPath
            )
            if existingPolicy == nil {
                updateRun(at: inputIndex, runID: runID) { run in
                    run.policySnapshot = executionPolicy
                }
            }
            var runtimeTask = tasks[inputIndex]
            runtimeTask.selectedApps = runtimeSafeApps
            let input = TaskPromptBuilder.executionInput(
                for: runtimeTask,
                projectPath: executionPath,
                sourceProjectPath: project.path,
                pathSemantics: host.kind == .ssh ? .remote : .local
            )
            let executionModel = tasks[inputIndex].requestedModel
            let executionEffort = tasks[inputIndex].reasoningEffort
            let executionServiceTier = tasks[inputIndex].fastMode
                ? CodexServiceTier.fast
                : CodexServiceTier.standard
            let executionAllowsNetwork = executionPolicy.networkAccess
            guard await saveImmediately() else {
                if let failureIndex = taskIndex(taskID) {
                    failTask(
                        at: failureIndex,
                        message: "无法持久化执行运行策略；未启动执行 Turn。"
                    )
                    scheduleExecutionQueue()
                }
                return
            }
            guard let persistedIndex = taskIndex(taskID),
                  tasks[persistedIndex].stage == .executing,
                  tasks[persistedIndex].runs.contains(where: {
                      $0.id == runID && $0.outcome.isActive
                  })
            else { return }
            if cancellationIntentTaskIDs.contains(taskID) {
                failTask(
                    at: persistedIndex,
                    message: "任务已停止。",
                    runOutcome: .interrupted,
                    kind: .interrupted
                )
                scheduleExecutionQueue()
                return
            }
            let turn = try await hostClient.startExecutionTurn(
                threadID: threadID,
                cwd: executionPath,
                input: input,
                model: executionModel,
                effort: executionEffort,
                serviceTier: executionServiceTier,
                allowNetwork: executionAllowsNetwork
            )
            guard let finalIndex = taskIndex(taskID),
                  tasks[finalIndex].stage == .executing,
                  !cancellationIntentTaskIDs.contains(taskID)
            else {
                try? await hostClient.interrupt(threadID: threadID, turnID: turn.turnID)
                if let cancelledIndex = taskIndex(taskID),
                   tasks[cancelledIndex].stage == .executing {
                    failTask(
                        at: cancelledIndex,
                        message: "任务已停止。",
                        runOutcome: .interrupted,
                        kind: .interrupted
                    )
                    scheduleExecutionQueue()
                }
                return
            }
            tasks[finalIndex].executionTurnID = turn.turnID
            updateRun(at: finalIndex, runID: runID) { run in
                run.turnID = turn.turnID
            }
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
                if let worktreeError = error as? WorktreeManagerError,
                   case let .capturedStatePreserved(path, branch, _) = worktreeError,
                   tasks[failureIndex].workspace.kind == .worktree,
                   isOwnedWorktreeBranch(branch, taskID: taskID),
                   let normalizedPath = safeNormalizedWorktreePath(
                    path,
                    projectPath: project.path,
                    host: host
                   ) {
                    tasks[failureIndex].workspace.path = normalizedPath
                    tasks[failureIndex].workspace.branch = branch
                }
                let kind: TaskFailureKind = (error is WorktreeManagerError || error is BoardStoreError)
                    ? .workspace
                    : classifyFailure(error.localizedDescription)
                failTask(
                    at: failureIndex,
                    message: error.localizedDescription,
                    kind: kind,
                    retryPhase: .execution,
                    automaticRetryAllowed: !isAmbiguousLifecycleTimeout(error)
                )
                scheduleExecutionQueue()
            }
        }
    }

    private func validatedPreparedWorktreePath(
        _ workspace: TaskWorkspaceConfiguration,
        taskID: UUID,
        project: ProjectRecord,
        host: CodexHost,
        requiredCapability: WorktreeCapability
    ) throws -> String {
        guard workspace.kind == .worktree,
              let path = workspace.path,
              let branch = workspace.branch,
              let preparation = workspace.preparation,
              preparation.ownerTaskID == taskID,
              preparation.capability == requiredCapability,
              isGitObjectID(preparation.sourceCommit),
              isGitObjectID(preparation.baselineCommit),
              preparation.untrackedFilesCaptured >= 0
        else {
            throw WorktreeManagerError.invalidPreparationEvidence(
                "管理器未返回完整的 Worktree 路径、分支、所有权、能力或提交证据。"
            )
        }
        guard isOwnedWorktreeBranch(branch, taskID: taskID) else {
            throw WorktreeManagerError.invalidPreparationEvidence("管理器返回了不属于当前任务的分支。")
        }
        guard let normalizedRepository = normalizedWorkspacePath(
            preparation.repositoryPath,
            host: host
        ),
        let normalizedProject = normalizedWorkspacePath(project.path, host: host),
        normalizedRepository == normalizedProject else {
            throw WorktreeManagerError.invalidPreparationEvidence("管理器返回的源仓库证据不匹配。")
        }
        guard let normalizedPath = safeNormalizedWorktreePath(
            path,
            projectPath: project.path,
            host: host
        ) else {
            throw WorktreeManagerError.invalidManagedPath(path)
        }
        return normalizedPath
    }

    private func safeNormalizedWorktreePath(
        _ path: String,
        projectPath: String,
        host: CodexHost
    ) -> String? {
        guard !path.isEmpty,
              !path.contains("\0"),
              !path.unicodeScalars.contains(where: CharacterSet.newlines.contains),
              (path as NSString).isAbsolutePath,
              let normalizedPath = normalizedWorkspacePath(path, host: host),
              let normalizedProject = normalizedWorkspacePath(projectPath, host: host)
        else { return nil }
        let pathComponents = (normalizedPath as NSString).pathComponents
        let projectComponents = (normalizedProject as NSString).pathComponents
        let pathContainsProject = pathComponents.count <= projectComponents.count
            && projectComponents.prefix(pathComponents.count).elementsEqual(pathComponents)
        let projectContainsPath = projectComponents.count <= pathComponents.count
            && pathComponents.prefix(projectComponents.count).elementsEqual(projectComponents)
        guard normalizedPath != "/", !pathContainsProject, !projectContainsPath else {
            return nil
        }
        return normalizedPath
    }

    private func normalizedWorkspacePath(_ path: String, host: CodexHost) -> String? {
        guard !path.isEmpty,
              !path.contains("\0"),
              !path.unicodeScalars.contains(where: CharacterSet.newlines.contains),
              (path as NSString).isAbsolutePath
        else { return nil }
        if host.kind == .local {
            return URL(fileURLWithPath: path, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        }
        return (path as NSString).standardizingPath
    }

    private func ownedWorktreeBranch(taskID: UUID) -> String {
        "codex/task-\(taskID.uuidString.lowercased())"
    }

    private func isOwnedWorktreeBranch(_ branch: String, taskID: UUID) -> Bool {
        let fullBranch = ownedWorktreeBranch(taskID: taskID)
        let legacyBranch = "codex/task-\(taskID.uuidString.prefix(8).lowercased())"
        if branch == fullBranch || branch == legacyBranch { return true }
        let attemptPrefix = "\(fullBranch)-attempt-"
        guard branch.hasPrefix(attemptPrefix),
              let attempt = Int(branch.dropFirst(attemptPrefix.count)),
              attempt >= 2
        else { return false }
        return branch == "\(attemptPrefix)\(attempt)"
    }

    private func isGitObjectID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.unicodeScalars.allSatisfy { scalar in
                ("0" ... "9").contains(Character(scalar))
                    || ("a" ... "f").contains(Character(scalar))
                    || ("A" ... "F").contains(Character(scalar))
            }
    }

    private func handle(_ event: CodexEvent, hostID: String) {
        switch event {
        case let .agentDelta(threadID, turnID, delta):
            guard let index = taskIndex(threadID: threadID, turnID: turnID, hostID: hostID) else { return }
            let taskID = tasks[index].id
            if tasks[index].stage == .planning {
                pendingStreamUpdates[taskID, default: PendingStreamUpdate()].planDelta += delta
            } else if tasks[index].stage == .executing {
                pendingStreamUpdates[taskID, default: PendingStreamUpdate()].resultDelta += delta
            } else {
                return
            }
            scheduleStreamFlush()
        case let .turnDiffUpdated(threadID, turnID, diff):
            guard let index = taskIndex(threadID: threadID, turnID: turnID, hostID: hostID) else { return }
            let taskID = tasks[index].id
            pendingStreamUpdates[taskID, default: PendingStreamUpdate()].turnDiffID = turnID
            pendingStreamUpdates[taskID, default: PendingStreamUpdate()].turnDiff = diff
            scheduleStreamFlush()
        case let .agentFinal(threadID, turnID, text):
            flushPendingStreamUpdates()
            guard let index = taskIndex(threadID: threadID, turnID: turnID, hostID: hostID) else { return }
            if tasks[index].stage == .planning, tasks[index].planText.isEmpty {
                tasks[index].planText = text
            } else if tasks[index].stage == .executing {
                tasks[index].resultText = text
            }
            scheduleSave(immediate: true)
        case let .planFinal(threadID, turnID, text):
            flushPendingStreamUpdates()
            guard let index = taskIndex(threadID: threadID, turnID: turnID, hostID: hostID) else { return }
            tasks[index].planText = text
            tasks[index].hasFinalPlan = true
            scheduleSave(immediate: true)
            scheduleExecutionQueue()
        case let .planUpdated(threadID, turnID, explanation, steps):
            guard let index = taskIndex(threadID: threadID, turnID: turnID, hostID: hostID) else { return }
            tasks[index].structuredPlan = steps
            if let explanation, !explanation.isEmpty { tasks[index].liveMessage = explanation }
            scheduleSave()
        case let .activity(threadID, turnID, message):
            guard let index = taskIndex(threadID: threadID, turnID: turnID, hostID: hostID) else { return }
            pendingStreamUpdates[tasks[index].id, default: PendingStreamUpdate()].liveMessage = message
            scheduleStreamFlush()
        case let .configurationWarning(threadID, turnID, message):
            guard let threadID,
                  let index = taskIndex(threadID: threadID, turnID: turnID, hostID: hostID) else { return }
            appendLog(at: index, message, level: .warning)
            scheduleSave(immediate: true)
        case let .warning(threadID, turnID, message):
            guard let threadID,
                  let index = taskIndex(threadID: threadID, turnID: turnID, hostID: hostID) else {
                lastError = "\(hostName(for: hostID))：\(message)"
                return
            }
            appendLog(at: index, message, level: .warning)
            tasks[index].lastError = message
            scheduleSave(immediate: true)
        case let .turnCompleted(threadID, turnID, status, error):
            flushPendingStreamUpdates()
            guard let index = taskIndex(threadID: threadID, turnID: turnID, hostID: hostID) else { return }
            completeTurn(at: index, turnID: turnID, status: status, error: error)
        case let .threadStarted(summary):
            observeStartedSubagentThread(summary, hostID: hostID)
        case let .collabAgentToolCall(threadID, turnID, _, call):
            guard let location = runTelemetryLocation(
                hostID: hostID,
                sourceThreadID: threadID,
                sourceTurnID: turnID
            ) else { return }
            observeCollaborationCall(at: location, threadID: threadID, call: call)
        case let .subAgentActivity(threadID, turnID, lifecycle, activity):
            guard let location = runTelemetryLocation(
                hostID: hostID,
                sourceThreadID: threadID,
                sourceTurnID: turnID
            ) else { return }
            observeSubagentActivity(
                at: location,
                threadID: threadID,
                activity: activity
            )
            recordAgentActivity(
                at: location,
                sourceThreadID: threadID,
                sourceTurnID: turnID,
                lifecycle: lifecycle,
                activity: activity
            )
        case let .tokenUsageUpdated(threadID, turnID, usage):
            guard let location = runTelemetryLocation(
                hostID: hostID,
                sourceThreadID: threadID,
                sourceTurnID: turnID
            ) else { return }
            recordTokenUsage(
                at: location,
                threadID: threadID,
                turnID: turnID,
                usage: usage
            )
        case .threadStatus:
            break
        case let .interactionRequested(request):
            guard let index = taskIndex(
                threadID: request.threadID,
                turnID: request.turnID,
                hostID: hostID
            ),
                  tasks[index].stage.isActive
            else { return }
            let taskID = tasks[index].id
            var requests = pendingInteractionsByTaskID[taskID] ?? []
            let isNewRequest: Bool
            if let existingIndex = requests.firstIndex(where: { $0.id == request.id }) {
                requests[existingIndex] = request
                isNewRequest = false
            } else {
                requests.append(request)
                isNewRequest = true
            }
            pendingInteractionsByTaskID[taskID] = requests
            tasks[index].liveMessage = "等待人工确认"
            tasks[index].updatedAt = Date()
            if isNewRequest {
                addInteractionAttention(
                    taskID: taskID,
                    requestID: request.id,
                    createdAt: request.createdAt
                )
                focusTask(taskID)
            }
            scheduleSave()
        case let .interactionResolved(threadID, requestID):
            guard let taskID = tasks.first(where: {
                $0.hostID == hostID && $0.threadID == threadID
            })?.id else { return }
            removeInteraction(taskID: taskID, requestID: requestID)
            if let index = taskIndex(taskID), tasks[index].stage.isActive {
                tasks[index].liveMessage = hasPendingInteraction(for: taskID)
                    ? "Codex 仍在等待人工确认…"
                    : (tasks[index].stage == .planning ? "Codex 继续制定方案…" : "Codex 继续实施方案…")
                tasks[index].updatedAt = Date()
                scheduleSave()
            }
        case let .mcpOAuthCompleted(completion):
            setOAuthInProgress(
                false,
                key: HostServerKey(hostID: hostID, serverName: completion.serverName)
            )
            let selectedHostID = selectedTask?.hostID
                ?? selectedProject?.hostID
                ?? CodexHost.localID
            if completion.success {
                if selectedHostID == hostID {
                    mcpServerError = nil
                }
                Task { @MainActor [weak self] in
                    guard let self,
                          (self.selectedTask?.hostID
                              ?? self.selectedProject?.hostID
                              ?? CodexHost.localID) == hostID
                    else { return }
                    await self.refreshMCPServers()
                    if let projectID = self.selectedProjectID,
                       self.projects.first(where: { $0.id == projectID })?.hostID == hostID {
                        await self.refreshCapabilities(projectID: projectID, forceRefresh: true)
                    }
                }
            } else if selectedHostID == hostID {
                mcpServerError = completion.error?.nilIfBlank
                    ?? "\(completion.serverName) OAuth 授权失败。"
            }
        case let .connectionLost(message):
            flushPendingStreamUpdates()
            invalidateWorktreeCapabilities(for: hostID)
            hostConnectionStates[hostID] = .failed(message)
            accountReady = connectedHostCount > 0
            let affectedTaskIDs = Set(tasks.lazy.filter { $0.hostID == hostID }.map(\.id))
            respondingRequests = Set(respondingRequests.filter { $0.hostID != hostID })
            respondingRequestIDs = Set(respondingRequests.map(\.requestID))
            oauthRequestsInProgress = Set(oauthRequestsInProgress.filter { $0.hostID != hostID })
            oauthServersInProgress = Set(oauthRequestsInProgress.map(\.serverName))
            for taskID in affectedTaskIDs {
                clearInteractions(for: taskID)
            }
            for index in tasks.indices
                where tasks[index].hostID == hostID && tasks[index].stage.isActive {
                let phase: TaskRunPhase = tasks[index].stage == .planning ? .planning : .execution
                if let runIndex = tasks[index].runs.lastIndex(where: {
                    $0.phase == phase && $0.outcome.isActive && $0.multiAgentDrain != nil
                }), var drain = tasks[index].runs[runIndex].multiAgentDrain {
                    let failureMessage = "\(hostName(for: hostID)) 的 Codex 连接已断开：\(message) 子代理状态尚未确认。"
                    drain.phase = .blocked
                    drain.blockedReason = failureMessage
                    // A transport loss is already an externally confirmed
                    // blocker, not a single noisy reconciliation sample. Mark
                    // it at the durable attention threshold so restart rebuilds
                    // the same actionable notice until a readback succeeds.
                    drain.consecutiveReconciliationFailureCount = max(
                        3,
                        drain.consecutiveReconciliationFailureCount + 1
                    )
                    drain.stabilitySignature = nil
                    drain.stableObservationCount = 0
                    tasks[index].runs[runIndex].multiAgentDrain = drain
                    tasks[index].lastError = failureMessage
                    tasks[index].liveMessage = "连接已断开，任务保持占槽并等待重新对账"
                    tasks[index].updatedAt = Date()
                    addFailureAttention(
                        taskID: tasks[index].id,
                        runID: tasks[index].runs[runIndex].id,
                        createdAt: tasks[index].updatedAt
                    )
                    scheduleDrainReconciliation(
                        taskID: tasks[index].id,
                        runID: tasks[index].runs[runIndex].id,
                        after: .seconds(1)
                    )
                } else {
                    failTask(
                        at: index,
                        message: "\(hostName(for: hostID)) 的 Codex 连接已断开：\(message) 请检查工作区后再继续。",
                        kind: .connection
                    )
                }
            }
            scheduleSave(immediate: true)
            scheduleExecutionQueue()
        }
    }

    private func observeStartedSubagentThread(_ summary: CodexThreadSummary, hostID: String) {
        guard let parentThreadID = summary.parentThreadID,
              let location = drainEventLocation(
                  hostID: hostID,
                  candidateThreadIDs: [parentThreadID]
              )
        else { return }
        mergeDrainObservation(
            at: location.taskIndex,
            runIndex: location.runIndex,
            observedThreadIDs: [summary.id, parentThreadID],
            authoritativeParents: [summary.id: parentThreadID]
        )
    }

    private func observeCollaborationCall(
        at location: (taskIndex: Int, runIndex: Int),
        threadID: String,
        call: CodexCollabAgentToolCall
    ) {
        let candidates = Set([threadID, call.senderThreadID] + call.receiverThreadIDs)
        var spawnParents: [String: String] = [:]
        if call.tool == "spawnAgent" {
            for receiverThreadID in call.receiverThreadIDs {
                spawnParents[receiverThreadID] = call.senderThreadID
            }
        }
        mergeDrainObservation(
            at: location.taskIndex,
            runIndex: location.runIndex,
            observedThreadIDs: candidates,
            supplementalParents: spawnParents
        )
    }

    private func observeSubagentActivity(
        at location: (taskIndex: Int, runIndex: Int),
        threadID: String,
        activity: CodexSubAgentActivity
    ) {
        mergeDrainObservation(
            at: location.taskIndex,
            runIndex: location.runIndex,
            observedThreadIDs: [threadID, activity.agentThreadID]
        )
    }

    private func recordAgentActivity(
        at location: (taskIndex: Int, runIndex: Int),
        sourceThreadID: String,
        sourceTurnID: String,
        lifecycle: CodexItemLifecycle,
        activity: CodexSubAgentActivity
    ) {
        let timestamp: Date
        let startedAt: Date?
        let completedAt: Date?
        switch lifecycle {
        case let .started(atMilliseconds):
            timestamp = Date(timeIntervalSince1970: Double(atMilliseconds) / 1_000)
            startedAt = timestamp
            completedAt = nil
        case let .completed(atMilliseconds):
            timestamp = Date(timeIntervalSince1970: Double(atMilliseconds) / 1_000)
            startedAt = nil
            completedAt = timestamp
        }
        let record = TaskRunAgentActivity(
            id: TaskRunTelemetryReducer.activityID(
                sourceThreadID: sourceThreadID,
                sourceTurnID: sourceTurnID,
                protocolItemID: activity.id
            ),
            protocolItemID: activity.id,
            sourceThreadID: sourceThreadID,
            sourceTurnID: sourceTurnID,
            agentThreadID: activity.agentThreadID,
            agentPath: activity.agentPath,
            kind: activity.kind,
            startedAt: startedAt,
            completedAt: completedAt
        )
        let reducer = TaskRunTelemetryReducer()
        tasks[location.taskIndex].runs[location.runIndex].telemetry = reducer.recording(
            record,
            in: tasks[location.taskIndex].runs[location.runIndex].telemetry
        )
        scheduleSave()
    }

    private func recordTokenUsage(
        at location: (taskIndex: Int, runIndex: Int),
        threadID: String,
        turnID: String,
        usage: CodexThreadTokenUsage
    ) {
        let snapshot = TaskRunThreadTokenUsageSnapshot(
            threadID: threadID,
            turnID: turnID,
            receivedAt: Date(),
            total: taskRunTokenUsage(usage.total),
            last: taskRunTokenUsage(usage.last),
            modelContextWindow: usage.modelContextWindow
        )
        let reducer = TaskRunTelemetryReducer()
        tasks[location.taskIndex].runs[location.runIndex].telemetry = reducer.recording(
            snapshot,
            in: tasks[location.taskIndex].runs[location.runIndex].telemetry
        )
        scheduleSave()
    }

    private func taskRunTokenUsage(
        _ usage: CodexTokenUsageBreakdown
    ) -> TaskRunTokenUsageBreakdown {
        TaskRunTokenUsageBreakdown(
            totalTokens: usage.totalTokens,
            inputTokens: usage.inputTokens,
            cachedInputTokens: usage.cachedInputTokens,
            cacheWriteInputTokens: usage.cacheWriteInputTokens,
            outputTokens: usage.outputTokens,
            reasoningOutputTokens: usage.reasoningOutputTokens
        )
    }

    private func runTelemetryLocation(
        hostID: String,
        sourceThreadID: String,
        sourceTurnID: String
    ) -> (taskIndex: Int, runIndex: Int)? {
        guard !sourceThreadID.isEmpty, !sourceTurnID.isEmpty else { return nil }
        var matches: [(taskIndex: Int, runIndex: Int)] = []
        for taskIndex in tasks.indices
        where tasks[taskIndex].hostID == hostID && tasks[taskIndex].stage.isActive {
            let phase: TaskRunPhase = tasks[taskIndex].stage == .planning ? .planning : .execution
            guard let runIndex = tasks[taskIndex].runs.lastIndex(where: {
                $0.phase == phase && $0.outcome.isActive
            }) else { continue }
            let run = tasks[taskIndex].runs[runIndex]
            let rootThreadID = run.threadID ?? tasks[taskIndex].threadID
            if rootThreadID == sourceThreadID {
                if run.turnID == sourceTurnID {
                    matches.append((taskIndex, runIndex))
                }
                continue
            }
            guard run.multiAgentDrain?.knownThreadIDs.contains(sourceThreadID) == true,
                  runHasObservedTurn(
                      run,
                      threadID: sourceThreadID,
                      turnID: sourceTurnID
                  )
            else { continue }
            matches.append((taskIndex, runIndex))
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private func runHasObservedTurn(
        _ run: TaskRun,
        threadID: String,
        turnID: String
    ) -> Bool {
        if run.multiAgentDrain?.activeTurns.contains(where: {
            $0.threadID == threadID && $0.turnID == turnID
        }) == true {
            return true
        }
        if run.telemetry?.tokenUsageByThread.contains(where: {
            $0.threadID == threadID && $0.turnID == turnID
        }) == true {
            return true
        }
        if run.telemetry?.agentActivities.contains(where: {
            $0.sourceThreadID == threadID && $0.sourceTurnID == turnID
        }) == true {
            return true
        }
        return false
    }

    private func drainEventLocation(
        hostID: String,
        candidateThreadIDs: Set<String>
    ) -> (taskIndex: Int, runIndex: Int)? {
        var matches: [(taskIndex: Int, runIndex: Int)] = []
        for taskIndex in tasks.indices
        where tasks[taskIndex].hostID == hostID && tasks[taskIndex].stage.isActive {
            let phase: TaskRunPhase = tasks[taskIndex].stage == .planning ? .planning : .execution
            guard let runIndex = tasks[taskIndex].runs.lastIndex(where: {
                $0.phase == phase && $0.outcome.isActive
            }) else { continue }
            let run = tasks[taskIndex].runs[runIndex]
            var ownedThreadIDs = Set(run.multiAgentDrain?.knownThreadIDs ?? [])
            if let rootThreadID = run.threadID ?? tasks[taskIndex].threadID {
                ownedThreadIDs.insert(rootThreadID)
            }
            if !ownedThreadIDs.isDisjoint(with: candidateThreadIDs) {
                matches.append((taskIndex, runIndex))
            }
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private func mergeDrainObservation(
        at taskIndex: Int,
        runIndex: Int,
        observedThreadIDs: Set<String>,
        authoritativeParents: [String: String] = [:],
        supplementalParents: [String: String] = [:]
    ) {
        let now = Date()
        let runID = tasks[taskIndex].runs[runIndex].id
        let rootThreadID = tasks[taskIndex].runs[runIndex].threadID ?? tasks[taskIndex].threadID
        var drain = tasks[taskIndex].runs[runIndex].multiAgentDrain ?? TaskRunDrainState(
            phase: .observing,
            knownThreadIDs: rootThreadID.map { [$0] } ?? [],
            startedAt: now
        )
        let previousThreadIDs = Set(drain.knownThreadIDs)
        let previousParents = drain.parentByThreadID
        var mergedThreadIDs = previousThreadIDs
        mergedThreadIDs.formUnion(observedThreadIDs.filter { !$0.isEmpty })
        if let rootThreadID { mergedThreadIDs.insert(rootThreadID) }
        for (childThreadID, parentThreadID) in supplementalParents
        where drain.parentByThreadID[childThreadID] == nil {
            drain.parentByThreadID[childThreadID] = parentThreadID
        }
        for (childThreadID, parentThreadID) in authoritativeParents {
            drain.parentByThreadID[childThreadID] = parentThreadID
        }
        drain.knownThreadIDs = mergedThreadIDs.sorted()

        let changed = previousThreadIDs != mergedThreadIDs || previousParents != drain.parentByThreadID
        guard changed else { return }
        drain.stabilitySignature = nil
        drain.stableObservationCount = 0
        if drain.rootTerminalStatus != nil {
            drain.phase = drain.cancellationRequestedAt != nil
                || cancellationIntentTaskIDs.contains(tasks[taskIndex].id)
                || drain.rootTerminalStatus.map { normalizedTurnStatus($0) != "completed" } == true
                ? .cancelling
                : .draining
        }
        tasks[taskIndex].runs[runIndex].multiAgentDrain = drain
        tasks[taskIndex].updatedAt = now
        scheduleSave()
        if drain.rootTerminalStatus != nil || drain.cancellationRequestedAt != nil {
            scheduleDrainReconciliation(taskID: tasks[taskIndex].id, runID: runID)
        }
    }

    private func scheduleDrainReconciliation(
        taskID: UUID,
        runID: UUID,
        after delay: Duration = .zero
    ) {
        guard drainTasksByRunID[runID] == nil else { return }
        drainTasksByRunID[runID] = Task { @MainActor [weak self] in
            if delay > .zero {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, let self else { return }
            let action = await self.reconcileMultiAgentDrain(taskID: taskID, runID: runID)
            self.drainTasksByRunID[runID] = nil
            if case let .retry(nextDelay) = action {
                self.scheduleDrainReconciliation(taskID: taskID, runID: runID, after: nextDelay)
            }
        }
    }

    private func reconcileMultiAgentDrain(
        taskID: UUID,
        runID: UUID
    ) async -> DrainReconciliationAction {
        guard let location = activeDrainLocation(taskID: taskID, runID: runID) else { return .stop }
        guard await saveImmediately() else {
            return recordDrainReconciliationFailure(
                taskID: taskID,
                runID: runID,
                message: "无法持久化子代理排空状态；尚未执行远端对账。"
            )
        }

        let taskSnapshot = tasks[location.taskIndex]
        guard let rootThreadID = taskSnapshot.runs[location.runIndex].threadID ?? taskSnapshot.threadID,
              let rootTurnID = taskSnapshot.runs[location.runIndex].turnID,
              let host = host(for: taskSnapshot.hostID),
              host.isEnabled
        else {
            return recordDrainReconciliationFailure(
                taskID: taskID,
                runID: runID,
                message: "缺少根 Thread/Turn 或任务主机不可用，无法核对子代理。"
            )
        }

        let hostClient = clientForHost(host)
        let listedDescendants: [CodexThreadSummary]
        do {
            try await hostClient.connect()
            hostConnectionStates[host.id] = .connected
            listedDescendants = try await hostClient.listDescendantThreads(
                ancestorThreadID: rootThreadID
            )
        } catch {
            reflectTransportState(of: hostClient, for: host, fallbackError: error)
            return recordDrainReconciliationFailure(
                taskID: taskID,
                runID: runID,
                message: "列出子代理 Thread 失败：\(error.localizedDescription)"
            )
        }

        guard let refreshedLocation = activeDrainLocation(taskID: taskID, runID: runID),
              let drain = tasks[refreshedLocation.taskIndex].runs[refreshedLocation.runIndex].multiAgentDrain
        else { return .stop }
        let observationBaseline = drain
        var candidateThreadIDs = Set(drain.knownThreadIDs)
        candidateThreadIDs.insert(rootThreadID)
        candidateThreadIDs.formUnion(listedDescendants.map(\.id))
        guard candidateThreadIDs.count <= drainCoordinator.maximumNodeCount else {
            return recordDrainReconciliationFailure(
                taskID: taskID,
                runID: runID,
                message: "子代理图包含 \(candidateThreadIDs.count) 个节点，超过安全上限 \(drainCoordinator.maximumNodeCount)。"
            )
        }

        if drain.rootTerminalStatus != nil,
           candidateThreadIDs == [rootThreadID],
           listedDescendants.isEmpty {
            return await reconcileEmptyDescendantFixedPoint(
                taskID: taskID,
                runID: runID,
                rootThreadID: rootThreadID,
                rootTurnID: rootTurnID
            )
        }

        var threadDetails: [CodexThreadDetail] = []
        do {
            for threadID in candidateThreadIDs.sorted() {
                threadDetails.append(try await hostClient.readThread(
                    threadID: threadID,
                    includeTurns: true
                ))
            }
        } catch {
            return recordDrainReconciliationFailure(
                taskID: taskID,
                runID: runID,
                message: "读取子代理 Thread 失败：\(error.localizedDescription)"
            )
        }

        guard let currentLocation = activeDrainLocation(taskID: taskID, runID: runID),
              var currentDrain = tasks[currentLocation.taskIndex].runs[currentLocation.runIndex].multiAgentDrain
        else { return .stop }
        guard currentDrain == observationBaseline else {
            return .retry(after: drainStabilityDelay)
        }
        if currentDrain.rootTerminalStatus == nil {
            guard let rootDetail = threadDetails.first(where: { $0.summary.id == rootThreadID }),
                  let rootTurn = rootDetail.turns.first(where: { $0.id == rootTurnID })
            else {
                return recordDrainReconciliationFailure(
                    taskID: taskID,
                    runID: runID,
                    message: "thread/read 未返回正在取消的根 Turn \(shortID(rootTurnID))。"
                )
            }
            switch normalizedTurnStatus(rootTurn.status) {
            case "completed", "failed", "interrupted", "cancelled", "canceled":
                currentDrain.rootTerminalStatus = rootTurn.status
                currentDrain.rootTerminalError = rootTurn.error
                currentDrain.rootTerminalObservedAt = Date()
            default:
                break
            }
        }

        let snapshot = drainCoordinator.makeSnapshot(
            rootThreadID: rootThreadID,
            threadDetails: threadDetails,
            knownThreadIDs: candidateThreadIDs
        )
        currentDrain.knownThreadIDs = snapshot.observedThreadIDs
        currentDrain.parentByThreadID = snapshot.parentByThreadID
        currentDrain.activeTurns = snapshot.activeTurns.map {
            TaskRunDrainTurnReference(threadID: $0.threadID, turnID: $0.turnID)
        }
        currentDrain.lastReconciledAt = Date()

        if let blocker = snapshot.blockedReason {
            currentDrain.phase = .blocked
            currentDrain.blockedReason = blocker.description
            currentDrain.stabilitySignature = nil
            currentDrain.stableObservationCount = 0
            currentDrain.consecutiveReconciliationFailureCount += 1
            applyDrainState(
                currentDrain,
                taskID: taskID,
                runID: runID,
                liveMessage: "子代理状态无法安全确认"
            )
            if currentDrain.consecutiveReconciliationFailureCount >= 3,
               let blockedLocation = activeDrainLocation(taskID: taskID, runID: runID) {
                addFailureAttention(
                    taskID: taskID,
                    runID: runID,
                    createdAt: tasks[blockedLocation.taskIndex].updatedAt
                )
            }
            _ = await saveImmediately()
            return .retry(after: .seconds(2))
        }

        currentDrain.blockedReason = nil
        currentDrain.consecutiveReconciliationFailureCount = 0
        let isCancelling = currentDrain.cancellationRequestedAt != nil
            || cancellationIntentTaskIDs.contains(taskID)
            || currentDrain.rootTerminalStatus.map { normalizedTurnStatus($0) != "completed" } == true

        if snapshot.isDrained {
            let stableCount = currentDrain.stabilitySignature == snapshot.stabilitySignature
                ? currentDrain.stableObservationCount + 1
                : 1
            currentDrain.stabilitySignature = snapshot.stabilitySignature
            currentDrain.stableObservationCount = stableCount
            currentDrain.phase = stableCount >= 2 ? .drained : (isCancelling ? .cancelling : .draining)
            applyDrainState(
                currentDrain,
                taskID: taskID,
                runID: runID,
                liveMessage: stableCount >= 2 ? "子代理已全部停止" : "正在确认子代理图已稳定…"
            )
            guard await saveImmediately() else {
                return recordDrainReconciliationFailure(
                    taskID: taskID,
                    runID: runID,
                    message: "子代理已排空，但最终状态无法持久化。"
                )
            }
            guard let savedLocation = activeDrainLocation(taskID: taskID, runID: runID),
                  tasks[savedLocation.taskIndex].runs[savedLocation.runIndex].multiAgentDrain == currentDrain
            else {
                return activeDrainLocation(taskID: taskID, runID: runID) == nil
                    ? .stop
                    : .retry(after: drainStabilityDelay)
            }
            guard stableCount >= 2 else { return .retry(after: drainStabilityDelay) }
            return finalizePersistedDrain(
                taskID: taskID,
                runID: runID,
                rootThreadID: rootThreadID,
                rootTurnID: rootTurnID
            )
        }

        currentDrain.phase = isCancelling ? .cancelling : .draining
        currentDrain.stabilitySignature = snapshot.stabilitySignature
        currentDrain.stableObservationCount = 0
        let activeCount = snapshot.activeTurns.count + snapshot.pendingThreadIDs.count
        applyDrainState(
            currentDrain,
            taskID: taskID,
            runID: runID,
            liveMessage: isCancelling
                ? "正在停止并核对 \(activeCount) 个活动子代理…"
                : "正在等待 \(activeCount) 个活动子代理…"
        )
        resolveFailureAttention(taskID: taskID)
        guard await saveImmediately() else {
            return recordDrainReconciliationFailure(
                taskID: taskID,
                runID: runID,
                message: "无法持久化最新子代理状态；未发送中断请求。"
            )
        }
        if isCancelling, !snapshot.activeTurns.isEmpty {
            await interruptDrainTurns(
                snapshot.activeTurns,
                parentByThreadID: snapshot.parentByThreadID,
                rootThreadID: rootThreadID,
                client: hostClient
            )
        }
        return .retry(after: drainStabilityDelay)
    }

    private func reconcileEmptyDescendantFixedPoint(
        taskID: UUID,
        runID: UUID,
        rootThreadID: String,
        rootTurnID: String
    ) async -> DrainReconciliationAction {
        guard let location = activeDrainLocation(taskID: taskID, runID: runID),
              var drain = tasks[location.taskIndex].runs[location.runIndex].multiAgentDrain,
              let terminalStatus = drain.rootTerminalStatus
        else { return .stop }
        let signature = "empty|\(rootThreadID)|\(rootTurnID)|\(terminalStatus)"
        drain.stableObservationCount = drain.stabilitySignature == signature
            ? drain.stableObservationCount + 1
            : 1
        drain.stabilitySignature = signature
        drain.activeTurns = []
        drain.parentByThreadID = [:]
        drain.knownThreadIDs = [rootThreadID]
        drain.lastReconciledAt = Date()
        drain.blockedReason = nil
        drain.consecutiveReconciliationFailureCount = 0
        drain.phase = drain.stableObservationCount >= 2
            ? .drained
            : (drain.cancellationRequestedAt != nil
                || normalizedTurnStatus(terminalStatus) != "completed"
                ? .cancelling
                : .draining)
        applyDrainState(
            drain,
            taskID: taskID,
            runID: runID,
            liveMessage: drain.stableObservationCount >= 2
                ? "未发现活动子代理"
                : "正在确认没有遗漏的子代理…"
        )
        guard await saveImmediately() else {
            return recordDrainReconciliationFailure(
                taskID: taskID,
                runID: runID,
                message: "空子代理图已确认，但状态无法持久化。"
            )
        }
        guard let savedLocation = activeDrainLocation(taskID: taskID, runID: runID),
              tasks[savedLocation.taskIndex].runs[savedLocation.runIndex].multiAgentDrain == drain
        else {
            return activeDrainLocation(taskID: taskID, runID: runID) == nil
                ? .stop
                : .retry(after: drainStabilityDelay)
        }
        guard drain.stableObservationCount >= 2 else {
            return .retry(after: drainStabilityDelay)
        }
        return finalizePersistedDrain(
            taskID: taskID,
            runID: runID,
            rootThreadID: rootThreadID,
            rootTurnID: rootTurnID
        )
    }

    private func interruptDrainTurns(
        _ activeTurns: [MultiAgentDrainActiveTurn],
        parentByThreadID: [String: String],
        rootThreadID: String,
        client: any CodexTaskClient
    ) async {
        let orderedTurns = activeTurns.sorted { lhs, rhs in
            let lhsDepth = drainDepth(
                threadID: lhs.threadID,
                rootThreadID: rootThreadID,
                parentByThreadID: parentByThreadID
            )
            let rhsDepth = drainDepth(
                threadID: rhs.threadID,
                rootThreadID: rootThreadID,
                parentByThreadID: parentByThreadID
            )
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            if lhs.threadID != rhs.threadID { return lhs.threadID < rhs.threadID }
            return lhs.turnID < rhs.turnID
        }
        for turn in orderedTurns {
            do {
                try await client.interrupt(threadID: turn.threadID, turnID: turn.turnID)
            } catch {
                // A rejected interrupt may race with natural completion. The
                // mandatory readback below, not the RPC result, is authoritative.
            }
            _ = try? await client.readThread(threadID: turn.threadID, includeTurns: true)
        }
    }

    private func drainDepth(
        threadID: String,
        rootThreadID: String,
        parentByThreadID: [String: String]
    ) -> Int {
        var depth = 0
        var current = threadID
        var visited = Set<String>()
        while current != rootThreadID,
              visited.insert(current).inserted,
              let parent = parentByThreadID[current] {
            depth += 1
            current = parent
        }
        return current == rootThreadID ? depth : Int.max
    }

    private func finalizePersistedDrain(
        taskID: UUID,
        runID: UUID,
        rootThreadID: String,
        rootTurnID: String
    ) -> DrainReconciliationAction {
        guard let location = activeDrainLocation(taskID: taskID, runID: runID),
              let drain = tasks[location.taskIndex].runs[location.runIndex].multiAgentDrain,
              drain.phase == .drained,
              (tasks[location.taskIndex].runs[location.runIndex].threadID
                  ?? tasks[location.taskIndex].threadID) == rootThreadID,
              tasks[location.taskIndex].runs[location.runIndex].turnID == rootTurnID,
              let terminalStatus = drain.rootTerminalStatus
        else { return .stop }
        finalizeDrainedTurn(
            at: location.taskIndex,
            turnID: rootTurnID,
            status: terminalStatus,
            error: drain.rootTerminalError
        )
        return .stop
    }

    private func activeDrainLocation(
        taskID: UUID,
        runID: UUID
    ) -> (taskIndex: Int, runIndex: Int)? {
        guard let taskIndex = taskIndex(taskID), tasks[taskIndex].stage.isActive,
              let runIndex = tasks[taskIndex].runs.firstIndex(where: {
                  $0.id == runID && $0.outcome.isActive && $0.multiAgentDrain != nil
              })
        else { return nil }
        return (taskIndex, runIndex)
    }

    private func applyDrainState(
        _ drain: TaskRunDrainState,
        taskID: UUID,
        runID: UUID,
        liveMessage: String
    ) {
        guard let location = activeDrainLocation(taskID: taskID, runID: runID) else { return }
        tasks[location.taskIndex].runs[location.runIndex].multiAgentDrain = drain
        tasks[location.taskIndex].liveMessage = liveMessage
        tasks[location.taskIndex].lastError = drain.blockedReason
        tasks[location.taskIndex].updatedAt = Date()
        scheduleSave(immediate: true)
    }

    private func recordDrainReconciliationFailure(
        taskID: UUID,
        runID: UUID,
        message: String
    ) -> DrainReconciliationAction {
        guard let location = activeDrainLocation(taskID: taskID, runID: runID),
              var drain = tasks[location.taskIndex].runs[location.runIndex].multiAgentDrain
        else { return .stop }
        drain.phase = .blocked
        drain.blockedReason = message
        drain.consecutiveReconciliationFailureCount += 1
        drain.stabilitySignature = nil
        drain.stableObservationCount = 0
        applyDrainState(
            drain,
            taskID: taskID,
            runID: runID,
            liveMessage: "子代理排空暂时受阻，将继续重试"
        )
        if drain.consecutiveReconciliationFailureCount >= 3 {
            addFailureAttention(taskID: taskID, runID: runID, createdAt: Date())
        }
        return .retry(after: drain.consecutiveReconciliationFailureCount >= 3 ? .seconds(5) : .seconds(1))
    }

    private func completeTurn(at index: Int, turnID: String, status: String, error: String?) {
        let phase: TaskRunPhase
        switch tasks[index].stage {
        case .planning:
            guard tasks[index].planningTurnID == nil || tasks[index].planningTurnID == turnID else { return }
            phase = .planning
        case .executing:
            guard tasks[index].planningTurnID != turnID else { return }
            guard tasks[index].executionTurnID == nil || tasks[index].executionTurnID == turnID else { return }
            phase = .execution
        default:
            return
        }

        guard let runIndex = tasks[index].runs.lastIndex(where: {
            $0.phase == phase && $0.outcome.isActive && ($0.turnID == nil || $0.turnID == turnID)
        }) else { return }
        let now = Date()
        let rootThreadID = tasks[index].runs[runIndex].threadID ?? tasks[index].threadID
        guard let rootThreadID else {
            tasks[index].lastError = "主代理已结束，但缺少可用于排空子代理的根 Thread。"
            tasks[index].liveMessage = "无法确认子代理是否已停止"
            tasks[index].updatedAt = now
            scheduleSave(immediate: true)
            return
        }

        tasks[index].runs[runIndex].threadID = rootThreadID
        tasks[index].runs[runIndex].turnID = turnID
        var drain = tasks[index].runs[runIndex].multiAgentDrain ?? TaskRunDrainState(
            phase: .observing,
            knownThreadIDs: [rootThreadID],
            startedAt: now
        )
        if let recordedStatus = drain.rootTerminalStatus,
           normalizedTurnStatus(recordedStatus) != normalizedTurnStatus(status) {
            drain.phase = .blocked
            drain.blockedReason = "根 Turn 收到冲突终态：\(recordedStatus) / \(status)"
            drain.consecutiveReconciliationFailureCount += 1
            tasks[index].runs[runIndex].multiAgentDrain = drain
            tasks[index].lastError = drain.blockedReason
            tasks[index].liveMessage = "根 Turn 终态冲突，已停止自动收口"
            tasks[index].updatedAt = now
            addFailureAttention(taskID: tasks[index].id, runID: tasks[index].runs[runIndex].id, createdAt: now)
            scheduleSave(immediate: true)
            return
        }

        drain.rootTerminalStatus = status
        if drain.rootTerminalError == nil { drain.rootTerminalError = error }
        if drain.rootTerminalObservedAt == nil { drain.rootTerminalObservedAt = now }
        drain.knownThreadIDs = Array(Set(drain.knownThreadIDs + [rootThreadID])).sorted()
        if drain.cancellationRequestedAt != nil
            || cancellationIntentTaskIDs.contains(tasks[index].id)
            || normalizedTurnStatus(status) != "completed" {
            drain.phase = .cancelling
        } else {
            drain.phase = .draining
        }
        drain.blockedReason = nil
        tasks[index].runs[runIndex].multiAgentDrain = drain
        tasks[index].liveMessage = drain.phase == .cancelling
            ? "主代理已结束，正在停止并核对子代理…"
            : "主代理已结束，正在核对子代理…"
        tasks[index].updatedAt = now
        scheduleSave(immediate: true)
        scheduleDrainReconciliation(taskID: tasks[index].id, runID: tasks[index].runs[runIndex].id)
    }

    private func finalizeDrainedTurn(at index: Int, turnID: String, status: String, error: String?) {
        let isPlanning: Bool
        switch tasks[index].stage {
        case .planning:
            guard tasks[index].planningTurnID == nil || tasks[index].planningTurnID == turnID else { return }
            isPlanning = true
        case .executing:
            guard tasks[index].planningTurnID != turnID else { return }
            guard tasks[index].executionTurnID == nil || tasks[index].executionTurnID == turnID else { return }
            isPlanning = false
        default:
            // App-server notifications may be replayed. A completed turn must
            // never move an already-settled card back into an active workflow.
            return
        }
        let persistedCancellationRequested = tasks[index].runs.last(where: {
            $0.outcome.isActive && $0.turnID == turnID
        })?.multiAgentDrain?.cancellationRequestedAt != nil
        clearInteractions(for: tasks[index].id, turnID: turnID)
        if cancellationIntentTaskIDs.contains(tasks[index].id) || persistedCancellationRequested {
            failTask(
                at: index,
                message: "任务已停止。",
                runOutcome: .interrupted,
                kind: .interrupted
            )
            scheduleExecutionQueue()
            return
        }
        let normalizedStatus = normalizedTurnStatus(status)
        guard normalizedStatus == "completed" else {
            let wasInterrupted = ["interrupted", "cancelled", "canceled"].contains(normalizedStatus)
            let reason = error ?? (wasInterrupted ? "任务已停止。" : "Codex turn 状态：\(status)")
            failTask(
                at: index,
                message: reason,
                runOutcome: wasInterrupted ? .interrupted : .failed,
                kind: wasInterrupted ? .interrupted : .execution
            )
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
                failTask(
                    at: index,
                    message: "规划轮已结束，但没有收到可确认的最终方案。",
                    kind: .execution
                )
                scheduleExecutionQueue()
                return
            }
            let completedAt = tasks[index].runs.last(where: {
                $0.phase == .planning && $0.outcome.isActive
            })?.multiAgentDrain?.rootTerminalObservedAt ?? Date()
            finishActiveRun(
                at: index,
                phase: .planning,
                outcome: .completed,
                summary: tasks[index].planText
            )
            resolveFailureAttention(taskID: tasks[index].id)
            tasks[index].stage = .awaitingApproval
            tasks[index].failureState = nil
            tasks[index].executionApproved = tasks[index].autoRun
            tasks[index].liveMessage = tasks[index].autoRun ? "方案完成，已进入自动执行队列" : "方案完成，等待确认"
            appendLog(at: index, tasks[index].autoRun ? "方案完成；全自动模式已跳过确认。" : "方案已生成，等待确认。", level: .success)
            tasks[index].updatedAt = completedAt
            if !tasks[index].autoRun {
                addPlanAttention(taskID: tasks[index].id, createdAt: completedAt)
                focusTask(tasks[index].id)
            }
            scheduleSave(immediate: true)
            scheduleExecutionQueue()
        } else {
            let evidence = TaskDeliveryEvidenceParser.parse(from: tasks[index].resultText)
            finishActiveRun(
                at: index,
                phase: .execution,
                outcome: .awaitingReview,
                summary: evidence.summary,
                evidence: evidence
            )
            resolveFailureAttention(taskID: tasks[index].id)
            tasks[index].stage = .review
            tasks[index].failureState = nil
            tasks[index].executionApproved = false
            tasks[index].liveMessage = "执行完成，等待验收"
            tasks[index].lastError = nil
            tasks[index].updatedAt = Date()
            appendLog(at: index, "Codex 已完成实施，等待检查交付证据。", level: .success)
            scheduleSave(immediate: true)
            scheduleExecutionQueue()
        }
    }

    private func failTask(
        at index: Int,
        message: String,
        runOutcome: TaskRunOutcome = .failed,
        kind: TaskFailureKind? = nil,
        retryPhase: TaskRunPhase? = nil,
        automaticRetryAllowed: Bool = true
    ) {
        let now = Date()
        let taskID = tasks[index].id
        let cancellationRequested = cancellationIntentTaskIDs.contains(taskID)
        let effectiveMessage = cancellationRequested ? "任务已停止。" : message
        let effectiveRunOutcome: TaskRunOutcome = cancellationRequested ? .interrupted : runOutcome
        let effectiveKind: TaskFailureKind? = cancellationRequested ? .interrupted : kind
        let effectiveRetryPhase: TaskRunPhase? = cancellationRequested ? nil : retryPhase
        let effectiveAutomaticRetryAllowed = automaticRetryAllowed && !cancellationRequested
        cancellationIntentTaskIDs.remove(taskID)
        cancellationRequestInFlightTaskIDs.remove(taskID)
        clearInteractions(for: taskID)
        resolvePlanAttention(taskID: taskID)
        pendingStreamUpdates.removeValue(forKey: taskID)
        let failedRunIndex = tasks[index].runs.lastIndex(where: { $0.outcome.isActive })
        let failedRunID = failedRunIndex.map { tasks[index].runs[$0].id }
        tasks[index].stage = .needsAttention
        tasks[index].executionApproved = false
        tasks[index].lastError = effectiveMessage
        tasks[index].updatedAt = now
        appendLog(at: index, effectiveMessage, level: cancellationRequested ? .warning : .error)

        let resolvedKind = effectiveKind ?? classifyFailure(effectiveMessage)
        let previous = tasks[index].failureState
        let consecutiveCount = previous?.kind == resolvedKind
            ? (previous?.consecutiveCount ?? 0) + 1
            : 1
        let previousRetryCount = previous?.kind == resolvedKind
            ? previous?.automaticRetryCount ?? 0
            : 0
        let mayRetry = effectiveAutomaticRetryAllowed
            && effectiveRetryPhase != nil
            && (resolvedKind == .startup || resolvedKind == .connection)
            && previousRetryCount < max(0, preferences.maxAutomaticRetries)
        let recoveryDisposition: TaskRunRecoveryDisposition
        var shouldCreateFailureAttention = false

        if cancellationRequested {
            tasks[index].failureState = TaskFailureState(
                kind: .interrupted,
                consecutiveCount: consecutiveCount,
                automaticRetryCount: previousRetryCount,
                circuitOpen: true,
                occurredAt: now,
                message: effectiveMessage
            )
            recoveryDisposition = .none
            tasks[index].liveMessage = "任务已停止"
        } else if mayRetry, let retryPhase = effectiveRetryPhase {
            let retryCount = previousRetryCount + 1
            let delay = retryCount == 1 ? 1 : min(8, 1 << (retryCount - 1))
            let retryAt = now.addingTimeInterval(TimeInterval(delay))
            tasks[index].failureState = TaskFailureState(
                kind: resolvedKind,
                consecutiveCount: consecutiveCount,
                automaticRetryCount: retryCount,
                circuitOpen: false,
                occurredAt: now,
                nextRetryAt: retryAt,
                message: effectiveMessage
            )
            recoveryDisposition = .automaticRetryScheduled
            tasks[index].liveMessage = "启动失败，\(delay) 秒后自动重试 \(retryCount)/\(preferences.maxAutomaticRetries)"
            appendLog(at: index, "将在 \(delay) 秒后自动重试（\(retryCount)/\(preferences.maxAutomaticRetries)）。", level: .warning)
            scheduleAutomaticRetry(taskID: taskID, phase: retryPhase, delay: delay)
        } else {
            tasks[index].failureState = TaskFailureState(
                kind: resolvedKind,
                consecutiveCount: consecutiveCount,
                automaticRetryCount: previousRetryCount,
                circuitOpen: true,
                occurredAt: now,
                message: effectiveMessage
            )
            if !effectiveAutomaticRetryAllowed, effectiveRetryPhase != nil {
                recoveryDisposition = .reconcileBeforeRetry
                tasks[index].liveMessage = "请求状态不确定，已暂停以避免重复执行"
                appendLog(
                    at: index,
                    "服务端可能已创建会话或轮次；为避免重复执行，未自动重试。",
                    level: .warning
                )
            } else {
                recoveryDisposition = .manualInterventionRequired
                tasks[index].liveMessage = "已熔断，等待人工处理"
            }
            shouldCreateFailureAttention = true
            if effectiveAutomaticRetryAllowed,
               effectiveRetryPhase != nil,
               resolvedKind == .startup || resolvedKind == .connection,
               preferences.maxAutomaticRetries > 0 {
                appendLog(at: index, "自动重试次数已用尽，熔断器已打开。", level: .warning)
            }
        }

        if let failedRunIndex,
           let failureState = tasks[index].failureState {
            tasks[index].runs[failedRunIndex].outcome = effectiveRunOutcome
            tasks[index].runs[failedRunIndex].endedAt = now
            tasks[index].runs[failedRunIndex].error = effectiveMessage
            tasks[index].runs[failedRunIndex].failure = TaskRunFailure(
                kind: resolvedKind,
                message: effectiveMessage,
                occurredAt: now,
                recoveryDisposition: recoveryDisposition,
                nextRetryAt: failureState.nextRetryAt,
                consecutiveCount: failureState.consecutiveCount,
                automaticRetryCount: failureState.automaticRetryCount
            )
            if tasks[index].runs[failedRunIndex].summary.isEmpty {
                tasks[index].runs[failedRunIndex].summary = effectiveMessage
            }
        }

        if shouldCreateFailureAttention {
            addFailureAttention(
                taskID: taskID,
                runID: failedRunID,
                createdAt: now
            )
        } else {
            resolveFailureAttention(taskID: taskID)
        }
        scheduleSave(immediate: true)
    }

    private func scheduleAutomaticRetry(taskID: UUID, phase: TaskRunPhase, delay: Int) {
        retryTasks[taskID]?.cancel()
        retryTasks[taskID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled,
                  let self,
                  !self.cancellationIntentTaskIDs.contains(taskID),
                  let index = self.taskIndex(taskID),
                  self.tasks[index].failureState?.nextRetryAt != nil
            else { return }
            self.retryTasks[taskID] = nil
            self.tasks[index].failureState?.nextRetryAt = nil
            self.tasks[index].lastError = nil
            switch phase {
            case .planning:
                self.tasks[index].stage = .inbox
                self.tasks[index].liveMessage = "正在自动重试规划…"
                self.enqueuePlanning(taskID: taskID)
            case .execution:
                self.tasks[index].stage = .awaitingApproval
                self.tasks[index].executionApproved = true
                self.tasks[index].liveMessage = "正在自动重试执行启动…"
                self.scheduleExecutionQueue()
            }
            self.scheduleSave(immediate: true)
        }
    }

    private func classifyFailure(_ message: String) -> TaskFailureKind {
        let normalized = message.lowercased()
        if normalized.contains("401")
            || normalized.contains("unauthorized")
            || normalized.contains("not logged in")
            || normalized.contains("missing bearer")
            || normalized.contains("authentication") {
            return .authentication
        }
        if normalized.contains("429")
            || normalized.contains("rate limit")
            || normalized.contains("quota") {
            return .rateLimit
        }
        if normalized.contains("worktree")
            || normalized.contains("not a git repository")
            || normalized.contains("项目目录")
            || normalized.contains("attachment")
            || normalized.contains("附件") {
            return .workspace
        }
        if normalized.contains("connection")
            || normalized.contains("websocket")
            || normalized.contains("连接") {
            return .connection
        }
        return .startup
    }

    private func isAmbiguousLifecycleTimeout(_ error: Error) -> Bool {
        guard let clientError = error as? CodexClientError,
              case let .requestTimedOut(method) = clientError
        else { return false }
        // These methods can create durable server-side state before their RPC
        // result reaches us. Replaying them after a timeout can duplicate a
        // thread or turn, so require an explicit recovery decision instead.
        return method == "thread/start" || method == "turn/start"
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

    private func removeInteraction(taskID: UUID, requestID: CodexRequestID) {
        guard var requests = pendingInteractionsByTaskID[taskID] else { return }
        requests.removeAll { $0.id == requestID }
        if requests.isEmpty {
            pendingInteractionsByTaskID.removeValue(forKey: taskID)
        } else {
            pendingInteractionsByTaskID[taskID] = requests
        }
        if let hostID = tasks.first(where: { $0.id == taskID })?.hostID {
            setResponding(
                false,
                key: HostRequestKey(hostID: hostID, requestID: requestID)
            )
        }
        resolveInteractionAttention(taskID: taskID, requestID: requestID)
    }

    private func clearInteractions(for taskID: UUID, turnID: String? = nil) {
        guard let turnID else {
            let requests = pendingInteractionsByTaskID.removeValue(forKey: taskID) ?? []
            requests.forEach { request in
                if let hostID = tasks.first(where: { $0.id == taskID })?.hostID {
                    setResponding(
                        false,
                        key: HostRequestKey(hostID: hostID, requestID: request.id)
                    )
                }
                resolveInteractionAttention(taskID: taskID, requestID: request.id)
            }
            return
        }
        guard var requests = pendingInteractionsByTaskID[taskID] else { return }
        let removed = requests.filter { $0.turnID == nil || $0.turnID == turnID }
        requests.removeAll { $0.turnID == nil || $0.turnID == turnID }
        removed.forEach { request in
            if let hostID = tasks.first(where: { $0.id == taskID })?.hostID {
                setResponding(
                    false,
                    key: HostRequestKey(hostID: hostID, requestID: request.id)
                )
            }
            resolveInteractionAttention(taskID: taskID, requestID: request.id)
        }
        if requests.isEmpty {
            pendingInteractionsByTaskID.removeValue(forKey: taskID)
        } else {
            pendingInteractionsByTaskID[taskID] = requests
        }
    }

    private func addInteractionAttention(
        taskID: UUID,
        requestID: CodexRequestID,
        createdAt: Date
    ) {
        guard let hostID = tasks.first(where: { $0.id == taskID })?.hostID else { return }
        let key = InteractionAttentionKey(
            hostID: hostID,
            taskID: taskID,
            requestID: requestID
        )
        guard interactionAttentionIDs[key] == nil else { return }
        let notice = TaskAttentionNotice(
            id: UUID(),
            taskID: taskID,
            kind: .interaction,
            createdAt: createdAt
        )
        interactionAttentionIDs[key] = notice.id
        attentionNotices.append(notice)
    }

    private func resolveInteractionAttention(taskID: UUID, requestID: CodexRequestID) {
        guard let hostID = tasks.first(where: { $0.id == taskID })?.hostID else { return }
        let key = InteractionAttentionKey(
            hostID: hostID,
            taskID: taskID,
            requestID: requestID
        )
        guard let noticeID = interactionAttentionIDs.removeValue(forKey: key) else { return }
        attentionNotices.removeAll { $0.id == noticeID }
    }

    private func setResponding(_ isResponding: Bool, key: HostRequestKey) {
        if isResponding {
            respondingRequests.insert(key)
        } else {
            respondingRequests.remove(key)
        }
        respondingRequestIDs = Set(respondingRequests.map(\.requestID))
    }

    private func setOAuthInProgress(_ isInProgress: Bool, key: HostServerKey) {
        if isInProgress {
            oauthRequestsInProgress.insert(key)
        } else {
            oauthRequestsInProgress.remove(key)
        }
        oauthServersInProgress = Set(oauthRequestsInProgress.map(\.serverName))
    }

    private func resolveAllInteractionAttentions() {
        let noticeIDs = Set(interactionAttentionIDs.values)
        interactionAttentionIDs.removeAll()
        attentionNotices.removeAll { noticeIDs.contains($0.id) }
    }

    private func addPlanAttention(taskID: UUID, createdAt: Date) {
        guard let index = taskIndex(taskID) else { return }
        let runID = tasks[index].runs.last(where: { $0.phase == .planning })?.id
        var attention = tasks[index].attention
        if attention?.kind != .planApproval {
            attention = TaskAttention(
                kind: .planApproval,
                runID: runID,
                createdAt: createdAt
            )
        } else if attention?.runID != runID {
            attention?.runID = runID
        }
        if let attention {
            setDurableAttention(attention, at: index)
        }
    }

    private func addFailureAttention(
        taskID: UUID,
        runID: UUID?,
        createdAt: Date
    ) {
        guard let index = taskIndex(taskID) else { return }
        var attention = tasks[index].attention
        if attention?.kind != .failure || attention?.runID != runID {
            attention = TaskAttention(
                kind: .failure,
                runID: runID,
                createdAt: createdAt
            )
        }
        if let attention {
            setDurableAttention(attention, at: index)
        }
    }

    private func rebuildDurableAttentions() {
        let existingNoticeIDs = Set(durableAttentionIDs.values)
        durableAttentionIDs.removeAll()
        attentionNotices.removeAll { existingNoticeIDs.contains($0.id) }

        var changed = false
        var waitingPlanTaskIDs: [UUID] = []
        for index in tasks.indices {
            let expectedKind: TaskAttentionKind?
            if tasks[index].stage == .awaitingApproval,
               !tasks[index].executionApproved,
               tasks[index].hasFinalPlan,
               !tasks[index].planText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                expectedKind = .planApproval
                waitingPlanTaskIDs.append(tasks[index].id)
            } else if tasks[index].stage == .needsAttention,
                      tasks[index].failureState?.circuitOpen == true,
                      tasks[index].failureState?.kind != .interrupted {
                expectedKind = .failure
            } else if tasks[index].stage.isActive,
                      tasks[index].runs.last(where: {
                          $0.outcome.isActive
                              && $0.multiAgentDrain?.phase == .blocked
                              && ($0.multiAgentDrain?.consecutiveReconciliationFailureCount ?? 0) >= 3
                      }) != nil {
                expectedKind = .failure
            } else {
                expectedKind = nil
            }

            guard let expectedKind else {
                if tasks[index].attention != nil {
                    tasks[index].attention = nil
                    changed = true
                }
                continue
            }

            let runID = switch expectedKind {
            case .planApproval:
                tasks[index].runs.last(where: { $0.phase == .planning })?.id
            case .failure:
                tasks[index].runs.last(where: {
                    $0.failure != nil
                        || $0.error != nil
                        || ($0.outcome.isActive && $0.multiAgentDrain?.phase == .blocked)
                })?.id
            }
            var attention = tasks[index].attention
            if attention?.kind != expectedKind {
                let createdAt = expectedKind == .failure
                    ? tasks[index].failureState?.occurredAt ?? tasks[index].updatedAt
                    : tasks[index].updatedAt
                attention = TaskAttention(
                    kind: expectedKind,
                    runID: runID,
                    createdAt: createdAt
                )
                changed = true
            } else if attention?.runID != runID {
                attention?.runID = runID
                changed = true
            }
            if let attention {
                setDurableAttention(attention, at: index)
            }
        }

        if changed {
            scheduleSave()
        }
        if let newestTaskID = waitingPlanTaskIDs.max(by: { lhs, rhs in
            guard let lhsIndex = taskIndex(lhs), let rhsIndex = taskIndex(rhs) else { return false }
            return tasks[lhsIndex].updatedAt < tasks[rhsIndex].updatedAt
        }) {
            focusTask(newestTaskID)
        }
    }

    private func setDurableAttention(_ attention: TaskAttention, at index: Int) {
        let taskID = tasks[index].id
        if let previousID = durableAttentionIDs[taskID], previousID != attention.id {
            attentionNotices.removeAll { $0.id == previousID }
        }
        tasks[index].attention = attention
        durableAttentionIDs[taskID] = attention.id
        guard !attentionNotices.contains(where: { $0.id == attention.id }) else { return }
        attentionNotices.append(TaskAttentionNotice(
            id: attention.id,
            taskID: taskID,
            kind: attention.kind == .planApproval ? .planApproval : .failure,
            createdAt: attention.createdAt
        ))
    }

    private func resolvePlanAttention(taskID: UUID) {
        guard let index = taskIndex(taskID), tasks[index].attention?.kind == .planApproval else { return }
        resolveDurableAttention(at: index)
    }

    private func resolveFailureAttention(taskID: UUID) {
        guard let index = taskIndex(taskID), tasks[index].attention?.kind == .failure else { return }
        resolveDurableAttention(at: index)
    }

    private func resolveDurableAttention(at index: Int) {
        let taskID = tasks[index].id
        let noticeID = durableAttentionIDs.removeValue(forKey: taskID)
            ?? tasks[index].attention?.id
        tasks[index].attention = nil
        if let noticeID {
            attentionNotices.removeAll { $0.id == noticeID }
        }
    }

    private func cancelPendingInteractions(for taskID: UUID) async {
        let requests = pendingInteractionsByTaskID[taskID] ?? []
        guard let task = tasks.first(where: { $0.id == taskID }),
              let host = host(for: task.hostID),
              host.isEnabled
        else { return }
        let hostClient = clientForHost(host)
        for request in requests {
            guard let response = cancellationResponse(for: request) else { continue }
            do {
                try await hostClient.respond(to: request.id, with: response)
                removeInteraction(taskID: taskID, requestID: request.id)
            } catch {
                // Keep the request visible so the user can retry if interrupting
                // the turn also fails.
            }
        }
    }

    private func cancellationResponse(
        for request: CodexInteractionRequest
    ) -> CodexInteractionResponse? {
        switch request.kind {
        case let .commandApproval(approval):
            if approval.availableDecisions?.contains(.cancel) != false {
                return .approval(.cancel)
            }
            if approval.availableDecisions?.contains(.decline) == true {
                return .approval(.decline)
            }
            return nil
        case .fileChangeApproval:
            return .approval(.cancel)
        case .permissionsApproval:
            return .permissions(.deny(scope: .turn))
        case .mcpElicitation:
            return .mcpElicitation(.cancel)
        case .userInput:
            return nil
        }
    }

    private func runtimeSafeApps(
        selectedApps: [TaskAppSelection],
        taskID: UUID
    ) async -> [TaskAppSelection] {
        guard !selectedApps.isEmpty else { return [] }
        do {
            guard let task = tasks.first(where: { $0.id == taskID }),
                  let host = host(for: task.hostID),
                  host.isEnabled
            else { return [] }
            let currentCatalog = try await clientForHost(host).listApps(
                forceRefresh: true,
                threadID: task.threadID
            )
            let readOnlyAppIDs = Set(currentCatalog.lazy.filter(\.supportsReadOnlyUse).map(\.id))
            let safeSelections = selectedApps.filter {
                !$0.requiresApproval && readOnlyAppIDs.contains($0.id)
            }
            if safeSelections.count != selectedApps.count,
               let index = taskIndex(taskID) {
                appendLog(
                    at: index,
                    "部分 App 已不可用或不再是纯只读，本轮已停止注入。",
                    level: .warning
                )
            }
            return safeSelections
        } catch {
            if let index = taskIndex(taskID) {
                appendLog(
                    at: index,
                    "无法重新验证 App 目录，本轮不注入任何 App。",
                    level: .warning
                )
            }
            return []
        }
    }

    private func project(forTaskAt index: Int) -> ProjectRecord? {
        projects.first(where: { $0.id == tasks[index].projectID })
    }

    private func selectInitialProjectIfNeeded() {
        let visibleProjects = visibleProjects
        if let selectedProjectID,
           visibleProjects.contains(where: { $0.id == selectedProjectID }) {
            return
        }
        selectedProjectID = visibleProjects.first(where: { project in
            tasks.contains(where: { $0.projectID == project.id })
        })?.id ?? visibleProjects.first?.id
    }

    private func managedWorktreePaths(for hostID: String) -> [String] {
        tasks.compactMap { task in
            guard task.hostID == hostID, task.workspace.kind == .worktree else { return nil }
            return task.workspace.path
        }
    }

    private func reconcileManualProjectVisibility() {
        let manualProjectIDs = Set(projects.lazy.filter(\.isManual).map(\.id))
        let previouslyHiddenCount = hiddenProjectPaths.count
        hiddenProjectPaths.subtract(manualProjectIDs)
        if hiddenProjectPaths.count != previouslyHiddenCount {
            scheduleSave()
        }
    }

    private static func isSameOrDescendant(
        _ path: String,
        of ancestor: String,
        isRemote: Bool = false
    ) -> Bool {
        let pathComponents: [String]
        let ancestorComponents: [String]
        if isRemote {
            // Remote paths belong to another filesystem. Comparing them must be
            // purely lexical; resolving symlinks here would inspect the Mac and
            // could remove an unrelated remote manual project.
            pathComponents = ((path as NSString).standardizingPath as NSString).pathComponents
            ancestorComponents = ((ancestor as NSString).standardizingPath as NSString).pathComponents
        } else {
            pathComponents = URL(fileURLWithPath: path, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .pathComponents
            ancestorComponents = URL(fileURLWithPath: ancestor, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .pathComponents
        }
        guard ancestorComponents.count <= pathComponents.count else { return false }
        return pathComponents.prefix(ancestorComponents.count).elementsEqual(ancestorComponents)
    }

    @discardableResult
    private func beginRun(at taskIndex: Int, phase: TaskRunPhase) -> UUID {
        let threadID = tasks[taskIndex].threadID
        let sourceRunID = threadID.flatMap { threadID in
            tasks[taskIndex].runs.last(where: { $0.threadID == threadID })?.id
        }
        let run = TaskRun(
            phase: phase,
            attempt: tasks[taskIndex].runs.count(where: { $0.phase == phase }) + 1,
            threadID: threadID,
            sessionID: tasks[taskIndex].sessionID,
            model: tasks[taskIndex].actualModel ?? tasks[taskIndex].requestedModel.nilIfEmpty,
            reasoningEffort: tasks[taskIndex].reasoningEffort,
            fastMode: tasks[taskIndex].fastMode,
            continuation: TaskRunContinuation(
                mode: threadID == nil ? .freshThread : .reusedThread,
                sourceRunID: sourceRunID
            )
        )
        tasks[taskIndex].runs.append(run)
        return run.id
    }

    private func taskRunPolicySnapshot(
        for task: BoardTask,
        phase: TaskRunPhase,
        cwd: String
    ) -> TaskRunPolicySnapshot {
        let isPlanning = phase == .planning
        return TaskRunPolicySnapshot(
            hostID: task.hostID,
            workspace: TaskRunWorkspaceSnapshot(
                kind: isPlanning ? .project : task.workspace.kind,
                path: cwd,
                branch: isPlanning ? nil : task.workspace.branch,
                baseBranch: isPlanning ? nil : task.workspace.baseBranch,
                preparation: isPlanning ? nil : task.workspace.preparation
            ),
            sandboxMode: isPlanning ? .readOnly : .workspaceWrite,
            approvalPolicy: isPlanning ? .never : .onRequest,
            networkAccess: isPlanning ? false : preferences.allowNetworkAccess,
            writableRoots: isPlanning ? [] : [cwd],
            serviceTier: task.fastMode ? CodexServiceTier.fast : CodexServiceTier.standard
        )
    }

    private func updateRun(
        at taskIndex: Int,
        runID: UUID,
        _ mutate: (inout TaskRun) -> Void
    ) {
        guard let runIndex = tasks[taskIndex].runs.firstIndex(where: { $0.id == runID }) else { return }
        mutate(&tasks[taskIndex].runs[runIndex])
    }

    private func updateLatestExecutionRun(
        at taskIndex: Int,
        _ mutate: (inout TaskRun) -> Void
    ) {
        guard let runIndex = tasks[taskIndex].runs.lastIndex(where: { $0.phase == .execution }) else { return }
        mutate(&tasks[taskIndex].runs[runIndex])
    }

    private func restoreExecutionRunForConfirmedTurn(at taskIndex: Int, turnID: String) {
        restoreRunForConfirmedTurn(at: taskIndex, phase: .execution, turnID: turnID)
    }

    private func restoreRunForConfirmedTurn(
        at taskIndex: Int,
        phase: TaskRunPhase,
        turnID: String
    ) {
        if let runIndex = tasks[taskIndex].runs.lastIndex(where: {
            $0.phase == phase && ($0.turnID == turnID || $0.turnID == nil)
        }) {
            tasks[taskIndex].runs[runIndex].turnID = turnID
            tasks[taskIndex].runs[runIndex].outcome = .running
            tasks[taskIndex].runs[runIndex].endedAt = nil
            tasks[taskIndex].runs[runIndex].error = nil
            tasks[taskIndex].runs[runIndex].failure = nil
            return
        }
        let task = tasks[taskIndex]
        tasks[taskIndex].runs.append(TaskRun(
            phase: phase,
            attempt: task.runs.count(where: { $0.phase == phase }) + 1,
            threadID: task.threadID,
            sessionID: task.sessionID,
            turnID: turnID,
            model: task.actualModel ?? task.requestedModel.nilIfEmpty,
            reasoningEffort: task.reasoningEffort,
            fastMode: task.fastMode,
            continuation: TaskRunContinuation(
                mode: task.threadID == nil ? .freshThread : .reusedThread,
                sourceRunID: task.threadID.flatMap { threadID in
                    task.runs.last(where: { $0.threadID == threadID })?.id
                }
            )
        ))
    }

    private func finishActiveRun(
        at taskIndex: Int,
        phase: TaskRunPhase,
        outcome: TaskRunOutcome,
        summary: String,
        evidence: TaskDeliveryEvidence? = nil,
        error: String? = nil
    ) {
        guard let runIndex = tasks[taskIndex].runs.lastIndex(where: {
            $0.phase == phase && $0.outcome.isActive
        }) else { return }
        tasks[taskIndex].runs[runIndex].outcome = outcome
        tasks[taskIndex].runs[runIndex].endedAt = Date()
        tasks[taskIndex].runs[runIndex].summary = conciseRunSummary(summary)
        tasks[taskIndex].runs[runIndex].evidence = evidence
        tasks[taskIndex].runs[runIndex].error = error
    }

    private func conciseRunSummary(_ value: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 1_200 else { return clean }
        return "\(clean.prefix(1_200))…"
    }

    private func synchronizeTaskProjections() {
        let completedIDs = Set(tasks.lazy.filter { $0.stage == .completed }.map(\.id))
        let nextCards = tasks.map { task in
            BoardTaskCard(
                task: task,
                blockingDependencyCount: task.dependencyIDs.count { !completedIDs.contains($0) }
            )
        }
        if nextCards != taskCards {
            taskCards = nextCards
        }
        synchronizeSelectedTask()
    }

    private func synchronizeSelectedTask() {
        let nextTask = selectedTaskID.flatMap { id in
            tasks.first(where: { $0.id == id })
        }
        if nextTask != selectedTask {
            selectedTask = nextTask
        }
    }

    private func scheduleStreamFlush() {
        guard streamFlushTask == nil else { return }
        streamFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.flushPendingStreamUpdates()
        }
    }

    private func flushPendingStreamUpdates() {
        streamFlushTask?.cancel()
        streamFlushTask = nil
        guard !pendingStreamUpdates.isEmpty else { return }

        let updates = pendingStreamUpdates
        pendingStreamUpdates.removeAll(keepingCapacity: true)
        var updatedTasks = tasks
        var changed = false
        var changesPersistedContent = false

        for (taskID, update) in updates {
            guard let index = updatedTasks.firstIndex(where: { $0.id == taskID }) else { continue }
            if !update.planDelta.isEmpty, updatedTasks[index].stage == .planning {
                updatedTasks[index].planText += update.planDelta
                changed = true
            }
            if !update.resultDelta.isEmpty, updatedTasks[index].stage == .executing {
                updatedTasks[index].resultText += update.resultDelta
                changed = true
            }
            if let liveMessage = update.liveMessage, updatedTasks[index].stage.isActive {
                updatedTasks[index].liveMessage = liveMessage
                changed = true
            }
            if let turnID = update.turnDiffID, let diff = update.turnDiff {
                let executionTurnID = updatedTasks[index].executionTurnID
                if let runIndex = updatedTasks[index].runs.lastIndex(where: { run in
                    run.phase == .execution
                        && (run.turnID == turnID
                            || (run.outcome.isActive && run.turnID == nil && executionTurnID == nil))
                }) {
                    let delivery = TaskCodeDelivery.capturing(diff)
                    if updatedTasks[index].runs[runIndex].codeDelivery != delivery {
                        updatedTasks[index].runs[runIndex].codeDelivery = delivery
                        changed = true
                    }
                }
            }
            changesPersistedContent = changesPersistedContent || update.changesPersistedContent
        }

        guard changed else { return }
        tasks = updatedTasks
        if changesPersistedContent {
            scheduleSave()
        }
    }

    private func discardPendingStreamUpdate(for taskID: UUID) {
        pendingStreamUpdates.removeValue(forKey: taskID)
        if pendingStreamUpdates.isEmpty {
            streamFlushTask?.cancel()
            streamFlushTask = nil
        }
    }

    private func scheduleSave(immediate: Bool = false) {
        guard didStart else { return }
        saveRevision &+= 1
        if isSaving {
            saveImmediatelyAfterCurrentWrite = saveImmediatelyAfterCurrentWrite || immediate
            return
        }
        if immediate {
            saveTask?.cancel()
            saveTask = nil
        } else if saveTask != nil {
            return
        }

        let delay: Duration = immediate ? .zero : .milliseconds(800)
        saveTask = Task { @MainActor [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.persistLatestSnapshot()
        }
    }

    @discardableResult
    private func persistLatestSnapshot() async -> Bool {
        saveTask = nil
        guard !isSaving else { return false }
        guard savedRevision < saveRevision else { return true }
        isSaving = true
        let revision = saveRevision
        let snapshot = currentSnapshot()
        let deletedTasks = pendingAttachmentDeletions
        var succeeded = false
        do {
            try await persistence.save(snapshot)
            savedRevision = revision
            succeeded = true
            let deletedIDs = Set(deletedTasks.map(\.id))
            pendingAttachmentDeletions.removeAll { deletedIDs.contains($0.id) }
            for task in deletedTasks {
                await attachmentStorage.removeManagedAttachments(
                    taskID: task.id,
                    attachments: task.attachments
                )
            }
        } catch {
            lastError = error.localizedDescription
        }
        isSaving = false

        guard succeeded else {
            let newerRevisionArrived = saveRevision > revision
            saveImmediatelyAfterCurrentWrite = false
            if newerRevisionArrived {
                // The failed snapshot was already stale before its write
                // returned. Preserve the newer dirty revision and retry it
                // with the normal debounce instead of dropping that state.
                scheduleSaveWithoutRevision(immediate: false)
            }
            return false
        }
        guard savedRevision < saveRevision else {
            saveImmediatelyAfterCurrentWrite = false
            return true
        }
        let immediate = saveImmediatelyAfterCurrentWrite
        saveImmediatelyAfterCurrentWrite = false
        scheduleSaveWithoutRevision(immediate: immediate)
        return true
    }

    private func scheduleSaveWithoutRevision(immediate: Bool) {
        guard saveTask == nil else { return }
        let delay: Duration = immediate ? .zero : .milliseconds(800)
        saveTask = Task { @MainActor [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.persistLatestSnapshot()
        }
    }

    @discardableResult
    private func saveImmediately() async -> Bool {
        guard didStart else { return false }
        saveRevision &+= 1
        let targetRevision = saveRevision
        saveImmediatelyAfterCurrentWrite = true
        saveTask?.cancel()
        saveTask = nil
        while savedRevision < targetRevision {
            if Task.isCancelled { return false }
            if isSaving {
                try? await Task.sleep(for: .milliseconds(5))
                continue
            }
            saveTask?.cancel()
            saveTask = nil
            let succeeded = await persistLatestSnapshot()
            if !succeeded, savedRevision < targetRevision {
                saveImmediatelyAfterCurrentWrite = false
                return false
            }
        }
        return true
    }

    private func currentSnapshot() -> BoardSnapshot {
        BoardSnapshot(
            version: BoardSnapshot.currentVersion,
            tasks: tasks,
            hosts: hosts,
            manualProjects: manualProjects,
            preferences: preferences,
            hiddenProjectPaths: hiddenProjectPaths.sorted()
        )
    }

    private func shortID(_ value: String) -> String {
        String(value.prefix(8))
    }

    private func resolvedModel(_ model: String?) -> String {
        if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            return availableModels.first(where: { $0.id == model })?.model ?? model
        }
        if let override = preferences.modelOverride.nilIfEmpty {
            return availableModels.first(where: { $0.id == override })?.model ?? override
        }
        return defaultTaskModel?.model ?? ""
    }

    private func skillsForProject(
        path: String,
        in skillsByCWD: [String: [CodexSkillMetadata]]
    ) -> [CodexSkillMetadata] {
        if let exact = skillsByCWD[path] { return exact }
        let normalizedPath = normalizedDirectoryPath(path)
        if let matching = skillsByCWD.first(where: {
            normalizedDirectoryPath($0.key) == normalizedPath
        }) {
            return matching.value
        }
        return skillsByCWD.count == 1 ? skillsByCWD.values.first ?? [] : []
    }

    private func normalizedDirectoryPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private func stableUniqueSkills(_ skills: [CodexSkillMetadata]) -> [CodexSkillMetadata] {
        var seen = Set<String>()
        return skills.filter { seen.insert($0.path).inserted }
    }

    private func stableUniqueApps(_ apps: [CodexApp]) -> [CodexApp] {
        var seen = Set<String>()
        return apps.filter { seen.insert($0.id).inserted }
    }

    private func stableUniqueMCPServers(
        _ servers: [CodexMCPServerStatus]
    ) -> [CodexMCPServerStatus] {
        var seen = Set<String>()
        return servers.filter { seen.insert($0.name).inserted }
    }

    private func stableUniqueSkillSelections(
        _ selections: [TaskSkillSelection]
    ) -> [TaskSkillSelection] {
        var seen = Set<String>()
        return selections.filter { selection in
            let key = selection.path.trimmingCharacters(in: .whitespacesAndNewlines)
            return !key.isEmpty && seen.insert(key).inserted
        }
    }

    private func stableUniqueAppSelections(
        _ selections: [TaskAppSelection]
    ) -> [TaskAppSelection] {
        var seen = Set<String>()
        return selections.filter { selection in
            let key = selection.id.trimmingCharacters(in: .whitespacesAndNewlines)
            return !key.isEmpty && seen.insert(key).inserted
        }
    }

    private func safeUniqueAppSelections(
        _ selections: [TaskAppSelection]
    ) -> [TaskAppSelection] {
        let readOnlyAppIDs = Set(availableApps.lazy.filter(\.supportsReadOnlyUse).map(\.id))
        return stableUniqueAppSelections(selections).filter { selection in
            !selection.requiresApproval && readOnlyAppIDs.contains(selection.id)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
    var nilIfBlank: String? {
        let clean = trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}

private extension CodexConnectionState {
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
