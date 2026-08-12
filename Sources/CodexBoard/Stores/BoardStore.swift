import AppKit
import Combine
import Foundation

@MainActor
final class BoardStore: ObservableObject {
    @Published private(set) var projects: [ProjectRecord] = []
    @Published private(set) var tasks: [BoardTask] = []
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

    let client: any CodexTaskClient
    private let persistence: BoardPersistence
    private let discovery: ProjectDiscoveryService
    private var manualProjectPaths: [String] = []
    private var eventTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var didStart = false

    init(
        client: any CodexTaskClient = CodexAppServerClient(),
        persistence: BoardPersistence = BoardPersistence(),
        discovery: ProjectDiscoveryService = ProjectDiscoveryService()
    ) {
        self.client = client
        self.persistence = persistence
        self.discovery = discovery
    }

    deinit {
        eventTask?.cancel()
        saveTask?.cancel()
    }

    var selectedProject: ProjectRecord? {
        selectedProjectID.flatMap { id in projects.first(where: { $0.id == id }) }
    }

    var selectedTask: BoardTask? {
        selectedTaskID.flatMap { id in tasks.first(where: { $0.id == id }) }
    }

    var visibleProjects: [ProjectRecord] {
        projects.filter { preferences.showMissingProjects || $0.existsOnDisk }
    }

    var filteredTasks: [BoardTask] {
        guard let selectedProjectID else { return tasks }
        return tasks.filter { $0.projectID == selectedProjectID }
    }

    var activeExecutionCount: Int {
        tasks.count(where: { $0.stage == .executing })
    }

    func tasks(in stage: TaskStage) -> [BoardTask] {
        filteredTasks
            .filter { $0.stage == stage }
            .sorted { $0.updatedAt > $1.updatedAt }
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

    func addManualProject(path: String) {
        let normalized = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        guard !manualProjectPaths.contains(normalized) else { return }
        manualProjectPaths.append(normalized)
        scheduleSave()
        Task { @MainActor [weak self] in await self?.refreshProjects() }
    }

    func removeManualProject(_ project: ProjectRecord) {
        guard project.isManual else { return }
        manualProjectPaths.removeAll { $0 == project.path }
        scheduleSave()
        Task { @MainActor [weak self] in await self?.refreshProjects() }
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
        guard !body.isEmpty, projects.contains(where: { $0.id == projectID }) else { return nil }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let derivedTitle = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? sourceKind.title
        var task = BoardTask(
            projectID: projectID,
            title: cleanTitle.isEmpty ? String(derivedTitle.prefix(80)) : cleanTitle,
            sourceKind: sourceKind,
            sourceText: body,
            autoRun: autoRun
        )
        task.logs.append(TaskLogEntry(message: "任务已加入看板。"))
        tasks.append(task)
        selectedProjectID = projectID
        selectedTaskID = task.id
        scheduleSave()
        Task { @MainActor [weak self] in await self?.startPlanning(taskID: task.id) }
        return task.id
    }

    func startPlanning(taskID: UUID) async {
        guard let index = taskIndex(taskID), let project = project(forTaskAt: index) else { return }
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
        tasks[index].liveMessage = "正在连接本机 Codex…"
        tasks[index].lastError = nil
        tasks[index].updatedAt = Date()
        appendLog(at: index, "开始只读规划。")
        scheduleSave()

        do {
            let startedThread: CodexStartedThread
            if let existingThread = tasks[index].threadID {
                startedThread = try await client.resumeThread(threadID: existingThread, cwd: project.path)
            } else {
                startedThread = try await client.startThread(
                    cwd: project.path,
                    model: preferences.modelOverride.nilIfEmpty
                )
                try? await client.setThreadName(
                    threadID: startedThread.threadID,
                    name: "CodexBoard · \(tasks[index].title)"
                )
            }
            guard let currentIndex = taskIndex(taskID) else { return }
            tasks[currentIndex].threadID = startedThread.threadID
            tasks[currentIndex].sessionID = startedThread.sessionID
            tasks[currentIndex].model = startedThread.model
            tasks[currentIndex].liveMessage = "Codex 正在检查项目并制定方案…"
            scheduleSave()

            let prompt = TaskPromptBuilder.planningPrompt(for: tasks[currentIndex], projectPath: project.path)
            let turn = try await client.startPlanningTurn(
                threadID: startedThread.threadID,
                cwd: project.path,
                prompt: prompt,
                model: startedThread.model,
                effort: preferences.planningEffort
            )
            guard let finalIndex = taskIndex(taskID) else { return }
            tasks[finalIndex].planningTurnID = turn.turnID
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
        guard let index = taskIndex(taskID),
              !tasks[index].stage.isActive,
              tasks[index].hasFinalPlan,
              !tasks[index].planText.isEmpty
        else { return }
        tasks[index].executionTurnID = nil
        tasks[index].stage = .awaitingApproval
        tasks[index].executionApproved = true
        appendLog(at: index, "已请求从当前工作区状态继续执行。")
        scheduleSave()
        scheduleExecutionQueue()
    }

    func cancel(taskID: UUID) async {
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
        guard project.existsOnDisk else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
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
            Task { @MainActor [weak self] in await self?.performExecution(taskID: taskID) }
        }
        scheduleSave()
    }

    private func performExecution(taskID: UUID) async {
        guard let index = taskIndex(taskID), let project = project(forTaskAt: index), let threadID = tasks[index].threadID else {
            if let index = taskIndex(taskID) { failTask(at: index, message: "缺少可恢复的 Codex thread。") }
            return
        }
        do {
            let resumed = try await client.resumeThread(threadID: threadID, cwd: project.path)
            guard let currentIndex = taskIndex(taskID) else { return }
            tasks[currentIndex].sessionID = resumed.sessionID
            tasks[currentIndex].model = resumed.model
            tasks[currentIndex].resultText = ""
            tasks[currentIndex].liveMessage = "Codex 正在实施方案…"
            let prompt = TaskPromptBuilder.executionPrompt(for: tasks[currentIndex], projectPath: project.path)
            let turn = try await client.startExecutionTurn(
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
            scheduleSave()
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
            if tasks[index].stage == .planning {
                tasks[index].planText += delta
            } else if tasks[index].stage == .executing {
                tasks[index].resultText += delta
            }
            scheduleSave()
        case let .agentFinal(threadID, turnID, text):
            guard let index = taskIndex(threadID: threadID, turnID: turnID) else { return }
            if tasks[index].stage == .planning, tasks[index].planText.isEmpty {
                tasks[index].planText = text
            } else if tasks[index].stage == .executing {
                tasks[index].resultText = text
            }
            scheduleSave()
        case let .planFinal(threadID, turnID, text):
            guard let index = taskIndex(threadID: threadID, turnID: turnID) else { return }
            tasks[index].planText = text
            tasks[index].hasFinalPlan = true
            scheduleSave()
        case let .planUpdated(threadID, turnID, explanation, steps):
            guard let index = taskIndex(threadID: threadID, turnID: turnID) else { return }
            tasks[index].structuredPlan = steps
            if let explanation, !explanation.isEmpty { tasks[index].liveMessage = explanation }
            scheduleSave()
        case let .activity(threadID, turnID, message):
            guard let index = taskIndex(threadID: threadID, turnID: turnID) else { return }
            tasks[index].liveMessage = message
        case let .warning(threadID, turnID, message):
            guard let threadID,
                  let index = taskIndex(threadID: threadID, turnID: turnID) else {
                lastError = message
                return
            }
            appendLog(at: index, message, level: .warning)
            tasks[index].lastError = message
            scheduleSave()
        case let .turnCompleted(threadID, turnID, status, error):
            guard let index = taskIndex(threadID: threadID, turnID: turnID) else { return }
            completeTurn(at: index, turnID: turnID, status: status, error: error)
        case .threadStatus:
            break
        case let .connectionLost(message):
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

    private func normalizeInterruptedTasks() {
        for index in tasks.indices where tasks[index].stage.isActive {
            tasks[index].stage = .needsAttention
            tasks[index].executionApproved = false
            tasks[index].lastError = "应用上次退出时任务仍在运行；请检查当前工作区后选择继续。"
            appendLog(at: index, "检测到未完成的上次运行，已暂停以避免重复副作用。", level: .warning)
        }
        scheduleSave()
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

    private func scheduleSave() {
        guard didStart else { return }
        saveTask?.cancel()
        let snapshot = BoardSnapshot(
            version: 1,
            tasks: tasks,
            manualProjectPaths: manualProjectPaths,
            preferences: preferences
        )
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

    private func shortID(_ value: String) -> String {
        String(value.prefix(8))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
