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

        VStack(spacing: 0) {
            boardHeader(project: selectedProject)
            Divider()
            if selectedProject == nil {
                emptyProjectState
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(columns) { stage in
                            BoardColumn(
                                stage: stage,
                                tasks: tasksByStage[stage, default: []],
                                selectTask: { store.selectedTaskID = $0 },
                                moveTask: { store.moveTask(taskID: $0, to: $1) },
                                confirmPlan: { store.confirmPlan(taskID: $0) },
                                cancelTask: { taskID in
                                    Task { await store.cancel(taskID: taskID) }
                                },
                                continueExecution: { store.continueExecution(taskID: $0) },
                                acceptReview: { store.acceptReview(taskID: $0) },
                                deleteTask: { store.deleteTask(taskID: $0) }
                            )
                                .frame(width: 274)
                        }
                    }
                    .padding(18)
                }
                .scrollIndicators(.visible)
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
                Text(project?.name ?? "项目看板")
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
            .help("新任务完成规划后自动进入执行队列")

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
    let selectTask: (UUID) -> Void
    let moveTask: (UUID, TaskStage) -> Bool
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

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(tasks) { task in
                        TaskCard(
                            task: task,
                            selectTask: { selectTask(task.id) },
                            confirmPlan: { confirmPlan(task.id) },
                            cancelTask: { cancelTask(task.id) },
                            continueExecution: { continueExecution(task.id) },
                            acceptReview: { acceptReview(task.id) },
                            deleteTask: { deleteTask(task.id) }
                        )
                            .draggable(task.id.uuidString)
                    }
                }
            }
            .scrollIndicators(.hidden)
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
    let selectTask: () -> Void
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

                if task.executionAttemptCount > 0 || task.hasDeliveryEvidence {
                    HStack(spacing: 10) {
                        if task.executionAttemptCount > 0 {
                            Label("执行 #\(task.executionAttemptCount)", systemImage: "arrow.triangle.2.circlepath")
                        }
                        if task.hasDeliveryEvidence {
                            Label("交付证据", systemImage: "checkmark.seal")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if !task.liveMessage.isEmpty {
                    Text(task.liveMessage)
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
                    .fill(Color(nsColor: .textBackgroundColor))
                    .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(BoardTheme.color(for: task.stage))
                    .frame(width: 3)
                    .padding(.vertical, 8)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
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
