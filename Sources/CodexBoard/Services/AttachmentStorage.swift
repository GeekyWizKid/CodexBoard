import Foundation
import ImageIO

enum AttachmentStorageError: LocalizedError, Equatable {
    case missingOrUnreadable(String)
    case notARegularFile(String)
    case invalidImage(String)
    case storageFailed(String)

    var errorDescription: String? {
        switch self {
        case let .missingOrUnreadable(name):
            "附件不存在或无法读取：\(name)"
        case let .notARegularFile(name):
            "附件不是普通文件：\(name)"
        case let .invalidImage(name):
            "无法识别图片附件：\(name)"
        case let .storageFailed(reason):
            "无法保存截图附件：\(reason)"
        }
    }
}

actor AttachmentStorage {
    private let rootDirectory: URL
    private let fileManager: FileManager

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootDirectory = (rootDirectory ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexBoard/attachments", isDirectory: true))
            .standardizedFileURL
    }

    func materialize(_ drafts: [TaskAttachmentDraft], taskID: UUID) throws -> [TaskAttachment] {
        guard !drafts.isEmpty else { return [] }
        var attachments: [TaskAttachment] = []
        do {
            for draft in drafts {
                switch draft.source {
                case let .file(url):
                    attachments.append(try externalAttachment(from: url, id: draft.id))
                case let .pastedImage(data):
                    attachments.append(try storePastedImage(data, draft: draft, taskID: taskID))
                }
            }
            return attachments
        } catch {
            try? removeTaskDirectory(taskID: taskID)
            throw error
        }
    }

    func validate(_ attachments: [TaskAttachment]) throws {
        for attachment in attachments {
            let url = URL(fileURLWithPath: attachment.path).standardizedFileURL
            try validateRegularReadableFile(at: url, displayName: attachment.displayName)
            if attachment.kind == .image, !isDecodableImage(at: url) {
                throw AttachmentStorageError.invalidImage(attachment.displayName)
            }
        }
    }

    func removeManagedAttachments(taskID: UUID, attachments: [TaskAttachment]) {
        guard attachments.contains(where: \.isManaged) else { return }
        try? removeTaskDirectory(taskID: taskID)
    }

    private func externalAttachment(from rawURL: URL, id: UUID) throws -> TaskAttachment {
        let url = rawURL.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        try validateRegularReadableFile(at: url, displayName: url.lastPathComponent)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let isImage = isDecodableImage(at: url)
        return TaskAttachment(
            id: id,
            kind: isImage ? .image : .file,
            displayName: url.lastPathComponent,
            path: url.path,
            byteCount: values?.fileSize.map(Int64.init),
            isManaged: false
        )
    }

    private func storePastedImage(
        _ data: Data,
        draft: TaskAttachmentDraft,
        taskID: UUID
    ) throws -> TaskAttachment {
        guard isDecodableImage(data: data) else {
            throw AttachmentStorageError.invalidImage(draft.displayName)
        }
        let directory = taskDirectory(taskID: taskID)
        let fileURL = directory.appendingPathComponent("\(draft.id.uuidString).png", isDirectory: false)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directory.path
            )
            try data.write(to: fileURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw AttachmentStorageError.storageFailed(error.localizedDescription)
        }
        return TaskAttachment(
            id: draft.id,
            kind: .image,
            displayName: draft.displayName,
            path: fileURL.path,
            byteCount: Int64(data.count),
            isManaged: true
        )
    }

    private func validateRegularReadableFile(at url: URL, displayName: String) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              fileManager.isReadableFile(atPath: url.path)
        else {
            throw AttachmentStorageError.missingOrUnreadable(displayName)
        }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard !isDirectory.boolValue, values?.isRegularFile == true else {
            throw AttachmentStorageError.notARegularFile(displayName)
        }
    }

    private func isDecodableImage(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    private func isDecodableImage(data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    private func taskDirectory(taskID: UUID) -> URL {
        rootDirectory.appendingPathComponent(taskID.uuidString, isDirectory: true)
    }

    private func removeTaskDirectory(taskID: UUID) throws {
        let directory = taskDirectory(taskID: taskID)
        guard directory.deletingLastPathComponent().standardizedFileURL.path == rootDirectory.path else { return }
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }
}
