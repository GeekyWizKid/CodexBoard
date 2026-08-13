import AppKit
import Foundation
import Observation

enum BoardStoreError: LocalizedError {
    case invalidProject
    case emptyTask

    var errorDescription: String? {
        switch self {
        case .invalidProject: "所选项目不存在或已不可用。"
        case .emptyTask: "请输入任务内容或至少添加一个附件。"
        }
    }
}

private struct PendingStreamUpdate {
    var planDelta = ""
    var resultDelta = ""
    var liveMessage: String?

    var changesPersistedContent: Bool {
        !planDelta.isEmpty || !resultDelta.isEmpty
    }
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
            guard selectedProjectID != oldValue,
                  let selectedTaskID,
                  tasks.first(where: { $0.id == selectedTaskID })?.projectID != selectedProjectID
            else { return }
            self.selectedTaskID = nil
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

    @ObservationIgnored
    let client: any CodexTaskClient
    @ObservationIgnored
    private let persistence: any BoardPersisting
    @ObservationIgnored
    private let discovery: ProjectDiscoveryService
    @ObservationIgnored
    private let attachmentStorage: AttachmentStorage
    @ObservationIgnored
    private var manualProjectPaths: [String] = []
    @ObservationIgnored
    private var eventTask: Task<Void, Never>?
    @ObservationIgnored
    private var saveTask: Task<Void, Never>?
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

    init(
        client: any CodexTaskClient = CodexAppServerClient(),
        persistence: any BoardPersisting = BoardPersistence(),
        discovery: ProjectDiscoveryService = ProjectDiscoveryService(),
        attachmentStorage: AttachmentStorage = AttachmentStorage()
    ) {
        self.client = client
        self.persistence = persistence
        self.discovery = discovery
        self.attachmentStorage = attachmentStorage
    }

    deinit {
        eventTask?.cancel()
        saveTask?.cancel()
        streamFlushTask?.cancel()
    }

    var selectedProject: ProjectRecord? {
        selectedProjectID.flatMap { id in projects.first(where: { $0.id == id }) }
    }

    var visibleProjects: [ProjectRecord] {
        projects.filter { preferences.showMissingProjects || $0.existsOnDisk }
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

    func focusTask(_ taskID: UUID) {
        guard let task = taskCards.first(where: { $0.id == taskID }) else { return }
        selectedProjectID = task.projectID
        selectedTaskID = taskID
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
            projects = await discovery.discover(threads: threads, manualPaths: manualProjectPaths)
            selectInitialProjectIfNeeded()
            statusMessage = "已载入 \(projects.count) 个项目"
            lastError = nil
        } catch {
            accountReady = false
            lastError = error.localizedDescription
            statusMessage = "项目扫描失败"
            projects = await discovery.discover(threads: [], manualPaths: manualProjectPaths)
            selectInitialProjectIfNeeded()
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

    func addManualProject(path: String) {
        let normalized = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        manualProjectPaths.removeAll { $0 == normalized }
        manualProjectPaths.insert(normalized, at: 0)
        scheduleSave()
        Task { @MainActor [weak self] in await self?.refreshProjects() }
    }

    func removeManualProject(_ project: ProjectRecord) {
        guard project.isManual else { return }
        manualProjectPaths.removeAll { manualPath in
            let components = URL(fileURLWithPath: manualPath).standardizedFileURL.pathComponents
            let projectComponents = URL(fileURLWithPath: project.path).standardizedFileURL.pathComponents
            return components.count >= projectComponents.count
                && components.prefix(projectComponents.count).elementsEqual(projectComponents)
        }
        scheduleSave()
        Task { @MainActor [weak self] in await self?.refreshProjects() }
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
        fastMode: Bool = false
    ) async throws -> UUID {
        let body = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !attachmentDrafts.isEmpty else { throw BoardStoreError.emptyTask }
        guard projects.contains(where: { $0.id == projectID }) else { throw BoardStoreError.invalidProject }
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
            autoRun: autoRun,
            requestedModel: resolvedModel(model),
            reasoningEffort: effort ?? preferences.planningEffort,
            fastMode: fastMode
        )
        task.logs.append(TaskLogEntry(message: "任务已加入看板。"))
        tasks.append(task)
        selectedProjectID = projectID
        selectedTaskID = task.id
        scheduleSave(immediate: true)
        Task { @MainActor [weak self] in await self?.startPlanning(taskID: task.id) }
        return task.id
    }

    func startPlanning(taskID: UUID) async {
        discardPendingStreamUpdate(for: taskID)
        guard let index = taskIndex(taskID), let project = project(forTaskAt: index) else { return }
        guard project.existsOnDisk else {
            failTask(at: index, message: "项目目录不存在：\(project.path)")
            return
        }
        guard !tasks[index].stage.isActive else { return }

        do {
            try await attachmentStorage.validate(tasks[index].attachments)
        } catch {
            failTask(at: index, message: error.localizedDescription)
            return
        }

        tasks[index].stage = .planning
        tasks[index].executionApproved = false
        tasks[index].planText = ""
        tasks[index].hasFinalPlan = false
        tasks[index].structuredPlan = []
        tasks[index].planningTurnID = nil
        tasks[index].executionTurnID = nil
        tasks[index].liveMessage = "正在连接本机 Codex…"
        tasks[index].lastError = nil
        tasks[index].updatedAt = Date()
        appendLog(at: index, "开始只读规划。")
        let planningRunID = beginRun(at: index, phase: .planning)
        scheduleSave()

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

            let input = TaskPromptBuilder.planningInput(for: tasks[currentIndex], projectPath: project.path)
            let turn = try await client.startPlanningTurn(
                threadID: startedThread.threadID,
                cwd: project.path,
                input: input,
                model: tasks[currentIndex].requestedModel,
                effort: tasks[currentIndex].reasoningEffort,
                serviceTier: tasks[currentIndex].fastMode ? CodexServiceTier.fast : CodexServiceTier.standard
            )
            guard let finalIndex = taskIndex(taskID) else { return }
            tasks[finalIndex].planningTurnID = turn.turnID
            updateRun(at: finalIndex, runID: planningRunID) { run in
                run.turnID = turn.turnID
            }
            appendLog(at: finalIndex, "规划会话已启动：\(shortID(turn.turnID))")
            scheduleSave()
        } catch {
            if let failureIndex = taskIndex(taskID) {
                failTask(at: failureIndex, message: error.localizedDescription)
            }
        }
    }

    func confirmPlan(taskID: UUID) {
        guard let index = taskIndex(taskID),
              tasks[index].stage == .awaitingApproval,
              tasks[index].hasFinalPlan,
              !tasks[index].planText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
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
        appendLog(at: index, "方案已手动修改，需要重新确认。", level: .warning)
        scheduleSave(immediate: true)
        return true
    }

    func revisePlan(taskID: UUID) {
        guard let index = taskIndex(taskID), !tasks[index].stage.isActive else { return }
        tasks[index].stage = .inbox
        tasks[index].executionApproved = false
        tasks[index].updatedAt = Date()
        appendLog(at: index, "方案退回，准备重新规划。", level: .warning)
        scheduleSave(immediate: true)
        Task { @MainActor [weak self] in await self?.startPlanning(taskID: taskID) }
    }

    func continueExecution(taskID: UUID) {
        guard let index = taskIndex(taskID),
              !tasks[index].stage.isActive,
              tasks[index].hasFinalPlan,
              !tasks[index].planText.isEmpty
        else { return }
        tasks[index].executionTurnID = nil
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
        guard let index = taskIndex(taskID),
              let threadID = tasks[index].threadID,
              let turnID = tasks[index].stage == .planning
                ? tasks[index].planningTurnID
                : tasks[index].executionTurnID
        else { return }
        do {
            try await client.interrupt(threadID: threadID, turnID: turnID)
            appendLog(at: index, "已发送停止请求。", level: .warning)
        } catch {
            appendLog(at: index, "停止失败：\(error.localizedDescription)", level: .error)
        }
        scheduleSave(immediate: true)
    }

    func deleteTask(taskID: UUID) {
        discardPendingStreamUpdate(for: taskID)
        guard let index = taskIndex(taskID), !tasks[index].stage.isActive else { return }
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
        tasks[index].updatedAt = Date()
        appendLog(at: index, "手动移至“\(stage.title)”。")
        scheduleSave(immediate: true)
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

    func openTaskInCodex(_ task: BoardTask) {
        guard let threadID = task.threadID,
              let url = URL(string: "codex://thread/\(threadID)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func loadAndConnect() async {
        do {
            let snapshot = try await persistence.load()
            tasks = snapshot.tasks
            manualProjectPaths = snapshot.manualProjectPaths
            preferences = snapshot.preferences
            normalizeInterruptedTasks()
        } catch {
            lastError = error.localizedDescription
        }
        await refreshProjects()
        scheduleExecutionQueue()
    }

    private func scheduleExecutionQueue() {
        let available = max(0, preferences.maxConcurrentExecutions - activeExecutionCount)
        guard available > 0 else { return }
        var occupiedProjects = Set(
            tasks.lazy
                .filter { $0.stage == .executing }
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
            guard !occupiedProjects.contains(tasks[index].projectID) else { continue }
            occupiedProjects.insert(tasks[index].projectID)
            queued.append(index)
            if queued.count == available { break }
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
            if let index = taskIndex(taskID) { failTask(at: index, message: "缺少可恢复的 Codex thread。") }
            return
        }
        do {
            try await attachmentStorage.validate(tasks[index].attachments)
            let resumed = try await client.resumeThread(threadID: threadID, cwd: project.path)
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
            let input = TaskPromptBuilder.executionInput(for: tasks[currentIndex], projectPath: project.path)
            let turn = try await client.startExecutionTurn(
                threadID: threadID,
                cwd: project.path,
                input: input,
                model: tasks[currentIndex].requestedModel,
                effort: tasks[currentIndex].reasoningEffort,
                serviceTier: tasks[currentIndex].fastMode ? CodexServiceTier.fast : CodexServiceTier.standard,
                allowNetwork: preferences.allowNetworkAccess
            )
            guard let finalIndex = taskIndex(taskID) else { return }
            tasks[finalIndex].executionTurnID = turn.turnID
            updateRun(at: finalIndex, runID: runID) { run in
                run.turnID = turn.turnID
            }
            appendLog(at: finalIndex, "执行会话已启动：\(shortID(turn.turnID))")
            scheduleSave(immediate: true)
        } catch {
            if let failureIndex = taskIndex(taskID) {
                failTask(at: failureIndex, message: error.localizedDescription)
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
        case let .connectionLost(message):
            flushPendingStreamUpdates()
            for index in tasks.indices where tasks[index].stage.isActive {
                failTask(
                    at: index,
                    message: "Codex 连接已断开：\(message) 请检查工作区后再继续。"
                )
            }
            scheduleExecutionQueue()
        }
    }

    private func completeTurn(at index: Int, turnID: String, status: String, error: String?) {
        let isPlanning = tasks[index].planningTurnID == turnID || tasks[index].stage == .planning
        guard status == "completed" else {
            let reason = error ?? (status == "interrupted" ? "任务已停止。" : "Codex turn 状态：\(status)")
            failTask(
                at: index,
                message: reason,
                runOutcome: status == "interrupted" ? .interrupted : .failed
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
                failTask(at: index, message: "规划轮已结束，但没有收到可确认的最终方案。")
                return
            }
            finishActiveRun(
                at: index,
                phase: .planning,
                outcome: .completed,
                summary: tasks[index].planText
            )
            tasks[index].stage = .awaitingApproval
            tasks[index].executionApproved = tasks[index].autoRun
            tasks[index].liveMessage = tasks[index].autoRun ? "方案完成，已进入自动执行队列" : "方案完成，等待确认"
            appendLog(at: index, tasks[index].autoRun ? "方案完成；全自动模式已跳过确认。" : "方案已生成，等待确认。", level: .success)
            tasks[index].updatedAt = Date()
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
            tasks[index].stage = .review
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
            appendLog(at: index, "检测到未完成的上次运行，已暂停以避免重复副作用。", level: .warning)
        }
        scheduleSave()
    }

    private func failTask(
        at index: Int,
        message: String,
        runOutcome: TaskRunOutcome = .failed
    ) {
        pendingStreamUpdates.removeValue(forKey: tasks[index].id)
        if let runIndex = tasks[index].runs.lastIndex(where: { $0.outcome.isActive }) {
            tasks[index].runs[runIndex].outcome = runOutcome
            tasks[index].runs[runIndex].endedAt = Date()
            tasks[index].runs[runIndex].error = message
            if tasks[index].runs[runIndex].summary.isEmpty {
                tasks[index].runs[runIndex].summary = message
            }
        }
        tasks[index].stage = .needsAttention
        tasks[index].executionApproved = false
        tasks[index].lastError = message
        tasks[index].liveMessage = "需要处理"
        tasks[index].updatedAt = Date()
        appendLog(at: index, message, level: .error)
        scheduleSave(immediate: true)
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

    private func project(forTaskAt index: Int) -> ProjectRecord? {
        projects.first(where: { $0.id == tasks[index].projectID })
    }

    private func selectInitialProjectIfNeeded() {
        if let selectedProjectID, projects.contains(where: { $0.id == selectedProjectID }) { return }
        selectedProjectID = projects.first(where: { project in
            tasks.contains(where: { $0.projectID == project.id })
        })?.id ?? visibleProjects.first?.id
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
        let nextCards = tasks.map(BoardTaskCard.init)
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
            preferences: preferences
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
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
