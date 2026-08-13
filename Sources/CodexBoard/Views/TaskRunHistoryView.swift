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
                if let reviewNote = run.reviewNote {
                    labeledText("验收反馈", reviewNote, tint: BoardTheme.approval)
                }
                if let error = run.error {
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

    private func labeledText(_ label: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }

    private func metadata(_ label: String, _ value: String) -> some View {
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

    private func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return "\(minutes) 分 \(remainder) 秒"
    }
}
