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
                        actions(task)
                        if !task.attachments.isEmpty { attachmentSection(task) }
                        if !task.planText.isEmpty { planSection(task) }
                        if let evidence = task.latestDeliveryEvidence { deliveryEvidenceSection(evidence) }
                        if !task.resultText.isEmpty { resultSection(task) }
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
        if task.stage == .awaitingApproval {
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
        } else if task.stage == .review {
            reviewActions(task)
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
        inspectorSection("结果", systemImage: "checkmark.seal") {
            Text(TaskDeliveryEvidenceParser.humanReadableResult(from: task.resultText))
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func deliveryEvidenceSection(_ evidence: TaskDeliveryEvidence) -> some View {
        inspectorSection("交付证据", systemImage: "checkmark.seal") {
            TaskDeliveryEvidenceView(evidence: evidence)
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
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func metadata(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
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
