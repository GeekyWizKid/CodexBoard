import SwiftUI

struct TaskInspector: View {
    @ObservedObject var store: BoardStore

    var body: some View {
        Group {
            if let task = store.selectedTask {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(task)
                        actions(task)
                        if !task.planText.isEmpty { planSection(task) }
                        if !task.resultText.isEmpty { resultSection(task) }
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
    }

    private func header(_ task: BoardTask) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(task.stage.title, systemImage: task.stage.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BoardTheme.color(for: task.stage))
                Label(store.hostName(for: task.hostID), systemImage: "server.rack")
                    .font(.caption)
                    .foregroundStyle(store.hostConnectionState(for: task.hostID).hostStatusColor)
                    .help(store.hostConnectionState(for: task.hostID).hostStatusDetail)
                Spacer()
                if task.autoRun {
                    Label("全自动", systemImage: "bolt.fill")
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
            VStack(spacing: 8) {
                Button {
                    store.confirmPlan(taskID: task.id)
                } label: {
                    Label("确认方案并执行", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(BoardTheme.accent)

                Button("重新规划") { store.revisePlan(taskID: task.id) }
                    .frame(maxWidth: .infinity)
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
        }
    }

    private func planSection(_ task: BoardTask) -> some View {
        inspectorSection("方案", systemImage: "list.bullet.clipboard") {
            Text(task.planText)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func resultSection(_ task: BoardTask) -> some View {
        inspectorSection("结果", systemImage: "checkmark.seal") {
            Text(task.resultText)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sessionSection(_ task: BoardTask) -> some View {
        inspectorSection("Codex 会话", systemImage: "terminal") {
            VStack(alignment: .leading, spacing: 7) {
                metadata("主机", store.hostName(for: task.hostID))
                metadata("连接", store.hostConnectionState(for: task.hostID).hostStatusTitle)
                metadata("模型", task.model ?? "由当前主机 Codex 选择")
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
