import SwiftUI
import UniformTypeIdentifiers

struct BoardView: View {
    let store: BoardStore
    @Binding var showingComposer: Bool

    private let columns: [TaskStage] = [
        .inbox, .planning, .awaitingApproval, .executing, .review, .completed, .needsAttention
    ]

    var body: some View {
        let selectedProject = store.selectedProject
        let tasksByStage = groupedTasks
        let attentionTaskIDs = Set(store.attentionNotices.map(\.taskID))

        VStack(spacing: 0) {
            boardHeader(project: selectedProject)
            Divider()
            if selectedProject == nil {
                emptyProjectState
            } else {
                ScrollViewReader { stageProxy in
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(columns) { stage in
                                BoardColumn(
                                    stage: stage,
                                    tasks: tasksByStage[stage, default: []],
                                    selectedTaskID: store.selectedTaskID,
                                    attentionTaskIDs: attentionTaskIDs,
                                    focusRequest: store.taskFocusRequest,
                                    selectTask: { store.selectedTaskID = $0 },
                                    moveTask: { store.moveTask(taskID: $0, to: $1) },
                                    startPlanning: { taskID in
                                        Task { await store.startPlanning(taskID: taskID) }
                                    },
                                    confirmPlan: { store.confirmPlan(taskID: $0) },
                                    cancelTask: { taskID in
                                        Task { await store.cancel(taskID: taskID) }
                                    },
                                    continueExecution: { store.continueExecution(taskID: $0) },
                                    acceptReview: { store.acceptReview(taskID: $0) },
                                    deleteTask: { store.deleteTask(taskID: $0) }
                                )
                                .frame(width: 274)
                                .id(stage)
                            }
                        }
                        .padding(18)
                    }
                    .scrollIndicators(.visible)
                    .onChange(of: store.taskFocusRequest, initial: true) { _, request in
                        guard let request, columns.contains(request.stage) else { return }
                        withAnimation(.easeInOut(duration: 0.25)) {
                            stageProxy.scrollTo(request.stage, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var groupedTasks: [TaskStage: [BoardTaskCard]] {
        var result = Dictionary(uniqueKeysWithValues: columns.map { ($0, [BoardTaskCard]()) })
        for task in store.filteredTaskCards.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            result[task.stage, default: []].append(task)
        }
        return result
    }

    private func boardHeader(project: ProjectRecord?) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(project?.name ?? L10n.text("项目看板", fallback: "项目看板"))
                    .font(.title2.weight(.semibold))
                if let project {
                    Text(BoardFormatters.displayPath(project.path))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if store.activeExecutionCount > 0 {
                Label("\(store.activeExecutionCount) 个任务运行中", systemImage: "bolt.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(BoardTheme.executing)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(BoardTheme.executing.opacity(0.12), in: Capsule())
            }
            Toggle("全自动", isOn: Binding(
                get: { store.preferences.defaultAutoRun },
                set: { value in store.updatePreferences { $0.defaultAutoRun = value } }
            ))
            .toggleStyle(.switch)
            .help("新任务会立即开始规划，并在方案完成后自动进入执行队列")

            Button("新建任务") { showingComposer = true }
                .buttonStyle(.borderedProminent)
                .tint(BoardTheme.accent)
                .disabled(store.selectedProject == nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var emptyProjectState: some View {
        ContentUnavailableView {
            Label("没有可用项目", systemImage: "folder.badge.questionmark")
        } description: {
            Text("等待本机 Codex 项目扫描完成，或从侧边栏添加一个项目文件夹。")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BoardColumn: View {
    let stage: TaskStage
    let tasks: [BoardTaskCard]
    let selectedTaskID: UUID?
    let attentionTaskIDs: Set<UUID>
    let focusRequest: TaskFocusRequest?
    let selectTask: (UUID) -> Void
    let moveTask: (UUID, TaskStage) -> Bool
    let startPlanning: (UUID) -> Void
    let confirmPlan: (UUID) -> Void
    let cancelTask: (UUID) -> Void
    let continueExecution: (UUID) -> Void
    let acceptReview: (UUID) -> Void
    let deleteTask: (UUID) -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: stage.symbol)
                    .foregroundStyle(BoardTheme.color(for: stage))
                Text(stage.title)
                    .font(.headline)
                Text(tasks.count.formatted())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                Spacer()
            }

            ScrollViewReader { taskProxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(tasks) { task in
                            TaskCard(
                                task: task,
                                isSelected: selectedTaskID == task.id,
                                needsAttention: attentionTaskIDs.contains(task.id),
                                selectTask: { selectTask(task.id) },
                                startPlanning: { startPlanning(task.id) },
                                confirmPlan: { confirmPlan(task.id) },
                                cancelTask: { cancelTask(task.id) },
                                continueExecution: { continueExecution(task.id) },
                                acceptReview: { acceptReview(task.id) },
                                deleteTask: { deleteTask(task.id) }
                            )
                            .draggable(task.id.uuidString)
                            .id(task.id)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onChange(of: focusRequest, initial: true) { _, request in
                    guard let request,
                          request.stage == stage,
                          tasks.contains(where: { $0.id == request.taskID })
                    else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        taskProxy.scrollTo(request.taskID, anchor: .top)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isTargeted ? BoardTheme.color(for: stage).opacity(0.10) : Color(nsColor: .controlBackgroundColor).opacity(0.72))
                .stroke(isTargeted ? BoardTheme.color(for: stage) : Color.clear, lineWidth: 1.5)
        )
        .dropDestination(for: String.self) { values, _ in
            guard stage.allowsManualDrop,
                  let raw = values.first,
                  let id = UUID(uuidString: raw)
            else { return false }
            return moveTask(id, stage)
        } isTargeted: { isTargeted = $0 }
    }
}

private struct TaskCard: View {
    let task: BoardTaskCard
    let isSelected: Bool
    let needsAttention: Bool
    let selectTask: () -> Void
    let startPlanning: () -> Void
    let confirmPlan: () -> Void
    let cancelTask: () -> Void
    let continueExecution: () -> Void
    let acceptReview: () -> Void
    let deleteTask: () -> Void

    var body: some View {
        Button(action: selectTask) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: task.sourceKind.symbol)
                        .foregroundStyle(BoardTheme.color(for: task.stage))
                    Text(task.sourceKind.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if needsAttention {
                        Label("待响应", systemImage: "bell.badge.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(BoardTheme.approval)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(BoardTheme.approval.opacity(0.14), in: Capsule())
                            .fixedSize()
                            .help("此任务需要人工响应")
                    }
                    if task.autoRun {
                        Image(systemName: "bolt.fill")
                            .font(.caption)
                            .foregroundStyle(BoardTheme.executing)
                            .help("全自动")
                    }
                }

                Text(task.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)

                if task.attachmentCount > 0 {
                    Label("\(task.attachmentCount) 个附件", systemImage: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if task.workspaceKind == .worktree || task.dependencyCount > 0 || task.circuitOpen {
                    HStack(spacing: 10) {
                        if task.workspaceKind == .worktree {
                            Label("Worktree", systemImage: "arrow.triangle.branch")
                        }
                        if task.dependencyCount > 0 {
                            Label(
                                task.blockingDependencyCount > 0
                                    ? "等待 \(task.blockingDependencyCount)"
                                    : "依赖已满足",
                                systemImage: "point.3.connected.trianglepath.dotted"
                            )
                        }
                        if task.circuitOpen {
                            Label("已熔断", systemImage: "bolt.slash")
                                .foregroundStyle(BoardTheme.danger)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if task.executionAttemptCount > 0 || task.hasDeliveryEvidence {
                    HStack(spacing: 10) {
                        if task.executionAttemptCount > 0 {
                            Label("执行 #\(task.executionAttemptCount)", systemImage: "arrow.triangle.2.circlepath")
                        }
                        if task.hasDeliveryEvidence {
                            Label("交付物", systemImage: "shippingbox")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if !task.liveMessage.isEmpty {
                    Text(L10n.localizedRuntimeText(task.liveMessage))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }

                if task.stage.isActive {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(BoardTheme.color(for: task.stage))
                }

                HStack {
                    Text(BoardFormatters.relativeDate(task.updatedAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if let model = task.model {
                        Text(model)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        isSelected
                            ? BoardTheme.accent.opacity(0.10)
                            : Color(nsColor: .textBackgroundColor)
                    )
                    .shadow(
                        color: isSelected ? BoardTheme.accent.opacity(0.18) : .black.opacity(0.06),
                        radius: isSelected ? 6 : 4,
                        y: 2
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(isSelected ? BoardTheme.accent : Color.clear, lineWidth: 2)
            }
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(BoardTheme.color(for: task.stage))
                    .frame(width: 3)
                    .padding(.vertical, 8)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            if task.stage == .inbox {
                Button("开始规划", action: startPlanning)
                    .disabled(task.blockingDependencyCount > 0)
            }
            if task.stage == .awaitingApproval, !task.executionApproved {
                Button("确认并执行", action: confirmPlan)
            }
            if task.stage == .review {
                Button("验收完成", action: acceptReview)
            }
            if task.stage.isActive {
                Button("停止", role: .destructive, action: cancelTask)
            }
            if task.canContinueExecution {
                Button("从当前状态继续", action: continueExecution)
            }
            Button("删除卡片", role: .destructive, action: deleteTask)
                .disabled(task.stage.isActive)
        }
    }
}
