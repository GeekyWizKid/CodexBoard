import AppKit
import Foundation
import Observation

enum BoardStoreError: LocalizedError {
    case invalidProject
    case emptyTask
    case worktreeRequiresGit
    case invalidDependencies

    var errorDescription: String? {
        switch self {
        case .invalidProject: "所选项目不存在或已不可用。"
        case .emptyTask: "请输入任务内容或至少添加一个附件。"
        case .worktreeRequiresGit: "独立 Worktree 只能用于 Git 项目。"
        case .invalidDependencies: "前置任务必须存在于同一个项目中。"
        }
    }
}

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
    let taskID: UUID
    let requestID: CodexRequestID
}

@MainActor
@Observable
final class BoardStore {
    private(set) var projects: [ProjectRecord] = []
    private(set) var tasks: [BoardTask] = [] {
        didSet { synchronizeTaskProjections() }
    }
    private(set) var taskCards: [BoardTaskCard] = []
    private(set) var selectedTask: BoardTask?
    var preferences = BoardPreferences()
    var selectedProjectID: String? {
        didSet {
            guard selectedProjectID != oldValue else { return }
            if let selectedTaskID,
               tasks.first(where: { $0.id == selectedTaskID })?.projectID != selectedProjectID {
                self.selectedTaskID = nil
            }
            if let selectedProjectID {
                scheduleCapabilityRefresh(projectID: selectedProjectID, forceRefresh: false)
            } else {
                capabilityRefreshTask?.cancel()
                capabilityRefreshGeneration &+= 1
                capabilityProjectID = nil
                availableSkills = []
                isLoadingCapabilities = false
                capabilityCatalogError = nil
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

    @ObservationIgnored
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
    private let externalURLOpener: (URL) -> Bool
    @ObservationIgnored
    private var manualProjectPaths: [String] = []
    @ObservationIgnored
    private var hiddenProjectPaths = Set<String>()
    @ObservationIgnored
    private var eventTask: Task<Void, Never>?
    @ObservationIgnored
    private var saveTask: Task<Void, Never>?
    @ObservationIgnored
    private var capabilityRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var capabilityRefreshGeneration = 0
    @ObservationIgnored
    private var capabilityProjectID: String?
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
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored
    private var cancellationIntentTaskIDs = Set<UUID>()
    @ObservationIgnored
    private var cancellationRequestInFlightTaskIDs = Set<UUID>()
    @ObservationIgnored
    private var interactionAttentionIDs: [InteractionAttentionKey: UUID] = [:]
    @ObservationIgnored
    private var planAttentionIDs: [UUID: UUID] = [:]

    init(
        client: any CodexTaskClient = CodexAppServerClient(),
        persistence: any BoardPersisting = BoardPersistence(),
        discovery: ProjectDiscoveryService = ProjectDiscoveryService(),
        attachmentStorage: AttachmentStorage = AttachmentStorage(),
        worktreeManager: any WorktreeManaging = WorktreeManager(),
        externalURLOpener: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.client = client
        self.persistence = persistence
        self.discovery = discovery
        self.attachmentStorage = attachmentStorage
        self.worktreeManager = worktreeManager
        self.externalURLOpener = externalURLOpener
    }

    deinit {
        eventTask?.cancel()
        saveTask?.cancel()
        capabilityRefreshTask?.cancel()
        streamFlushTask?.cancel()
        retryTasks.values.forEach { $0.cancel() }
    }

    var selectedProject: ProjectRecord? {
        selectedProjectID.flatMap { id in projects.first(where: { $0.id == id }) }
    }

    var visibleProjects: [ProjectRecord] {
        projects.filter { project in
            (project.isManual || !hiddenProjectPaths.contains(project.id))
                && (preferences.showMissingProjects || project.existsOnDisk)
        }
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

    func respondToInteraction(
        taskID: UUID,
        requestID: CodexRequestID,
        response: CodexInteractionResponse
    ) async {
        guard let request = pendingInteractionsByTaskID[taskID]?.first(where: { $0.id == requestID }),
              !respondingRequestIDs.contains(requestID)
        else { return }
        guard let task = tasks.first(where: { $0.id == taskID }),
              task.threadID == request.threadID
        else {
            removeInteraction(taskID: taskID, requestID: requestID)
            return
        }

        respondingRequestIDs.insert(requestID)
        defer { respondingRequestIDs.remove(requestID) }
        do {
            try await client.respond(to: requestID, with: response)
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
        eventTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self.client.events {
                guard !Task.isCancelled else { break }
                self.handle(event)
            }
        }
        Task { @MainActor [weak self] in
            await self?.loadAndConnect()
        }
    }

    func refreshProjects() async {
        guard !isRefreshingProjects else { return }
        isRefreshingProjects = true
        statusMessage = "正在扫描本机 Codex 项目…"
        defer { isRefreshingProjects = false }
        do {
            try await client.connect()
            accountReady = try await client.verifyAccount()
            await refreshModels()
            var threads: [CodexThreadSummary] = []
            for archived in [false, true] {
                var cursor: String?
                repeat {
                    let page = try await client.listThreads(cursor: cursor, archived: archived)
                    threads.append(contentsOf: page.threads)
                    cursor = page.nextCursor
                } while cursor != nil
            }
            projects = await discovery.discover(
                threads: threads,
                manualPaths: manualProjectPaths,
                ignoredPaths: managedWorktreePaths
            )
            reconcileManualProjectVisibility()
            selectInitialProjectIfNeeded()
            statusMessage = "已载入 \(visibleProjects.count) 个项目"
            lastError = nil
        } catch {
            accountReady = false
            lastError = error.localizedDescription
            statusMessage = "项目扫描失败"
            projects = await discovery.discover(
                threads: [],
                manualPaths: manualProjectPaths,
                ignoredPaths: managedWorktreePaths
            )
            reconcileManualProjectVisibility()
            selectInitialProjectIfNeeded()
        }
        if let selectedProjectID {
            scheduleCapabilityRefresh(projectID: selectedProjectID, forceRefresh: false)
        }
    }

    func refreshModels() async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            availableModels = try await client.listModels()
            modelCatalogError = availableModels.isEmpty ? "本机 Codex 未返回可用模型。" : nil
        } catch {
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
        }
        isLoadingCapabilities = true
        capabilityCatalogError = nil
        defer {
            if capabilityRefreshGeneration == generation {
                isLoadingCapabilities = false
            }
        }

        do {
            try await client.connect()
        } catch {
            guard capabilityRefreshGeneration == generation else { return }
            capabilityCatalogError = error.localizedDescription
            return
        }

        var nextSkills: [CodexSkillMetadata]?
        var nextApps: [CodexApp]?
        var errors: [String] = []
        do {
            let skillsByCWD = try await client.listSkills(
                cwds: [project.path],
                forceReload: forceRefresh
            )
            nextSkills = skillsForProject(path: project.path, in: skillsByCWD)
        } catch {
            errors.append("Skills：\(error.localizedDescription)")
        }
        guard !Task.isCancelled, capabilityRefreshGeneration == generation else { return }
        do {
            nextApps = try await client.listApps(forceRefresh: forceRefresh)
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
            try await client.connect()
            let threadID = selectedTask?.threadID
            let servers = try await client.listMCPServers(threadID: threadID)
            guard !Task.isCancelled, mcpRefreshGeneration == generation else { return }
            mcpServers = stableUniqueMCPServers(servers)
        } catch {
            guard mcpRefreshGeneration == generation else { return }
            mcpServerError = error.localizedDescription
        }
    }

    func beginMCPOAuth(serverName: String) async {
        let cleanName = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !oauthServersInProgress.contains(cleanName) else { return }
        oauthServersInProgress.insert(cleanName)
        mcpServerError = nil
        do {
            try await client.connect()
            let url = try await client.beginMCPOAuth(
                serverName: cleanName,
                threadID: selectedTask?.threadID
            )
            guard openInteractionURL(url) else {
                throw BoardStoreOAuthError.cannotOpenBrowser
            }
        } catch {
            oauthServersInProgress.remove(cleanName)
            mcpServerError = error.localizedDescription
        }
    }

    @discardableResult
    func openInteractionURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        return externalURLOpener(url)
    }

    func addManualProject(path: String) {
        let normalized = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        manualProjectPaths.removeAll { $0 == normalized }
        manualProjectPaths.insert(normalized, at: 0)
        hiddenProjectPaths.remove(normalized)
        scheduleSave()
        Task { @MainActor [weak self] in await self?.refreshProjects() }
    }

    func removeProjectFromSidebar(_ project: ProjectRecord) {
        hiddenProjectPaths.insert(project.id)
        manualProjectPaths.removeAll { manualPath in
            Self.isSameOrDescendant(manualPath, of: project.path)
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
        guard let project = projects.first(where: { $0.id == projectID }) else {
            throw BoardStoreError.invalidProject
        }
        guard workspaceKind != .worktree || project.isGitRepository else {
            throw BoardStoreError.worktreeRequiresGit
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
        selectedProjectID = projectID
        selectedTaskID = task.id
        scheduleSave(immediate: true)
        if autoRun && blockingCount == 0 {
            enqueuePlanning(taskID: task.id)
        }
        return task.id
    }

    func startPlanning(taskID: UUID) async {
        guard let initialIndex = taskIndex(taskID), let project = project(forTaskAt: initialIndex) else { return }
        guard tasks[initialIndex].stage == .inbox else { return }
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
        // Claim the task before the first suspension point so a rapid double
        // click cannot create duplicate Codex threads or planning turns.
        tasks[initialIndex].stage = .planning
        tasks[initialIndex].executionApproved = false
        tasks[initialIndex].planText = ""
        tasks[initialIndex].hasFinalPlan = false
        tasks[initialIndex].structuredPlan = []
        tasks[initialIndex].planningTurnID = nil
        tasks[initialIndex].executionTurnID = nil
        tasks[initialIndex].liveMessage = "正在连接本机 Codex…"
        tasks[initialIndex].lastError = nil
        tasks[initialIndex].updatedAt = Date()
        appendLog(at: initialIndex, "开始只读规划。")
        let planningRunID = beginRun(at: initialIndex, phase: .planning)
        scheduleSave()

        do {
            try await attachmentStorage.validate(tasks[initialIndex].attachments)
        } catch {
            if let failureIndex = taskIndex(taskID) {
                failTask(at: failureIndex, message: error.localizedDescription, kind: .workspace)
            }
            return
        }

        guard let index = taskIndex(taskID), tasks[index].stage == .planning else { return }

        do {
            let startedThread: CodexStartedThread
            if let existingThread = tasks[index].threadID {
                startedThread = try await client.resumeThread(threadID: existingThread, cwd: project.path)
            } else {
                startedThread = try await client.startThread(
                    cwd: project.path,
                    model: tasks[index].requestedModel,
                    serviceTier: tasks[index].fastMode ? CodexServiceTier.fast : CodexServiceTier.standard
                )
                try? await client.setThreadName(
                    threadID: startedThread.threadID,
                    name: "CodexBoard · \(tasks[index].title)"
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
            scheduleSave()

            let runtimeSafeApps = await runtimeSafeApps(
                selectedApps: tasks[currentIndex].selectedApps,
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
            let turn = try await client.startPlanningTurn(
                threadID: startedThread.threadID,
                cwd: project.path,
                input: input,
                model: tasks[inputIndex].requestedModel,
                effort: tasks[inputIndex].reasoningEffort,
                serviceTier: tasks[inputIndex].fastMode ? CodexServiceTier.fast : CodexServiceTier.standard
            )
            guard let finalIndex = taskIndex(taskID),
                  tasks[finalIndex].stage == .planning,
                  !cancellationIntentTaskIDs.contains(taskID)
            else {
                try? await client.interrupt(threadID: startedThread.threadID, turnID: turn.turnID)
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
            scheduleSave()
        } catch {
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
        resolvePlanAttention(taskID: taskID)
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
        guard let index = taskIndex(taskID),
              !tasks[index].stage.isActive,
              tasks[index].hasFinalPlan,
              !tasks[index].planText.isEmpty
        else { return }
        resolvePlanAttention(taskID: taskID)
        retryTasks[taskID]?.cancel()
        retryTasks[taskID] = nil
        tasks[index].executionTurnID = nil
        tasks[index].failureState = nil
        tasks[index].stage = .awaitingApproval
        tasks[index].executionApproved = true
        appendLog(at: index, "已请求从当前工作区状态继续执行。")
        scheduleSave(immediate: true)
        scheduleExecutionQueue()
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
        guard let threadID = tasks[initialIndex].threadID else {
            appendLog(at: initialIndex, "将在 Turn 启动完成后立即停止。", level: .warning)
            scheduleSave(immediate: true)
            return
        }
        let activeTurnID = tasks[initialIndex].stage == .planning
            ? tasks[initialIndex].planningTurnID
            : tasks[initialIndex].executionTurnID
        let turnID = activeTurnID
            ?? pendingInteractionsByTaskID[taskID]?.compactMap(\.turnID).first

        await cancelPendingInteractions(for: taskID)
        guard let turnID else {
            if let index = taskIndex(taskID) {
                appendLog(at: index, "停止请求正在等待 Turn 启动完成，请稍后重试。", level: .warning)
                scheduleSave(immediate: true)
            }
            return
        }
        do {
            try await client.interrupt(threadID: threadID, turnID: turnID)
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
    }

    func deleteTask(taskID: UUID) {
        discardPendingStreamUpdate(for: taskID)
        guard let index = taskIndex(taskID), !tasks[index].stage.isActive else { return }
        let dependentCount = dependents(of: taskID).count
        guard dependentCount == 0 else {
            lastError = "仍有 \(dependentCount) 个任务依赖这张卡片，请先解除依赖。"
            return
        }
        retryTasks[taskID]?.cancel()
        retryTasks[taskID] = nil
        clearInteractions(for: taskID)
        resolvePlanAttention(taskID: taskID)
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
            resolvePlanAttention(taskID: taskID)
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
        guard project.existsOnDisk else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
    }

    func revealAttachment(_ attachment: TaskAttachment) {
        let url = URL(fileURLWithPath: attachment.path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func deliveryArtifactURL(_ artifact: TaskDeliveryArtifact, for task: BoardTask) -> URL? {
        guard let project = projects.first(where: { $0.id == task.projectID }) else { return nil }
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
        guard let path = task.workspace.path,
              FileManager.default.fileExists(atPath: path)
        else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func cleanupWorktree(taskID: UUID) async {
        guard let index = taskIndex(taskID),
              !tasks[index].stage.isActive,
              tasks[index].workspace.kind == .worktree,
              let project = project(forTaskAt: index)
        else { return }
        do {
            let cleaned = try await worktreeManager.cleanup(
                projectPath: project.path,
                configuration: tasks[index].workspace
            )
            guard let currentIndex = taskIndex(taskID) else { return }
            tasks[currentIndex].workspace = cleaned
            appendLog(at: currentIndex, "独立 Worktree 已清理；任务分支仍保留。", level: .success)
            scheduleSave(immediate: true)
        } catch {
            guard let currentIndex = taskIndex(taskID) else { return }
            tasks[currentIndex].lastError = error.localizedDescription
            appendLog(at: currentIndex, error.localizedDescription, level: .error)
            scheduleSave(immediate: true)
        }
    }

    func openTaskInCodex(_ task: BoardTask) {
        guard let threadID = task.threadID,
              let url = URL(string: "codex://thread/\(threadID)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func scheduleCapabilityRefresh(projectID: String, forceRefresh: Bool) {
        capabilityRefreshTask?.cancel()
        capabilityRefreshTask = Task { @MainActor [weak self] in
            await self?.refreshCapabilities(projectID: projectID, forceRefresh: forceRefresh)
        }
    }

    private func loadAndConnect() async {
        do {
            let snapshot = try await persistence.load()
            tasks = snapshot.tasks
            manualProjectPaths = snapshot.manualProjectPaths
            hiddenProjectPaths = Set(snapshot.hiddenProjectPaths)
            preferences = snapshot.preferences
            normalizeInterruptedTasks()
        } catch {
            lastError = error.localizedDescription
        }
        await refreshProjects()
        rebuildPlanAttentions()
        scheduleEligiblePlanningTasks()
        scheduleExecutionQueue()
    }

    private func enqueuePlanning(taskID: UUID) {
        guard pendingPlanningTaskIDs.insert(taskID).inserted else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pendingPlanningTaskIDs.remove(taskID)
            await self.startPlanning(taskID: taskID)
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

    private func scheduleExecutionQueue() {
        let available = max(0, preferences.maxConcurrentExecutions - activeExecutionCount)
        var activeDirectWorkspaceProjects = Set(
            tasks.lazy
                .filter { $0.stage == .executing && $0.workspace.kind == .project }
                .map(\.projectID)
        )
        var queued: [Int] = []
        let candidates = tasks.indices
            .filter {
                tasks[$0].stage == .awaitingApproval
                    && tasks[$0].executionApproved
                    && !cancellationIntentTaskIDs.contains(tasks[$0].id)
                    && tasks[$0].hasFinalPlan
                    && !tasks[$0].planText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { tasks[$0].updatedAt < tasks[$1].updatedAt }
        for index in candidates {
            let task = tasks[index]
            if task.workspace.kind == .project {
                guard !activeDirectWorkspaceProjects.contains(task.projectID) else {
                    tasks[index].liveMessage = "等待同项目的主目录任务结束"
                    continue
                }
            }
            guard queued.count < available else {
                tasks[index].liveMessage = "等待可用执行槽位"
                continue
            }
            if task.workspace.kind == .project {
                activeDirectWorkspaceProjects.insert(task.projectID)
            }
            queued.append(index)
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
        guard let index = taskIndex(taskID), let project = project(forTaskAt: index), let threadID = tasks[index].threadID else {
            if let index = taskIndex(taskID) {
                failTask(at: index, message: "缺少可恢复的 Codex thread。", kind: .workspace)
            }
            return
        }
        do {
            let preparedWorkspace = try await worktreeManager.prepare(
                taskID: taskID,
                projectPath: project.path,
                configuration: tasks[index].workspace
            )
            guard let preparedIndex = taskIndex(taskID) else { return }
            tasks[preparedIndex].workspace = preparedWorkspace
            let executionPath = preparedWorkspace.path ?? project.path
            if preparedWorkspace.kind == .worktree, preparedWorkspace.path != nil {
                appendLog(
                    at: preparedIndex,
                    "使用独立 Worktree：\(preparedWorkspace.branch ?? executionPath)",
                    level: .success
                )
            }
            try await attachmentStorage.validate(tasks[index].attachments)
            let resumed = try await client.resumeThread(threadID: threadID, cwd: executionPath)
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
            let runtimeSafeApps = await runtimeSafeApps(
                selectedApps: tasks[currentIndex].selectedApps,
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
            var runtimeTask = tasks[inputIndex]
            runtimeTask.selectedApps = runtimeSafeApps
            let input = TaskPromptBuilder.executionInput(
                for: runtimeTask,
                projectPath: executionPath,
                sourceProjectPath: project.path
            )
            let turn = try await client.startExecutionTurn(
                threadID: threadID,
                cwd: executionPath,
                input: input,
                model: tasks[inputIndex].requestedModel,
                effort: tasks[inputIndex].reasoningEffort,
                serviceTier: tasks[inputIndex].fastMode ? CodexServiceTier.fast : CodexServiceTier.standard,
                allowNetwork: preferences.allowNetworkAccess
            )
            guard let finalIndex = taskIndex(taskID),
                  tasks[finalIndex].stage == .executing,
                  !cancellationIntentTaskIDs.contains(taskID)
            else {
                try? await client.interrupt(threadID: threadID, turnID: turn.turnID)
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
            scheduleSave(immediate: true)
        } catch {
            if let failureIndex = taskIndex(taskID) {
                let kind: TaskFailureKind = error is WorktreeManagerError ? .workspace : classifyFailure(error.localizedDescription)
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

    private func handle(_ event: CodexEvent) {
        switch event {
        case let .agentDelta(threadID, turnID, delta):
            guard let index = taskIndex(threadID: threadID, turnID: turnID) else { return }
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
            guard let index = taskIndex(threadID: threadID, turnID: turnID) else { return }
            let taskID = tasks[index].id
            pendingStreamUpdates[taskID, default: PendingStreamUpdate()].turnDiffID = turnID
            pendingStreamUpdates[taskID, default: PendingStreamUpdate()].turnDiff = diff
            scheduleStreamFlush()
        case let .agentFinal(threadID, turnID, text):
            flushPendingStreamUpdates()
            guard let index = taskIndex(threadID: threadID, turnID: turnID) else { return }
            if tasks[index].stage == .planning, tasks[index].planText.isEmpty {
                tasks[index].planText = text
            } else if tasks[index].stage == .executing {
                tasks[index].resultText = text
            }
            scheduleSave(immediate: true)
        case let .planFinal(threadID, turnID, text):
            flushPendingStreamUpdates()
            guard let index = taskIndex(threadID: threadID, turnID: turnID) else { return }
            tasks[index].planText = text
            tasks[index].hasFinalPlan = true
            scheduleSave(immediate: true)
        case let .planUpdated(threadID, turnID, explanation, steps):
            guard let index = taskIndex(threadID: threadID, turnID: turnID) else { return }
            tasks[index].structuredPlan = steps
            if let explanation, !explanation.isEmpty { tasks[index].liveMessage = explanation }
            scheduleSave()
        case let .activity(threadID, turnID, message):
            guard let index = taskIndex(threadID: threadID, turnID: turnID) else { return }
            pendingStreamUpdates[tasks[index].id, default: PendingStreamUpdate()].liveMessage = message
            scheduleStreamFlush()
        case let .configurationWarning(threadID, turnID, message):
            guard let threadID,
                  let index = taskIndex(threadID: threadID, turnID: turnID) else { return }
            appendLog(at: index, message, level: .warning)
            scheduleSave(immediate: true)
        case let .warning(threadID, turnID, message):
            guard let threadID,
                  let index = taskIndex(threadID: threadID, turnID: turnID) else {
                lastError = message
                return
            }
            appendLog(at: index, message, level: .warning)
            tasks[index].lastError = message
            scheduleSave(immediate: true)
        case let .turnCompleted(threadID, turnID, status, error):
            flushPendingStreamUpdates()
            guard let index = taskIndex(threadID: threadID, turnID: turnID) else { return }
            completeTurn(at: index, turnID: turnID, status: status, error: error)
        case .threadStatus:
            break
        case let .interactionRequested(request):
            guard let index = taskIndex(threadID: request.threadID, turnID: request.turnID),
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
            guard let taskID = tasks.first(where: { $0.threadID == threadID })?.id else { return }
            removeInteraction(taskID: taskID, requestID: requestID)
            if let index = taskIndex(taskID), tasks[index].stage.isActive {
                tasks[index].liveMessage = hasPendingInteraction(for: taskID)
                    ? "Codex 仍在等待人工确认…"
                    : (tasks[index].stage == .planning ? "Codex 继续制定方案…" : "Codex 继续实施方案…")
                tasks[index].updatedAt = Date()
                scheduleSave()
            }
        case let .mcpOAuthCompleted(completion):
            oauthServersInProgress.remove(completion.serverName)
            if completion.success {
                mcpServerError = nil
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.refreshMCPServers()
                    if let projectID = self.selectedProjectID {
                        await self.refreshCapabilities(projectID: projectID, forceRefresh: true)
                    }
                }
            } else {
                mcpServerError = completion.error?.nilIfBlank
                    ?? "\(completion.serverName) OAuth 授权失败。"
            }
        case let .connectionLost(message):
            flushPendingStreamUpdates()
            resolveAllInteractionAttentions()
            pendingInteractionsByTaskID.removeAll()
            respondingRequestIDs.removeAll()
            oauthServersInProgress.removeAll()
            for index in tasks.indices where tasks[index].stage.isActive {
                failTask(
                    at: index,
                    message: "Codex 连接已断开：\(message) 请检查工作区后再继续。",
                    kind: .connection
                )
            }
            scheduleExecutionQueue()
        }
    }

    private func completeTurn(at index: Int, turnID: String, status: String, error: String?) {
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
        clearInteractions(for: tasks[index].id, turnID: turnID)
        if cancellationIntentTaskIDs.contains(tasks[index].id) {
            failTask(
                at: index,
                message: "任务已停止。",
                runOutcome: .interrupted,
                kind: .interrupted
            )
            scheduleExecutionQueue()
            return
        }
        guard status == "completed" else {
            let reason = error ?? (status == "interrupted" ? "任务已停止。" : "Codex turn 状态：\(status)")
            failTask(
                at: index,
                message: reason,
                runOutcome: status == "interrupted" ? .interrupted : .failed,
                kind: status == "interrupted" ? .interrupted : .execution
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
                return
            }
            finishActiveRun(
                at: index,
                phase: .planning,
                outcome: .completed,
                summary: tasks[index].planText
            )
            tasks[index].stage = .awaitingApproval
            tasks[index].failureState = nil
            tasks[index].executionApproved = tasks[index].autoRun
            tasks[index].liveMessage = tasks[index].autoRun ? "方案完成，已进入自动执行队列" : "方案完成，等待确认"
            appendLog(at: index, tasks[index].autoRun ? "方案完成；全自动模式已跳过确认。" : "方案已生成，等待确认。", level: .success)
            tasks[index].updatedAt = Date()
            scheduleSave(immediate: true)
            if !tasks[index].autoRun {
                addPlanAttention(taskID: tasks[index].id, createdAt: Date())
                focusTask(tasks[index].id)
            }
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

    private func normalizeInterruptedTasks() {
        for index in tasks.indices where tasks[index].stage.isActive {
            finishActiveRun(
                at: index,
                phase: tasks[index].stage == .planning ? .planning : .execution,
                outcome: .interrupted,
                summary: "应用退出时运行尚未完成。",
                error: "应用上次退出时任务仍在运行。"
            )
            tasks[index].stage = .needsAttention
            tasks[index].executionApproved = false
            tasks[index].lastError = "应用上次退出时任务仍在运行；请检查当前工作区后选择继续。"
            tasks[index].failureState = TaskFailureState(
                kind: .interrupted,
                circuitOpen: true,
                message: tasks[index].lastError ?? "运行被中断。"
            )
            appendLog(at: index, "检测到未完成的上次运行，已暂停以避免重复副作用。", level: .warning)
        }
        for index in tasks.indices where tasks[index].failureState?.nextRetryAt != nil {
            tasks[index].failureState?.nextRetryAt = nil
            tasks[index].failureState?.circuitOpen = true
            tasks[index].liveMessage = "已熔断，等待人工处理"
            appendLog(at: index, "应用重启后未自动恢复失败重试；请先检查现场。", level: .warning)
        }
        scheduleSave()
    }

    private func failTask(
        at index: Int,
        message: String,
        runOutcome: TaskRunOutcome = .failed,
        kind: TaskFailureKind? = nil,
        retryPhase: TaskRunPhase? = nil,
        automaticRetryAllowed: Bool = true
    ) {
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
        if let runIndex = tasks[index].runs.lastIndex(where: { $0.outcome.isActive }) {
            tasks[index].runs[runIndex].outcome = effectiveRunOutcome
            tasks[index].runs[runIndex].endedAt = Date()
            tasks[index].runs[runIndex].error = effectiveMessage
            if tasks[index].runs[runIndex].summary.isEmpty {
                tasks[index].runs[runIndex].summary = effectiveMessage
            }
        }
        tasks[index].stage = .needsAttention
        tasks[index].executionApproved = false
        tasks[index].lastError = effectiveMessage
        tasks[index].updatedAt = Date()
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

        if cancellationRequested {
            tasks[index].failureState = TaskFailureState(
                kind: .interrupted,
                consecutiveCount: consecutiveCount,
                automaticRetryCount: previousRetryCount,
                circuitOpen: true,
                message: effectiveMessage
            )
            tasks[index].liveMessage = "任务已停止"
        } else if mayRetry, let retryPhase = effectiveRetryPhase {
            let retryCount = previousRetryCount + 1
            let delay = retryCount == 1 ? 1 : min(8, 1 << (retryCount - 1))
            let retryAt = Date().addingTimeInterval(TimeInterval(delay))
            tasks[index].failureState = TaskFailureState(
                kind: resolvedKind,
                consecutiveCount: consecutiveCount,
                automaticRetryCount: retryCount,
                circuitOpen: false,
                nextRetryAt: retryAt,
                message: effectiveMessage
            )
            tasks[index].liveMessage = "启动失败，\(delay) 秒后自动重试 \(retryCount)/\(preferences.maxAutomaticRetries)"
            appendLog(at: index, "将在 \(delay) 秒后自动重试（\(retryCount)/\(preferences.maxAutomaticRetries)）。", level: .warning)
            scheduleAutomaticRetry(taskID: taskID, phase: retryPhase, delay: delay)
        } else {
            tasks[index].failureState = TaskFailureState(
                kind: resolvedKind,
                consecutiveCount: consecutiveCount,
                automaticRetryCount: previousRetryCount,
                circuitOpen: true,
                message: effectiveMessage
            )
            if !effectiveAutomaticRetryAllowed, effectiveRetryPhase != nil {
                tasks[index].liveMessage = "请求状态不确定，已暂停以避免重复执行"
                appendLog(
                    at: index,
                    "服务端可能已创建会话或轮次；为避免重复执行，未自动重试。",
                    level: .warning
                )
            } else {
                tasks[index].liveMessage = "已熔断，等待人工处理"
            }
            if effectiveAutomaticRetryAllowed,
               effectiveRetryPhase != nil,
               resolvedKind == .startup || resolvedKind == .connection,
               preferences.maxAutomaticRetries > 0 {
                appendLog(at: index, "自动重试次数已用尽，熔断器已打开。", level: .warning)
            }
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

    private func taskIndex(threadID: String, turnID: String?) -> Int? {
        tasks.firstIndex { task in
            guard task.threadID == threadID else { return false }
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
        respondingRequestIDs.remove(requestID)
        resolveInteractionAttention(taskID: taskID, requestID: requestID)
    }

    private func clearInteractions(for taskID: UUID, turnID: String? = nil) {
        guard let turnID else {
            let requests = pendingInteractionsByTaskID.removeValue(forKey: taskID) ?? []
            requests.forEach { request in
                respondingRequestIDs.remove(request.id)
                resolveInteractionAttention(taskID: taskID, requestID: request.id)
            }
            return
        }
        guard var requests = pendingInteractionsByTaskID[taskID] else { return }
        let removed = requests.filter { $0.turnID == nil || $0.turnID == turnID }
        requests.removeAll { $0.turnID == nil || $0.turnID == turnID }
        removed.forEach { request in
            respondingRequestIDs.remove(request.id)
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
        let key = InteractionAttentionKey(taskID: taskID, requestID: requestID)
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
        let key = InteractionAttentionKey(taskID: taskID, requestID: requestID)
        guard let noticeID = interactionAttentionIDs.removeValue(forKey: key) else { return }
        attentionNotices.removeAll { $0.id == noticeID }
    }

    private func resolveAllInteractionAttentions() {
        let noticeIDs = Set(interactionAttentionIDs.values)
        interactionAttentionIDs.removeAll()
        attentionNotices.removeAll { noticeIDs.contains($0.id) }
    }

    private func addPlanAttention(taskID: UUID, createdAt: Date) {
        guard planAttentionIDs[taskID] == nil else { return }
        let notice = TaskAttentionNotice(
            id: UUID(),
            taskID: taskID,
            kind: .planApproval,
            createdAt: createdAt
        )
        planAttentionIDs[taskID] = notice.id
        attentionNotices.append(notice)
    }

    private func rebuildPlanAttentions() {
        let existingNoticeIDs = Set(planAttentionIDs.values)
        planAttentionIDs.removeAll()
        attentionNotices.removeAll { existingNoticeIDs.contains($0.id) }

        let waitingTasks = tasks
            .filter {
                $0.stage == .awaitingApproval
                    && !$0.executionApproved
                    && $0.hasFinalPlan
                    && !$0.planText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { $0.updatedAt < $1.updatedAt }
        for task in waitingTasks {
            addPlanAttention(taskID: task.id, createdAt: task.updatedAt)
        }
        if let newest = waitingTasks.last {
            focusTask(newest.id)
        }
    }

    private func resolvePlanAttention(taskID: UUID) {
        guard let noticeID = planAttentionIDs.removeValue(forKey: taskID) else { return }
        attentionNotices.removeAll { $0.id == noticeID }
    }

    private func cancelPendingInteractions(for taskID: UUID) async {
        let requests = pendingInteractionsByTaskID[taskID] ?? []
        for request in requests {
            guard let response = cancellationResponse(for: request) else { continue }
            do {
                try await client.respond(to: request.id, with: response)
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
            let threadID = tasks.first(where: { $0.id == taskID })?.threadID
            let currentCatalog = try await client.listApps(
                forceRefresh: true,
                threadID: threadID
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

    private var managedWorktreePaths: [String] {
        tasks.compactMap { task in
            guard task.workspace.kind == .worktree else { return nil }
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

    private static func isSameOrDescendant(_ path: String, of ancestor: String) -> Bool {
        let pathComponents = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .pathComponents
        let ancestorComponents = URL(fileURLWithPath: ancestor, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .pathComponents
        guard ancestorComponents.count <= pathComponents.count else { return false }
        return pathComponents.prefix(ancestorComponents.count).elementsEqual(ancestorComponents)
    }

    @discardableResult
    private func beginRun(at taskIndex: Int, phase: TaskRunPhase) -> UUID {
        let run = TaskRun(
            phase: phase,
            attempt: tasks[taskIndex].runs.count(where: { $0.phase == phase }) + 1,
            threadID: tasks[taskIndex].threadID,
            sessionID: tasks[taskIndex].sessionID,
            model: tasks[taskIndex].actualModel ?? tasks[taskIndex].requestedModel.nilIfEmpty,
            reasoningEffort: tasks[taskIndex].reasoningEffort,
            fastMode: tasks[taskIndex].fastMode
        )
        tasks[taskIndex].runs.append(run)
        return run.id
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

    private func persistLatestSnapshot() async {
        saveTask = nil
        guard !isSaving, savedRevision < saveRevision else { return }
        isSaving = true
        let revision = saveRevision
        let snapshot = BoardSnapshot(
            version: BoardSnapshot.currentVersion,
            tasks: tasks,
            manualProjectPaths: manualProjectPaths,
            preferences: preferences,
            hiddenProjectPaths: hiddenProjectPaths.sorted()
        )
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

        guard succeeded, savedRevision < saveRevision else {
            saveImmediatelyAfterCurrentWrite = false
            return
        }
        let immediate = saveImmediatelyAfterCurrentWrite
        saveImmediatelyAfterCurrentWrite = false
        scheduleSaveWithoutRevision(immediate: immediate)
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
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
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
