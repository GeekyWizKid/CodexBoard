import SwiftUI

struct TaskDeliveryEvidenceView: View {
    let task: BoardTask
    let run: TaskRun
    let store: BoardStore

    private var evidence: TaskDeliveryEvidence? { run.evidence }

    private var summary: String {
        let evidenceSummary = evidence?.summary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return evidenceSummary.isEmpty ? run.summary : evidenceSummary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("执行 #\(run.attempt)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(BoardTheme.color(for: run.outcome))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(BoardTheme.color(for: run.outcome).opacity(0.11), in: Capsule())
                Text(run.outcome.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if !summary.isEmpty {
                Text(summary)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let codeDelivery = run.codeDelivery {
                TaskCodeDiffView(
                    delivery: codeDelivery,
                    canRevealFile: { path in
                        store.deliveryArtifactURL(
                            TaskDeliveryArtifact(path: path),
                            for: task
                        ) != nil
                    },
                    revealFile: { path in
                        store.revealDeliveryArtifact(
                            TaskDeliveryArtifact(path: path),
                            for: task
                        )
                    }
                )
            } else if let changedFiles = evidence?.changedFiles, !changedFiles.isEmpty {
                changedFilesSection(changedFiles)
            }

            if let artifacts = evidence?.artifacts, !artifacts.isEmpty {
                artifactSection(artifacts)
            }

            if let evidence {
                verificationSection(evidence)

                if !evidence.residualRisks.isEmpty {
                    evidenceList(
                        "残留风险",
                        systemImage: "exclamationmark.triangle",
                        values: evidence.residualRisks,
                        tint: BoardTheme.approval
                    )
                }

                if !evidence.hasStructuredDetails, run.codeDelivery == nil {
                    Label("本次结果没有返回结构化明细，请结合完整回复人工验收。", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func changedFilesSection(_ files: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("改动文件", systemImage: "doc.badge.gearshape")
                .font(.caption.weight(.semibold))
                .foregroundStyle(BoardTheme.accent)
            CodeChangedFileList(files: files)
        }
    }

    @ViewBuilder
    private func artifactSection(_ artifacts: [TaskDeliveryArtifact]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("可用交付物", systemImage: "shippingbox")
                .font(.caption.weight(.semibold))
                .foregroundStyle(BoardTheme.accent)

            ForEach(Array(artifacts.enumerated()), id: \.offset) { _, artifact in
                let url = store.deliveryArtifactURL(artifact, for: task)
                HStack(spacing: 8) {
                    Image(systemName: artifactIcon(artifact))
                        .foregroundStyle(url == nil ? Color.secondary : BoardTheme.accent)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artifact.title.isEmpty ? URL(fileURLWithPath: artifact.path).lastPathComponent : artifact.title)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text(artifact.path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    Button {
                        store.openDeliveryArtifact(artifact, for: task)
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .buttonStyle(.plain)
                    .disabled(url == nil)
                    .help(url == nil ? "文件不存在或不在任务工作区内" : "打开交付物")
                    Button {
                        store.revealDeliveryArtifact(artifact, for: task)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                    .disabled(url == nil)
                    .help("在 Finder 中显示")
                }
                .padding(8)
                .background(.background.opacity(0.48), in: RoundedRectangle(cornerRadius: 7))
                .help(artifact.path)
            }
        }
    }

    @ViewBuilder
    private func verificationSection(_ evidence: TaskDeliveryEvidence) -> some View {
        if !evidence.verificationCommands.isEmpty
            || !evidence.testSummary.isEmpty
            || evidence.commitSHA != nil
            || evidence.pullRequestURL != nil {
            VStack(alignment: .leading, spacing: 9) {
                Label("验证与发布", systemImage: "checkmark.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BoardTheme.completed)

                if !evidence.testSummary.isEmpty {
                    Text(evidence.testSummary)
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !evidence.verificationCommands.isEmpty {
                    ForEach(evidence.verificationCommands, id: \.self) { command in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "terminal")
                                .foregroundStyle(.secondary)
                            Text(command)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if let commitSHA = evidence.commitSHA {
                    evidenceValue(
                        "Commit",
                        systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                        value: commitSHA,
                        monospaced: true
                    )
                }
                if let pullRequestURL = evidence.pullRequestURL,
                   let url = URL(string: pullRequestURL) {
                    Link(destination: url) {
                        Label(pullRequestURL, systemImage: "arrow.triangle.pull")
                            .font(.caption.monospaced())
                            .lineLimit(2)
                    }
                }
            }
            .padding(9)
            .background(.background.opacity(0.42), in: RoundedRectangle(cornerRadius: 8))
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
            Label(LocalizedStringKey(title), systemImage: systemImage)
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
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Label(LocalizedStringKey(title), systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
        }
    }

    private func artifactIcon(_ artifact: TaskDeliveryArtifact) -> String {
        let kind = artifact.kind.lowercased()
        let fileExtension = URL(fileURLWithPath: artifact.path).pathExtension.lowercased()
        if kind == "image" || ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(fileExtension) {
            return "photo"
        }
        if kind == "archive" || ["zip", "tar", "gz", "7z"].contains(fileExtension) {
            return "archivebox"
        }
        if kind == "data" || ["csv", "json", "xlsx"].contains(fileExtension) {
            return "tablecells"
        }
        if kind == "document" || ["pdf", "doc", "docx", "md", "html"].contains(fileExtension) {
            return "doc.richtext"
        }
        return "doc"
    }
}
