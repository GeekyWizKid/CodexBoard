import XCTest
@testable import CodexBoard

final class UnifiedDiffParserTests: XCTestCase {
    func testCodeDeliveryDropsEmptyDiffAndCapsPersistedPayload() throws {
        XCTAssertNil(TaskCodeDelivery.capturing("  \n\t"))

        let oversized = String(
            repeating: "+let delivered = true\n",
            count: TaskCodeDelivery.maximumStoredBytes / 10
        )
        let delivery = try XCTUnwrap(TaskCodeDelivery.capturing(oversized))

        XCTAssertTrue(delivery.isTruncated)
        XCTAssertLessThanOrEqual(delivery.unifiedDiff.utf8.count, TaskCodeDelivery.maximumStoredBytes)
        XCTAssertTrue(delivery.unifiedDiff.hasSuffix("\n"))
    }

    func testParsesMultipleFilesStatsAndLineNumbers() throws {
        let diff = """
        diff --git a/Sources/Feature.swift b/Sources/Feature.swift
        index 1111111..2222222 100644
        --- a/Sources/Feature.swift
        +++ b/Sources/Feature.swift
        @@ -10,3 +10,4 @@ struct Feature {
             let title: String
        -    let enabled = false
        +    let enabled = true
        +    let note = "ready"
         }
        diff --git a/Tests/FeatureTests.swift b/Tests/FeatureTests.swift
        new file mode 100644
        --- /dev/null
        +++ b/Tests/FeatureTests.swift
        @@ -0,0 +1,2 @@
        +import XCTest
        +final class FeatureTests: XCTestCase {}
        """

        let document = UnifiedDiffParser.parse(diff)

        XCTAssertEqual(document.files.map(\.path), [
            "Sources/Feature.swift",
            "Tests/FeatureTests.swift"
        ])
        XCTAssertEqual(document.additions, 4)
        XCTAssertEqual(document.deletions, 1)
        XCTAssertEqual(document.files[1].kind, .added)

        let firstAddition = try XCTUnwrap(document.files[0].lines.first(where: { $0.kind == .addition }))
        XCTAssertNil(firstAddition.oldLineNumber)
        XCTAssertEqual(firstAddition.newLineNumber, 11)
        let deletion = try XCTUnwrap(document.files[0].lines.first(where: { $0.kind == .deletion }))
        XCTAssertEqual(deletion.oldLineNumber, 11)
        XCTAssertNil(deletion.newLineNumber)
    }

    func testFileHeadersAreNotCountedAsChanges() throws {
        let document = UnifiedDiffParser.parse("""
        diff --git a/old.txt b/old.txt
        deleted file mode 100644
        --- a/old.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -old
        """)

        let file = try XCTUnwrap(document.files.first)
        XCTAssertEqual(file.kind, .deleted)
        XCTAssertEqual(file.additions, 0)
        XCTAssertEqual(file.deletions, 1)
        XCTAssertEqual(file.lines.filter { $0.kind == .fileHeader }.count, 3)
    }

    func testCodeLinesThatResembleFileHeadersRemainChangesInsideHunk() throws {
        let document = UnifiedDiffParser.parse("""
        diff --git a/options.txt b/options.txt
        --- a/options.txt
        +++ b/options.txt
        @@ -1 +1 @@
        --- old option
        +++ new option
        """)

        let file = try XCTUnwrap(document.files.first)
        XCTAssertEqual(file.additions, 1)
        XCTAssertEqual(file.deletions, 1)
        XCTAssertEqual(file.lines.last(where: { $0.kind == .deletion })?.content, "-- old option")
        XCTAssertEqual(file.lines.last(where: { $0.kind == .addition })?.content, "++ new option")
    }

    func testParsesRenameAndGitQuotedUnicodePath() throws {
        let document = UnifiedDiffParser.parse("""
        diff --git "a/\\346\\265\\213\\350\\257\\225.txt" "b/\\344\\272\\244\\344\\273\\230.txt"
        similarity index 100%
        rename from \\346\\265\\213\\350\\257\\225.txt
        rename to \\344\\272\\244\\344\\273\\230.txt
        """)

        let file = try XCTUnwrap(document.files.first)
        XCTAssertEqual(file.kind, .renamed)
        XCTAssertEqual(file.oldPath, "测试.txt")
        XCTAssertEqual(file.newPath, "交付.txt")
        XCTAssertEqual(file.path, "交付.txt")
    }

    func testBinaryDiffRemainsVisibleWithoutFalseLineCounts() throws {
        let document = UnifiedDiffParser.parse("""
        diff --git a/Assets/preview.png b/Assets/preview.png
        new file mode 100644
        index 0000000..1234567
        Binary files /dev/null and b/Assets/preview.png differ
        """)

        let file = try XCTUnwrap(document.files.first)
        XCTAssertEqual(file.kind, .binary)
        XCTAssertEqual(file.path, "Assets/preview.png")
        XCTAssertEqual(file.additions, 0)
        XCTAssertEqual(file.deletions, 0)
        XCTAssertTrue(file.rawPatch.contains("Binary files"))
    }
}
