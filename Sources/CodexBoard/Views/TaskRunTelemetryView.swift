import SwiftUI

struct TaskRunTelemetryView: View {
    let run: TaskRun

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let usage = rootUsage {
                usageSection(
                    title: "根 Thread · 上次观测",
                    usage: usage,
                    showThread: false
                )
            }
            if !otherUsage.isEmpty {
                DisclosureGroup("其他 Thread 的逐项观测（\(otherUsage.count)）") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(otherUsage, id: \.threadID) { usage in
                            usageSection(
                                title: shortID(usage.threadID),
                                usage: usage,
                                showThread: true
                            )
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.caption.weight(.semibold))
            }
            if !activities.isEmpty {
                Divider()
                Text("最近子代理活动")
                    .font(.caption.weight(.semibold))
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(activities) { activity in
                        activityRow(activity)
                    }
                }
            }
            Text("这里只显示本机实际收到并持久化的协议事件；离线期间可能不完整。Token 为逐 Thread 原始快照，不代表单轮成本或多代理合计。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rootUsage: TaskRunThreadTokenUsageSnapshot? {
        guard let rootThreadID = run.threadID else { return nil }
        return run.telemetry?.tokenUsageByThread
            .filter { $0.threadID == rootThreadID }
            .max(by: { $0.receivedAt < $1.receivedAt })
    }

    private var otherUsage: [TaskRunThreadTokenUsageSnapshot] {
        let rootThreadID = run.threadID
        return (run.telemetry?.tokenUsageByThread ?? [])
            .filter { $0.threadID != rootThreadID }
            .sorted { lhs, rhs in
                if lhs.receivedAt != rhs.receivedAt { return lhs.receivedAt > rhs.receivedAt }
                return lhs.threadID < rhs.threadID
            }
    }

    private var activities: [TaskRunAgentActivity] {
        Array((run.telemetry?.agentActivities ?? []).suffix(10).reversed())
    }

    private func usageSection(
        title: String,
        usage: TaskRunThreadTokenUsageSnapshot,
        showThread: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(BoardFormatters.relativeDate(usage.receivedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if showThread {
                telemetryMetadata("Thread", shortID(usage.threadID))
            }
            telemetryMetadata("累计 tokens", usage.total.totalTokens.formatted())
            telemetryMetadata("最近 Turn", usage.last.totalTokens.formatted())
            telemetryMetadata(
                "输入 / 输出",
                "\(usage.last.inputTokens.formatted()) / \(usage.last.outputTokens.formatted())"
            )
            telemetryMetadata(
                "缓存读 / 写",
                "\(usage.last.cachedInputTokens.formatted()) / \(usage.last.cacheWriteInputTokens.formatted())"
            )
            telemetryMetadata("推理输出", usage.last.reasoningOutputTokens.formatted())
            if let contextWindow = usage.modelContextWindow {
                telemetryMetadata("上下文窗口（协议原值）", contextWindow.formatted())
            }
        }
        .padding(9)
        .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private func activityRow(_ activity: TaskRunAgentActivity) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: activity.completedAt == nil ? "person.2.wave.2" : "person.2.fill")
                .foregroundStyle(activity.completedAt == nil ? BoardTheme.executing : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(activity.kind)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(activity.completedAt == nil ? "已开始" : "已完成")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(activity.agentPath.isEmpty ? shortID(activity.agentThreadID) : activity.agentPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if let observedAt = activity.completedAt ?? activity.startedAt {
                    Text(BoardFormatters.relativeDate(observedAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func telemetryMetadata(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
        }
        .font(.caption2)
    }

    private func shortID(_ value: String) -> String {
        value.count > 16 ? "\(value.prefix(8))…\(value.suffix(6))" : value
    }
}
