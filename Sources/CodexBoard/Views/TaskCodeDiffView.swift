import AppKit
import SwiftUI

struct TaskCodeDiffView: View {
    let delivery: TaskCodeDelivery
    let canRevealFile: (String) -> Bool
    let revealFile: (String) -> Void

    @State private var showingFullDiff = false

    private let document: UnifiedDiffDocument

    init(
        delivery: TaskCodeDelivery,
        canRevealFile: @escaping (String) -> Bool = { _ in false },
        revealFile: @escaping (String) -> Void = { _ in }
    ) {
        self.delivery = delivery
        self.canRevealFile = canRevealFile
        self.revealFile = revealFile
        document = UnifiedDiffParser.parse(delivery.unifiedDiff)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Label("代码改动", systemImage: "curlybraces.square")
                    .font(.caption.weight(.semibold))
                Spacer()
                DiffStatText(additions: document.additions, deletions: document.deletions)
            }

            HStack(spacing: 8) {
                Label("\(document.files.count) 个文件", systemImage: "doc.on.doc")
                if delivery.isTruncated {
                    Label("仅保留前段", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(BoardTheme.approval)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if document.files.isEmpty {
                Text("已收到代码改动，但暂时无法按文件拆分。可在完整 Diff 中查看原始内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(document.files.prefix(4))) { file in
                        CompactDiffFileView(file: file)
                    }
                }
                if document.files.count > 4 {
                    Text("另有 \(document.files.count - 4) 个文件")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                showingFullDiff = true
            } label: {
                Label("查看全部 Diff", systemImage: "arrow.up.left.and.arrow.down.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(.background.opacity(0.52), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(.quaternary, lineWidth: 1)
        }
        .sheet(isPresented: $showingFullDiff) {
            TaskDiffReviewView(
                delivery: delivery,
                canRevealFile: canRevealFile,
                revealFile: revealFile
            )
        }
    }
}

private struct CompactDiffFileView: View {
    let file: UnifiedDiffFile
    @State private var isExpanded = false

    private var previewLines: [UnifiedDiffLine] {
        let useful = file.lines.filter { $0.kind != .fileHeader }
        return Array((useful.isEmpty ? file.lines : useful).prefix(18))
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(previewLines.enumerated()), id: \.offset) { _, line in
                            UnifiedDiffLineView(line: line, compact: true)
                        }
                    }
                }
                .scrollIndicators(.hidden)

                if file.lines.count > previewLines.count {
                    Text("预览前 \(previewLines.count) 行 · 完整内容请在 Diff 审阅中查看")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 7)
        } label: {
            DiffFileLabel(file: file)
        }
        .padding(8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct TaskDiffReviewView: View {
    let delivery: TaskCodeDelivery
    let canRevealFile: (String) -> Bool
    let revealFile: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedFileID: UnifiedDiffFile.ID?

    private let document: UnifiedDiffDocument

    init(
        delivery: TaskCodeDelivery,
        canRevealFile: @escaping (String) -> Bool = { _ in false },
        revealFile: @escaping (String) -> Void = { _ in }
    ) {
        self.delivery = delivery
        self.canRevealFile = canRevealFile
        self.revealFile = revealFile
        let parsed = UnifiedDiffParser.parse(delivery.unifiedDiff)
        document = parsed
        _selectedFileID = State(initialValue: parsed.files.first?.id)
    }

    private var selectedFile: UnifiedDiffFile? {
        document.files.first(where: { $0.id == selectedFileID }) ?? document.files.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("代码交付", systemImage: "curlybraces.square.fill")
                    .font(.headline)
                Text("\(document.files.count) 个文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DiffStatText(additions: document.additions, deletions: document.deletions)
                if delivery.isTruncated {
                    Label("Diff 过大，仅保留前段", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(BoardTheme.approval)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if document.files.isEmpty {
                VStack(spacing: 12) {
                    ContentUnavailableView(
                        "无法拆分文件",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("下面保留了 Codex 返回的原始 unified diff。")
                    )
                    RawDiffView(text: delivery.unifiedDiff)
                }
                .padding()
            } else {
                HSplitView {
                    List(document.files, selection: $selectedFileID) { file in
                        DiffFileLabel(file: file)
                            .tag(file.id)
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)

                    if let selectedFile {
                        FullDiffFileView(
                            file: selectedFile,
                            canReveal: canRevealFile(selectedFile.path),
                            reveal: { revealFile(selectedFile.path) }
                        )
                        .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(
            minWidth: 860,
            idealWidth: 1_050,
            maxWidth: .infinity,
            minHeight: 600,
            idealHeight: 720,
            maxHeight: .infinity
        )
    }
}

private struct FullDiffFileView: View {
    let file: UnifiedDiffFile
    let canReveal: Bool
    let reveal: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                CodeFileIcon(path: file.path, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.filename)
                        .font(.callout.weight(.semibold))
                    if !file.parentPath.isEmpty {
                        Text(file.parentPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                DiffStatText(additions: file.additions, deletions: file.deletions)
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(file.rawPatch, forType: .string)
                } label: {
                    Label("复制 Patch", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                Button(action: reveal) {
                    Label("在 Finder 中显示", systemImage: "folder")
                }
                .controlSize(.small)
                .disabled(!canReveal)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(file.lines.enumerated()), id: \.offset) { _, line in
                        UnifiedDiffLineView(line: line, compact: false)
                    }
                }
                .frame(minWidth: 680, alignment: .leading)
            }
            .background(.background.opacity(0.35))
        }
    }
}

private struct RawDiffView: View {
    let text: String

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DiffFileLabel: View {
    let file: UnifiedDiffFile

    var body: some View {
        HStack(spacing: 8) {
            Text(file.kind.badge)
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(badgeColor)
                .frame(width: 20, height: 20)
                .background(badgeColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))

            CodeFileIcon(path: file.path)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.filename)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if !file.parentPath.isEmpty {
                    Text(file.parentPath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 6)
            DiffStatText(additions: file.additions, deletions: file.deletions)
        }
        .contentShape(Rectangle())
        .help(file.path)
    }

    private var badgeColor: Color {
        switch file.kind {
        case .added: BoardTheme.completed
        case .deleted: BoardTheme.danger
        case .renamed, .modified: BoardTheme.accent
        case .binary: .secondary
        }
    }
}

private struct DiffStatText: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 5) {
            Text("+\(additions)")
                .foregroundStyle(BoardTheme.completed)
            Text("−\(deletions)")
                .foregroundStyle(BoardTheme.danger)
        }
        .font(.caption2.monospaced().weight(.semibold))
    }
}

private struct UnifiedDiffLineView: View {
    let line: UnifiedDiffLine
    let compact: Bool

    private var fontSize: CGFloat { compact ? 10.5 : 12 }
    private var gutterWidth: CGFloat { compact ? 27 : 38 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(line.oldLineNumber.map(String.init) ?? "")
                .foregroundStyle(.tertiary)
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, 5)
            Text(line.newLineNumber.map(String.init) ?? "")
                .foregroundStyle(.tertiary)
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, 5)
            Text(line.marker)
                .foregroundStyle(markerColor)
                .frame(width: 15, alignment: .center)
            Text(line.content.isEmpty ? " " : line.content)
                .foregroundStyle(contentColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 12)
        }
        .font(.system(size: fontSize, design: .monospaced))
        .frame(minWidth: compact ? 300 : 680, minHeight: compact ? 18 : 20, alignment: .leading)
        .background(rowBackground)
    }

    private var markerColor: Color {
        switch line.kind {
        case .addition: BoardTheme.completed
        case .deletion: BoardTheme.danger
        case .hunk: BoardTheme.accent
        case .fileHeader, .context, .metadata: .secondary
        }
    }

    private var contentColor: Color {
        switch line.kind {
        case .hunk: BoardTheme.accent
        case .fileHeader, .metadata: .secondary
        case .addition, .deletion, .context: .primary
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        switch line.kind {
        case .addition: BoardTheme.completed.opacity(0.12)
        case .deletion: BoardTheme.danger.opacity(0.10)
        case .hunk: BoardTheme.accent.opacity(0.10)
        case .fileHeader: Color.secondary.opacity(0.07)
        case .context, .metadata: Color.clear
        }
    }
}

#if canImport(PreviewsMacros)
#Preview("Diff 卡片 · Inspector") {
    TaskCodeDiffView(delivery: TaskCodeDelivery(unifiedDiff: PreviewDiff.sample))
        .padding()
        .frame(width: 360)
}

#Preview("完整 Diff · Dark") {
    TaskDiffReviewView(delivery: TaskCodeDelivery(unifiedDiff: PreviewDiff.sample))
        .preferredColorScheme(.dark)
}

private enum PreviewDiff {
    static let sample = """
    diff --git a/Sources/Feature.swift b/Sources/Feature.swift
    index 1234567..89abcde 100644
    --- a/Sources/Feature.swift
    +++ b/Sources/Feature.swift
    @@ -10,4 +10,6 @@ struct Feature {
         let title: String
    -    let enabled = false
    +    let enabled = true
    +    let delivery = "Diff preview"
    +
         func run() {}
    diff --git a/Tests/FeatureTests.swift b/Tests/FeatureTests.swift
    new file mode 100644
    --- /dev/null
    +++ b/Tests/FeatureTests.swift
    @@ -0,0 +1,3 @@
    +import XCTest
    +
    +final class FeatureTests: XCTestCase {}
    """
}
#endif
