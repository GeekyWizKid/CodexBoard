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
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([imageURL as NSURL]))
        XCTAssertTrue(pasteboard.setData(Self.pngData, forType: .png))

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
        imagePasteboard.clearContents()
        XCTAssertTrue(imagePasteboard.setData(Self.pngData, forType: .png))

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
        textPasteboard.clearContents()
        XCTAssertTrue(textPasteboard.setString("normal text", forType: .string))
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
