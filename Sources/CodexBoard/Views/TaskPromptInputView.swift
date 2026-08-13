import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct TaskPromptInputView: View {
    @Binding var text: String
    @Binding var attachments: [TaskAttachmentDraft]

    let label: String
    let placeholder: String
    let chooseFiles: () -> Void
    let reportImportMessage: (String?) -> Void

    @State private var isDropTargeted = false
    @State private var quickLookURL: URL?
    @State private var imagePreview: PastedImagePreview?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.callout.weight(.medium))

            VStack(alignment: .leading, spacing: 8) {
                if !attachments.isEmpty {
                    attachmentStrip
                }

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: attachments.isEmpty ? 132 : 96)
                        .onPasteCommand(of: [.fileURL, .image]) { _ in
                            importPasteboard()
                        }

                    if text.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }

                HStack(spacing: 8) {
                    Button(action: chooseFiles) {
                        Image(systemName: "paperclip")
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("添加文件")
                    .accessibilityLabel("添加附件")

                    Text("⌘V 粘贴截图或文件 · 也可直接拖入文件")
                        .font(.caption)
                        .foregroundStyle(isDropTargeted ? BoardTheme.accent : .secondary)

                    Spacer(minLength: 8)

                    if !attachments.isEmpty {
                        Text("\(attachments.count) 个附件")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 4)
            }
            .padding(9)
            .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isDropTargeted ? BoardTheme.accent : Color.secondary.opacity(0.16),
                        lineWidth: isDropTargeted ? 2 : 1
                    )
            }
            .dropDestination(for: URL.self) { urls, _ in
                importFiles(urls)
            } isTargeted: { targeted in
                withAnimation(.easeOut(duration: 0.12)) {
                    isDropTargeted = targeted
                }
            }
        }
        .quickLookPreview($quickLookURL)
        .sheet(item: $imagePreview) { preview in
            PastedImagePreviewView(preview: preview)
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentDraftCard(
                        attachment: attachment,
                        preview: { preview(attachment) },
                        reveal: revealAction(for: attachment),
                        remove: { remove(attachment) }
                    )
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
        .frame(height: 78)
    }

    private func importPasteboard() {
        switch TaskAttachmentDraftImporter.importPasteboard(
            .general,
            existing: attachments
        ) {
        case let .attachments(outcome):
            attachments.append(contentsOf: outcome.drafts)
            reportImportMessage(outcome.message)
        case .unsupported:
            reportImportMessage("剪贴板中没有可用的图片或文件。")
        }
    }

    @discardableResult
    private func importFiles(_ urls: [URL]) -> Bool {
        let outcome = TaskAttachmentDraftImporter.importFiles(urls, existing: attachments)
        attachments.append(contentsOf: outcome.drafts)
        reportImportMessage(outcome.message)
        return !outcome.drafts.isEmpty
    }

    private func remove(_ attachment: TaskAttachmentDraft) {
        attachments.removeAll { $0.id == attachment.id }
        reportImportMessage(nil)
    }

    private func preview(_ attachment: TaskAttachmentDraft) {
        switch attachment.source {
        case let .file(url):
            quickLookURL = url
        case let .pastedImage(data):
            guard let image = NSImage(data: data) else { return }
            imagePreview = PastedImagePreview(
                id: attachment.id,
                title: attachment.displayName,
                image: image
            )
        }
    }

    private func revealAction(for attachment: TaskAttachmentDraft) -> (() -> Void)? {
        guard case let .file(url) = attachment.source else { return nil }
        return {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

private struct AttachmentDraftCard: View {
    let attachment: TaskAttachmentDraft
    let preview: () -> Void
    let reveal: (() -> Void)?
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: preview) {
                HStack(spacing: 8) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 3) {
                        Text(attachment.displayName)
                            .font(.caption.weight(.medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(sizeText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: isImage ? 88 : 112, alignment: .leading)
                }
                .padding(6)
                .frame(height: 74)
                .background(.background.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.14))
                }
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("点击预览 \(attachment.displayName)")
            .accessibilityLabel("预览附件 \(attachment.displayName)")

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.58))
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .padding(3)
            .help("移除 \(attachment.displayName)")
            .accessibilityLabel("移除附件 \(attachment.displayName)")
        }
        .contextMenu {
            Button("快速查看", action: preview)
            if let reveal {
                Button("在 Finder 中显示", action: reveal)
            }
            Divider()
            Button("移除附件", role: .destructive, action: remove)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = previewImage {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(nsImage: fileIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 46, height: 46)
                .frame(width: 58, height: 58)
        }
    }

    private var previewImage: NSImage? {
        switch attachment.source {
        case let .pastedImage(data):
            return NSImage(data: data)
        case let .file(url):
            guard let type = UTType(filenameExtension: url.pathExtension),
                  type.conforms(to: .image)
            else { return nil }
            return NSImage(contentsOf: url)
        }
    }

    private var fileIcon: NSImage {
        guard case let .file(url) = attachment.source else {
            return NSImage(systemSymbolName: "photo", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private var isImage: Bool {
        switch attachment.source {
        case .pastedImage:
            return true
        case let .file(url):
            return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        }
    }

    private var sizeText: String {
        attachment.byteCount.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        } ?? L10n.text("大小未知", fallback: "大小未知")
    }
}

private struct PastedImagePreview: Identifiable {
    let id: UUID
    let title: String
    let image: NSImage
}

private struct PastedImagePreviewView: View {
    let preview: PastedImagePreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(preview.title)
                    .font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: preview.image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 900, maxHeight: 650)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 460)
    }
}
