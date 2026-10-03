import XCTest
@testable import OctoCore

final class SourceDocumentTests: XCTestCase {
    private let context = ReviewSnapshot(projectID: UUID(), workingDirectory: "/tmp/checkout", path: "file.swift", scope: .file, baseRevision: "abc", lines: [])
    func testExactUnicodeCRLFSelectionAndBoundaryLines() throws {
        let text = "let 🐙 = 1\r\n\r\nlast"
        let document = SourceDocument(text: text, context: context)
        let selected = (text as NSString).range(of: "🐙 = 1\r\n\r\n")
        let capture = try XCTUnwrap(document.attachment(for: selected))
        XCTAssertEqual(capture.text, "🐙 = 1\r\n\r\n")
        XCTAssertEqual(capture.newLines, 1...2); XCTAssertNil(capture.oldLines)
        XCTAssertEqual(capture.workingDirectory, context.workingDirectory)
        XCTAssertEqual(capture.baseRevision, "abc"); XCTAssertEqual(capture.scope, .file)
        let blank = try XCTUnwrap(document.attachmentRange(forLineAtUTF16Offset: document.segments[1].displayRange.location, selection: .init(location: 0, length: 0)))
        XCTAssertEqual(document.attachment(for: blank)?.newLines, 2...2)
        XCTAssertEqual(document.attachment(for: blank)?.text, "\r\n")
        XCTAssertEqual(document.attachmentRange(forLineAtUTF16Offset: 0, selection: selected), selected)
        XCTAssertNil(document.attachment(for: .init(location: NSNotFound, length: 1)))
        XCTAssertNil(document.attachment(for: .init(location: 0, length: Int.max)))
    }
    func testSnapshotsCaptureUnsavedSourceAndLineEndings() throws {
        let a = SourceDocument(text: "one\ntwo\n", context: context)
        let b = SourceDocument(text: "one\r\ntwo\r\n", context: context)
        let c = SourceDocument(text: "one\ntwo", context: context)
        XCTAssertNotEqual(a.snapshot.id, b.snapshot.id); XCTAssertNotEqual(a.snapshot.id, c.snapshot.id)
        let capture = try XCTUnwrap(a.attachment(for: .init(location: 4, length: 3)))
        XCTAssertEqual(capture.text, "two"); XCTAssertEqual(capture.newLines, 2...2)
        let changed = SourceDocument(text: "new\none\ntwo\n", context: context)
        XCTAssertNotEqual(changed.snapshot.id, capture.snapshotID)
        XCTAssertEqual(capture.text, "two")
        XCTAssertEqual(SourceDocument(text: "", context: context).segments.count, 1)
    }
}
