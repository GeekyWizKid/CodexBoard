import Foundation
import XCTest
@testable import CodexBoard

final class CodeFileIconResolverTests: XCTestCase {
    func testRecognizesSpecialFilenamesCaseInsensitively() {
        XCTAssertEqual(resource(for: "Package.swift"), "file_type_swift")
        XCTAssertEqual(resource(for: "DOCKERFILE.dev"), "file_type_docker2")
        XCTAssertEqual(resource(for: "docs/README.MD"), "file_type_markdown")
        XCTAssertEqual(resource(for: ".github/.gitignore"), "file_type_git")
        XCTAssertEqual(resource(for: "frontend/package-lock.json"), "file_type_npm")
        XCTAssertEqual(resource(for: "pnpm-lock.yaml"), "file_type_pnpm")
    }

    func testRecognizesLanguagesAndCompoundExtensions() {
        XCTAssertEqual(resource(for: "Sources/App.swift"), "file_type_swift")
        XCTAssertEqual(resource(for: "src/types.d.ts"), "file_type_typescript_official")
        XCTAssertEqual(resource(for: "src/Widget.TSX"), "file_type_reactjs")
        XCTAssertEqual(resource(for: "scripts/check.py"), "file_type_python")
        XCTAssertEqual(resource(for: "server/main.go"), "file_type_go_gopher")
        XCTAssertEqual(resource(for: "Cargo/src/lib.rs"), "file_type_rust")
        XCTAssertEqual(resource(for: "schema/data.sql"), "file_type_sql")
    }

    func testRecognizesMediaArchivesAndFallbacks() {
        XCTAssertEqual(resource(for: "Assets/logo.svg"), "file_type_image")
        XCTAssertEqual(resource(for: "release.tar.gz"), "file_type_zip")
        XCTAssertEqual(CodeFileIconResolver.descriptor(for: "release.tar.gz").fallbackSystemName, "archivebox")
        XCTAssertEqual(CodeFileIconResolver.descriptor(for: "photo.png").fallbackSystemName, "photo")
        XCTAssertEqual(CodeFileIconResolver.descriptor(for: "archive.zip").fallbackSystemName, "archivebox")
        XCTAssertEqual(resource(for: "Makefile"), CodeFileIconResolver.defaultResourceName)
        XCTAssertEqual(resource(for: "file.unknown"), CodeFileIconResolver.defaultResourceName)
    }

    func testEveryMappedResourceExistsInSourceTree() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resourceDirectory = repositoryRoot
            .appendingPathComponent("Resources/FileIcons", isDirectory: true)

        for resourceName in CodeFileIconResolver.allResourceNames.sorted() {
            let url = resourceDirectory.appendingPathComponent("\(resourceName).svg")
            XCTAssertTrue(
                FileManager.default.isReadableFile(atPath: url.path),
                "Missing icon resource: \(url.path)"
            )
        }
    }

    private func resource(for path: String) -> String {
        CodeFileIconResolver.descriptor(for: path).resourceName
    }
}
