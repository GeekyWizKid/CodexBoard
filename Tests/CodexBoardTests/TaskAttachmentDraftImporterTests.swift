import AppKit
import XCTest
@testable import CodexBoard

@MainActor
final class TaskAttachmentDraftImporterTests: XCTestCase {
    func testFileImportDeduplicatesCanonicalPathsAndRejectsDirectories() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("需求 截图.png")
        let second = directory.appendingPathComponent("notes.md")
        try Self.pngData.write(to: first)
        try Data("notes".utf8).write(to: second)
        let existing = [TaskAttachmentDraft.file(first)]

        let outcome = TaskAttachmentDraftImporter.importFiles(
            [first, second, second, directory],
            existing: existing
        )

        XCTAssertEqual(outcome.drafts.count, 1)
        XCTAssertEqual(outcome.drafts.first?.displayName, "notes.md")
        XCTAssertTrue(outcome.message?.contains(directory.lastPathComponent) == true)
    }

    func testPastedImageNamesFillFirstAvailableSlot() {
        let existing = [
            TaskAttachmentDraft(
                displayName: "粘贴的图片 1.png",
                source: .pastedImage(Self.pngData)
            ),
            TaskAttachmentDraft(
                displayName: "粘贴的图片 3.png",
                source: .pastedImage(Self.pngData)
            )
        ]

        XCTAssertEqual(
            TaskAttachmentDraftImporter.nextPastedImageName(existing: existing),
            "粘贴的图片 2.png"
        )
    }

    func testPasteboardPrefersFinderFileURLOverImageRepresentation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("source.png")
        try Self.pngData.write(to: imageURL)
        let pasteboard = NSPasteboard(name: .init("CodexBoardTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([imageURL as NSURL]),
              pasteboard.setData(Self.pngData, forType: .png)
        else {
            throw XCTSkip("当前运行环境无法使用命名 NSPasteboard；保留在有 pasteboard 服务的 CI 中验证。")
        }

        let result = TaskAttachmentDraftImporter.importPasteboard(pasteboard, existing: [])

        guard case let .attachments(outcome) = result,
              let draft = outcome.drafts.first
        else { return XCTFail("Expected one attachment") }
        guard case let .file(url) = draft.source else {
            return XCTFail("Finder image must remain a file URL")
        }
        XCTAssertEqual(url.path, imageURL.path)
        XCTAssertEqual(outcome.drafts.count, 1)
    }

    func testPasteboardImageBecomesPNGWhilePlainTextIsUnsupported() throws {
        let imagePasteboard = NSPasteboard(name: .init("CodexBoardTests-\(UUID().uuidString)"))
        defer { imagePasteboard.releaseGlobally() }
        imagePasteboard.clearContents()
        guard imagePasteboard.setData(Self.pngData, forType: .png) else {
            throw XCTSkip("当前运行环境无法使用命名 NSPasteboard；保留在有 pasteboard 服务的 CI 中验证。")
        }

        let imageResult = TaskAttachmentDraftImporter.importPasteboard(imagePasteboard, existing: [])
        guard case let .attachments(outcome) = imageResult,
              let draft = outcome.drafts.first
        else { return XCTFail("Expected pasted image") }
        guard case let .pastedImage(data) = draft.source else {
            return XCTFail("Expected in-memory image")
        }
        XCTAssertEqual(data, Self.pngData)
        XCTAssertEqual(draft.displayName, "粘贴的图片 1.png")

        let textPasteboard = NSPasteboard(name: .init("CodexBoardTests-\(UUID().uuidString)"))
        defer { textPasteboard.releaseGlobally() }
        textPasteboard.clearContents()
        guard textPasteboard.setString("normal text", forType: .string) else {
            throw XCTSkip("当前运行环境无法使用命名 NSPasteboard；保留在有 pasteboard 服务的 CI 中验证。")
        }
        guard case .unsupported = TaskAttachmentDraftImporter.importPasteboard(
            textPasteboard,
            existing: []
        ) else {
            return XCTFail("Plain text must remain available to the native text editor")
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskAttachmentDraftImporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static let pngData = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z4i0AAAAASUVORK5CYII="
    )!
}
