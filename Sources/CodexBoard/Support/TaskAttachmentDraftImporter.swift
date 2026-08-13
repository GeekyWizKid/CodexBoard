import AppKit
import Foundation

@MainActor
enum TaskAttachmentDraftImporter {
    struct ImportOutcome {
        let drafts: [TaskAttachmentDraft]
        let message: String?
    }

    enum PasteboardOutcome {
        case attachments(ImportOutcome)
        case unsupported
    }

    static func importPasteboard(
        _ pasteboard: NSPasteboard,
        existing: [TaskAttachmentDraft]
    ) -> PasteboardOutcome {
        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let fileURLs = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: fileOptions
        ) as? [URL]) ?? []

        // Finder commonly publishes both a file URL and an image
        // representation for image files. Preserve the original file in that
        // case instead of adding it twice as both a file and a bitmap.
        if !fileURLs.isEmpty {
            return .attachments(importFiles(fileURLs, existing: existing))
        }

        guard let pngData = pngData(from: pasteboard) else {
            return .unsupported
        }
        let draft = TaskAttachmentDraft(
            displayName: nextPastedImageName(existing: existing),
            byteCount: Int64(pngData.count),
            source: .pastedImage(pngData)
        )
        return .attachments(ImportOutcome(drafts: [draft], message: nil))
    }

    static func importFiles(
        _ rawURLs: [URL],
        existing: [TaskAttachmentDraft]
    ) -> ImportOutcome {
        let existingPaths = Set(existing.compactMap(filePath))
        var seenPaths = existingPaths
        var drafts: [TaskAttachmentDraft] = []
        var duplicateCount = 0
        var rejectedNames: [String] = []

        for rawURL in rawURLs {
            let url = rawURL.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
            guard url.isFileURL else { continue }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: url.path),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else {
                rejectedNames.append(url.lastPathComponent)
                continue
            }
            guard seenPaths.insert(url.path).inserted else {
                duplicateCount += 1
                continue
            }
            drafts.append(.file(url))
        }

        let message: String?
        if !rejectedNames.isEmpty {
            message = "只能添加可读取的普通文件：\(rejectedNames.joined(separator: "、"))"
        } else if drafts.isEmpty, duplicateCount > 0 {
            message = "所选文件已在附件中。"
        } else {
            message = nil
        }
        return ImportOutcome(drafts: drafts, message: message)
    }

    static func nextPastedImageName(existing: [TaskAttachmentDraft]) -> String {
        let names = Set(existing.map(\.displayName))
        var index = 1
        while names.contains("粘贴的图片 \(index).png") {
            index += 1
        }
        return "粘贴的图片 \(index).png"
    }

    static func filePath(_ draft: TaskAttachmentDraft) -> String? {
        guard case let .file(url) = draft.source else { return nil }
        return url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let data = pasteboard.data(forType: .png), NSImage(data: data) != nil {
            return data
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
