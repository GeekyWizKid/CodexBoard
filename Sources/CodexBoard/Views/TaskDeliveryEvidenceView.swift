import SwiftUI

struct TaskDeliveryEvidenceView: View {
    let evidence: TaskDeliveryEvidence

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !evidence.summary.isEmpty {
                Text(evidence.summary)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !evidence.changedFiles.isEmpty {
                evidenceList("改动文件", systemImage: "doc.badge.gearshape", values: evidence.changedFiles, monospaced: true)
            }
            if !evidence.verificationCommands.isEmpty {
                evidenceList("验证命令", systemImage: "terminal", values: evidence.verificationCommands, monospaced: true)
            }
            if !evidence.testSummary.isEmpty {
                evidenceValue("测试结果", systemImage: "checkmark.circle", value: evidence.testSummary)
            }
            if let commitSHA = evidence.commitSHA {
                evidenceValue("Commit", systemImage: "point.topleft.down.to.point.bottomright.curvepath", value: commitSHA, monospaced: true)
            }
            if let pullRequestURL = evidence.pullRequestURL,
               let url = URL(string: pullRequestURL) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Pull Request", systemImage: "arrow.triangle.pull")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Link(destination: url) {
                        Text(pullRequestURL)
                            .font(.caption.monospaced())
                            .lineLimit(2)
                    }
                }
            }
            if !evidence.residualRisks.isEmpty {
                evidenceList("残留风险", systemImage: "exclamationmark.triangle", values: evidence.residualRisks, tint: BoardTheme.approval)
            }

            if !evidence.hasStructuredDetails {
                Label("本次结果没有返回结构化明细，请结合完整结果人工验收。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func evidenceList(
        _ title: String,
        systemImage: String,
        values: [String],
        monospaced: Bool = false,
        tint: Color = BoardTheme.accent
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            ForEach(values, id: \.self) { value in
                HStack(alignment: .top, spacing: 7) {
                    Circle()
                        .fill(tint)
                        .frame(width: 4, height: 4)
                        .padding(.top, 6)
                    Text(value)
                        .font(monospaced ? .caption.monospaced() : .caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func evidenceValue(
        _ title: String,
        systemImage: String,
        value: String,
        monospaced: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
