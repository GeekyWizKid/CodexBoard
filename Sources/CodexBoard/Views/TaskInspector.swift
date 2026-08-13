import SwiftUI

struct TaskInspector: View {
    let store: BoardStore
    @State private var editingPlanTaskID: UUID?
    @State private var planDraft = ""
    @State private var reviewFeedbackDraft = ""

    var body: some View {
        Group {
            if let task = store.selectedTask {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(task)
                        ForEach(store.interactions(for: task.id)) { request in
                            TaskInteractionPanel(
                                request: request,
                                isResponding: store.respondingRequestIDs.contains(request.id),
                                errorMessage: task.lastError,
                                respond: { response in
                                    Task {
                                        await store.respondToInteraction(
                                            taskID: task.id,
                                            requestID: request.id,
                                            response: response
                                        )
                                    }
                                },
                                openURL: { store.openInteractionURL($0) }
                            )
                        }
                        if task.stage != .review { actions(task) }
                        workflowSection(task)
                        if !task.selectedSkills.isEmpty || !task.selectedApps.isEmpty {
                            capabilitySection(task)
                        }
                        if let failure = task.failureState { failureSection(failure) }
                        if !task.attachments.isEmpty { attachmentSection(task) }
                        if !task.planText.isEmpty { planSection(task) }
                        if let run = task.latestExecutionRun,
                           run.evidence != nil || run.codeDelivery != nil {
                            deliveryEvidenceSection(task: task, run: run)
                        }
                        if !task.resultText.isEmpty { resultSection(task) }
                        if task.stage == .review { reviewSection(task) }
                        if !task.runs.isEmpty { runHistorySection(task) }
                        sessionSection(task)
                        logSection(task)
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView(
                    "选择一张卡片",
                    systemImage: "rectangle.on.rectangle",
                    description: Text("在这里确认方案、查看执行进度和 Codex 会话信息。")
                )
            }
        }
        .onChange(of: store.selectedTaskID) { _, _ in
            discardPlanEdits()
            reviewFeedbackDraft = ""
        }
        .onChange(of: store.selectedTask?.stage) { _, stage in
            if stage != .awaitingApproval {
                discardPlanEdits()
            }
            if stage != .review {
                reviewFeedbackDraft = ""
            }
        }
    }

    private func header(_ task: BoardTask) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(task.stage.title, systemImage: task.stage.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BoardTheme.color(for: task.stage))
                Spacer()
                if task.autoRun {
                    Label("全自动", systemImage: "bolt.fill")
                        .font(.caption)
                        .foregroundStyle(BoardTheme.executing)
                }
                if task.fastMode {
                    Label("Fast", systemImage: "bolt.horizontal.fill")
                        .font(.caption)
                        .foregroundStyle(BoardTheme.executing)
                }
            }
            Text(task.title)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            Text(task.sourceText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(8)
                .textSelection(.enabled)
            if let error = task.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(BoardTheme.danger)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(BoardTheme.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func actions(_ task: BoardTask) -> some View {
        let hasBlockingDependencies = store.blockingDependencyCount(for: task) > 0
        if task.stage == .inbox {
            Button {
                Task { await store.startPlanning(taskID: task.id) }
            } label: {
                Label(
                    hasBlockingDependencies ? "等待前置任务" : "开始规划",
                    systemImage: hasBlockingDependencies ? "hourglass" : "play.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(BoardTheme.accent)
            .disabled(hasBlockingDependencies)
        } else if task.stage == .awaitingApproval {
            if task.executionApproved {
                Label("方案已确认，正在等待执行槽位。", systemImage: "hourglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 8) {
                    Button {
                        store.confirmPlan(taskID: task.id)
                    } label: {
                        Label("确认方案并执行", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BoardTheme.accent)
                    .disabled(isEditingPlan(task))

                    Button("重新规划") { store.revisePlan(taskID: task.id) }
                        .frame(maxWidth: .infinity)
                        .disabled(isEditingPlan(task))
                }
            }
        } else if task.stage.isActive {
            Button(role: .destructive) {
                Task { await store.cancel(taskID: task.id) }
            } label: {
                Label("停止当前运行", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        } else if task.stage == .needsAttention, task.hasFinalPlan, !task.planText.isEmpty {
            Button {
                store.continueExecution(taskID: task.id)
            } label: {
                Label("检查后继续执行", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        } else if task.stage == .needsAttention {
            Button {
                store.revisePlan(taskID: task.id)
            } label: {
                Label("问题处理后重新规划", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func workflowSection(_ task: BoardTask) -> some View {
        if task.workspace.kind == .worktree || !task.dependencyIDs.isEmpty {
            inspectorSection("研发工作流", systemImage: "point.3.connected.trianglepath.dotted") {
                VStack(alignment: .leading, spacing: 10) {
                    if task.workspace.kind == .worktree {
                        metadata("工作区", task.workspace.kind.title)
                        metadata("分支", task.workspace.branch ?? "执行前自动创建")
                        if let baseBranch = task.workspace.baseBranch {
                            metadata("基线", baseBranch)
                        }
                        if let path = task.workspace.path {
                            Text(path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(3)
                            HStack {
                                Button("在 Finder 中显示") { store.revealWorkspace(for: task) }
                                    .controlSize(.small)
                                if !task.stage.isActive {
                                    Button("清理 Worktree", role: .destructive) {
                                        Task { await store.cleanupWorktree(taskID: task.id) }
                                    }
                                    .controlSize(.small)
                                    .help("仅在工作区无未提交改动时移除；任务分支会保留。")
                                }
                            }
                        }
                    }

                    if !task.dependencyIDs.isEmpty {
                        if task.workspace.kind == .worktree { Divider() }
                        Text("前置任务")
                            .font(.caption.weight(.semibold))
                        ForEach(store.dependencies(for: task)) { dependency in
                            Button {
                                store.focusTask(dependency.id)
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: dependency.stage.symbol)
                                        .foregroundStyle(BoardTheme.color(for: dependency.stage))
                                    Text(dependency.title)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(dependency.stage == .completed ? "已验收" : "阻塞中")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func failureSection(_ failure: TaskFailureState) -> some View {
        inspectorSection("失败保护", systemImage: "bolt.trianglebadge.exclamationmark") {
            VStack(alignment: .leading, spacing: 7) {
                metadata("分类", failure.kind.title)
                metadata("连续失败", "\(failure.consecutiveCount) 次")
                metadata("自动重试", "\(failure.automaticRetryCount)/\(store.preferences.maxAutomaticRetries)")
                metadata("熔断器", failure.circuitOpen ? "已打开" : "等待重试")
                if let nextRetryAt = failure.nextRetryAt {
                    metadata("下次重试", BoardFormatters.logTime.string(from: nextRetryAt))
                }
                Text(failure.circuitOpen
                     ? "已停止自动调度，修复问题并检查工作区后再手动继续。"
                     : "只会重试尚未进入写入 turn 的启动步骤。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func capabilitySection(_ task: BoardTask) -> some View {
        inspectorSection("任务能力", systemImage: "wand.and.stars") {
            VStack(alignment: .leading, spacing: 12) {
                Text("以下能力在创建任务时已固定，目录后续变化不会改变本任务。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !task.selectedSkills.isEmpty {
                    capabilityGroupTitle("Skills", count: task.selectedSkills.count)
                    ForEach(task.selectedSkills) { skill in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(skill.name, systemImage: "sparkles")
                                .font(.callout.weight(.medium))
                            if !skill.description.isEmpty {
                                Text(skill.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text("\(skill.scope) · \(skill.path)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }
                    }
                }

                if !task.selectedApps.isEmpty {
                    if !task.selectedSkills.isEmpty { Divider() }
                    capabilityGroupTitle("Apps", count: task.selectedApps.count)
                    ForEach(task.selectedApps) { app in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Label(app.name, systemImage: "square.grid.2x2")
                                    .font(.callout.weight(.medium))
                                if app.requiresApproval {
                                    Text("已阻止")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(BoardTheme.danger)
                                } else {
                                    Text("只读")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if !app.description.isEmpty {
                                Text(app.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(app.invocationName)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                            if app.requiresApproval {
                                Text("此历史选择包含写入工具，当前安全策略不会把它注入任何 Turn。")
                                    .font(.caption2)
                                    .foregroundStyle(BoardTheme.danger)
                            }
                        }
                    }
                }
            }
        }
    }

    private func capabilityGroupTitle(_ title: String, count: Int) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
                .font(.caption.weight(.semibold))
            Spacer()
            Text("\(count) 项")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func reviewActions(_ task: BoardTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                store.acceptReview(taskID: task.id)
            } label: {
                Label("验收完成", systemImage: "checkmark.seal.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(BoardTheme.completed)

            Divider()

            Text("要求修改")
                .font(.callout.weight(.semibold))
            Text("写清需要修正的内容，Codex 会在同一任务中创建下一次执行记录。")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $reviewFeedbackDraft)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(7)
                .frame(minHeight: 82)
                .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))

            Button {
                if store.requestChanges(taskID: task.id, feedback: reviewFeedbackDraft) {
                    reviewFeedbackDraft = ""
                }
            } label: {
                Label("提交修改要求并重新执行", systemImage: "arrow.uturn.backward.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(reviewFeedbackDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func planSection(_ task: BoardTask) -> some View {
        inspectorSection("方案", systemImage: "list.bullet.clipboard") {
            if isEditingPlan(task) {
                VStack(alignment: .leading, spacing: 10) {
                    TextEditor(text: $planDraft)
                        .font(.callout.monospaced())
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 220)
                        .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))

                    Text("保存后需要重新确认方案才会执行。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("取消") { discardPlanEdits() }
                        Spacer()
                        Button("保存修改") { savePlanEdits(for: task) }
                            .buttonStyle(.borderedProminent)
                            .tint(BoardTheme.accent)
                            .disabled(planDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if task.stage == .awaitingApproval, !task.executionApproved {
                        HStack {
                            Spacer()
                            Button {
                                beginEditingPlan(task)
                            } label: {
                                Label("编辑方案", systemImage: "pencil")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    Text(task.planText)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func isEditingPlan(_ task: BoardTask) -> Bool {
        editingPlanTaskID == task.id && task.stage == .awaitingApproval
    }

    private func beginEditingPlan(_ task: BoardTask) {
        planDraft = task.planText
        editingPlanTaskID = task.id
    }

    private func savePlanEdits(for task: BoardTask) {
        guard store.updatePlan(taskID: task.id, planText: planDraft) else { return }
        discardPlanEdits()
    }

    private func discardPlanEdits() {
        editingPlanTaskID = nil
        planDraft = ""
    }

    private func attachmentSection(_ task: BoardTask) -> some View {
        inspectorSection("附件", systemImage: "paperclip") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(task.attachments) { attachment in
                    let exists = FileManager.default.isReadableFile(atPath: attachment.path)
                    HStack(spacing: 8) {
                        Image(systemName: exists ? attachment.kind.symbol : "exclamationmark.triangle")
                            .foregroundStyle(exists ? BoardTheme.accent : BoardTheme.danger)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attachment.displayName)
                                .lineLimit(1)
                            HStack(spacing: 5) {
                                Text(attachment.kind.title)
                                if let byteCount = attachment.byteCount {
                                    Text("·")
                                    Text(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
                                }
                                if !exists {
                                    Text("· 文件缺失或不可读")
                                        .foregroundStyle(BoardTheme.danger)
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            store.revealAttachment(attachment)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.plain)
                        .disabled(!exists)
                        .help("在 Finder 中显示")
                    }
                    .help(attachment.path)
                }
            }
        }
    }

    private func resultSection(_ task: BoardTask) -> some View {
        inspectorSection("完整回复", systemImage: "text.bubble") {
            DisclosureGroup("查看 Codex 完整回复") {
                Text(TaskDeliveryEvidenceParser.humanReadableResult(from: task.resultText))
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
            .font(.caption.weight(.semibold))
        }
    }

    private func deliveryEvidenceSection(task: BoardTask, run: TaskRun) -> some View {
        inspectorSection("交付物", systemImage: "shippingbox") {
            TaskDeliveryEvidenceView(task: task, run: run, store: store)
        }
    }

    private func reviewSection(_ task: BoardTask) -> some View {
        inspectorSection("验收", systemImage: "checkmark.bubble") {
            reviewActions(task)
        }
    }

    private func runHistorySection(_ task: BoardTask) -> some View {
        inspectorSection("运行记录", systemImage: "clock.arrow.2.circlepath") {
            TaskRunHistoryView(runs: task.runs)
        }
    }

    private func sessionSection(_ task: BoardTask) -> some View {
        inspectorSection("Codex 会话", systemImage: "terminal") {
            VStack(alignment: .leading, spacing: 7) {
                metadata("请求模型", task.requestedModel.isEmpty ? "由本机 Codex 选择" : task.requestedModel)
                metadata("实际模型", task.actualModel ?? "尚未启动")
                metadata("推理强度", "\(task.reasoningEffort.title) · \(task.reasoningEffort.rawValue)")
                metadata("运行速度", task.fastMode ? "Fast · priority" : "标准")
                metadata("Thread", task.threadID.map(shortID) ?? "尚未创建")
                metadata("Session", task.sessionID.map(shortID) ?? "尚未创建")
                if let turn = task.planningTurnID { metadata("规划 Turn", shortID(turn)) }
                if let turn = task.executionTurnID { metadata("执行 Turn", shortID(turn)) }
            }
        }
    }

    private func logSection(_ task: BoardTask) -> some View {
        inspectorSection("活动", systemImage: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(task.logs.suffix(20).reversed()) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(logColor(entry.level))
                            .frame(width: 6, height: 6)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.message)
                                .font(.caption)
                                .textSelection(.enabled)
                            Text(BoardFormatters.logTime.string(from: entry.date))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func inspectorSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(LocalizedStringKey(title), systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func metadata(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(label))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .font(.caption)
    }

    private func shortID(_ value: String) -> String {
        value.count > 16 ? "\(value.prefix(8))…\(value.suffix(6))" : value
    }

    private func logColor(_ level: TaskLogEntry.Level) -> Color {
        switch level {
        case .info: BoardTheme.accent
        case .success: BoardTheme.completed
        case .warning: BoardTheme.approval
        case .error: BoardTheme.danger
        }
    }
}
