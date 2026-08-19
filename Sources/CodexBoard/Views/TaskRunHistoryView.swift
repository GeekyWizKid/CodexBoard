import SwiftUI

struct TaskRunHistoryView: View {
    let runs: [TaskRun]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(runs.reversed()) { run in
                TaskRunHistoryRow(run: run)
            }
        }
    }
}

private struct TaskRunHistoryRow: View {
    let run: TaskRun
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                if !run.summary.isEmpty {
                    Text(run.summary)
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let codeDelivery = run.codeDelivery {
                    TaskCodeDiffView(delivery: codeDelivery)
                }
                if let evidence = run.evidence, evidence.hasStructuredDetails {
                    runDeliverySummary(evidence)
                }
                if let reviewNote = run.reviewNote {
                    labeledText("验收反馈", reviewNote, tint: BoardTheme.approval)
                }
                if let error = run.failure?.message ?? run.error {
                    labeledText("错误", error, tint: BoardTheme.danger)
                }
                runMetadata
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: run.phase.symbol)
                    .foregroundStyle(BoardTheme.color(for: run.outcome))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(run.phase.title) #\(run.attempt)")
                        .font(.caption.weight(.semibold))
                    Text(BoardFormatters.relativeDate(run.startedAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(run.outcome.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(BoardTheme.color(for: run.outcome))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(BoardTheme.color(for: run.outcome).opacity(0.11), in: Capsule())
            }
        }
        .padding(9)
        .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private var runMetadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let model = run.model { metadata("模型", model) }
            metadata("推理强度", run.reasoningEffort.title)
            metadata("速度", run.fastMode ? "Fast" : "标准")
            if let threadID = run.threadID { metadata("Thread", shortID(threadID)) }
            if let turnID = run.turnID { metadata("Turn", shortID(turnID)) }
            if let endedAt = run.endedAt {
                metadata("耗时", duration(from: run.startedAt, to: endedAt))
            }
        }
    }

    private func runDeliverySummary(_ evidence: TaskDeliveryEvidence) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("本轮交付")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(BoardTheme.accent)
            if !evidence.artifacts.isEmpty {
                Label("\(evidence.artifacts.count) 个可用交付物", systemImage: "shippingbox")
            }
            if run.codeDelivery == nil, !evidence.changedFiles.isEmpty {
                Label("\(evidence.changedFiles.count) 个改动文件", systemImage: "doc.badge.gearshape")
            }
            if !evidence.testSummary.isEmpty {
                Label(evidence.testSummary, systemImage: "checkmark.circle")
                    .lineLimit(3)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labeledText(_ label: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(label))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }

    private func metadata(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(label))
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

    private func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds < 60 {
            return L10n.format("%lld 秒", fallback: "%lld 秒", Int64(seconds))
        }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return L10n.format(
            "%lld 分 %lld 秒",
            fallback: "%lld 分 %lld 秒",
            Int64(minutes),
            Int64(remainder)
        )
    }
}
