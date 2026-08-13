import Foundation
import XCTest
@testable import CodexBoard

final class AttachmentStorageTests: XCTestCase {
    func testMaterializesPrivateScreenshotAndPreservesExternalFileOnCleanup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBoardAttachmentTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let externalFile = root.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: externalFile)
        let managedRoot = root.appendingPathComponent("managed", isDirectory: true)
        let storage = AttachmentStorage(rootDirectory: managedRoot)
        let taskID = UUID()

        let attachments = try await storage.materialize(
            [
                .file(externalFile),
                TaskAttachmentDraft(
                    displayName: "Screenshot.png",
                    byteCount: Int64(Self.pngData.count),
                    source: .pastedImage(Self.pngData)
                )
            ],
            taskID: taskID
        )

        XCTAssertEqual(attachments.map(\.kind), [.file, .image])
        XCTAssertFalse(attachments[0].isManaged)
        XCTAssertTrue(attachments[1].isManaged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachments[1].path))
        XCTAssertEqual(try permissions(at: managedRoot.appendingPathComponent(taskID.uuidString)), 0o700)
        XCTAssertEqual(try permissions(at: URL(fileURLWithPath: attachments[1].path)), 0o600)
        try await storage.validate(attachments)

        await storage.removeManagedAttachments(taskID: taskID, attachments: attachments)

        XCTAssertTrue(FileManager.default.fileExists(atPath: externalFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachments[1].path))
    }

    func testRejectsMissingExternalFile() async {
        let storage = AttachmentStorage()
        let attachment = TaskAttachment(
            kind: .file,
            displayName: "missing.txt",
            path: "/tmp/does-not-exist-\(UUID().uuidString)"
        )

        do {
            try await storage.validate([attachment])
            XCTFail("Expected validation to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("missing.txt"))
        }
    }

    func testRejectsDirectoryAttachment() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBoardDirectoryAttachment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storage = AttachmentStorage()

        do {
            _ = try await storage.materialize([.file(directory)], taskID: UUID())
            XCTFail("Expected directory attachment to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("不是普通文件"))
        }
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let value = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return value.intValue & 0o777
    }

    private static let pngData = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z4i0AAAAASUVORK5CYII="
    )!
}
