import XCTest
@testable import OctoCore

final class SideBySideReviewTests: XCTestCase {
    private func snapshot(_ lines: [DiffLine], scope: DiffScope = .working) -> ReviewSnapshot {
        ReviewSnapshot(projectID: UUID(), workingDirectory: "/tmp/repo", path: "renamed.swift", scope: scope, baseRevision: "abc", lines: lines)
    }
    private func row(_ segment: ReviewDocument.Segment, in document: ReviewDocument) -> Int {
        (document.text as NSString).substring(to: segment.displayRange.location).filter { $0 == "\n" }.count
    }
    func testChangeBlocksAlignWithoutCrossingContextOrHunks() {
        let source = snapshot([
            .init(id: 0, kind: .header, text: "@@ -2,4 +2,3 @@"),
            .init(id: 1, kind: .deletion, text: "old one", oldLine: 2),
            .init(id: 2, kind: .deletion, text: "old two", oldLine: 3),
            .init(id: 3, kind: .addition, text: "new one", newLine: 2),
            .init(id: 4, kind: .context, text: "same", oldLine: 4, newLine: 3),
            .init(id: 5, kind: .header, text: "@@ -20 +19,2 @@"),
            .init(id: 6, kind: .addition, text: "insert", newLine: 19),
            .init(id: 7, kind: .context, text: "end", oldLine: 20, newLine: 20)
        ])
        let pair = ReviewDocument.sideBySide(snapshot: source)
        XCTAssertEqual(pair.before.segments.map { row($0, in: pair.before) }, [0, 1, 2, 3, 4, 6])
        XCTAssertEqual(pair.after.segments.map { row($0, in: pair.after) }, [0, 1, 3, 4, 5, 6])
        XCTAssertEqual(pair.before.text.filter { $0 == "\n" }.count, pair.after.text.filter { $0 == "\n" }.count)
        for doc in [pair.before, pair.after] {
            XCTAssertEqual(doc.snapshot, source)
            let capture = doc.attachment(for: NSRange(location: 0, length: doc.text.utf16.count))
            XCTAssertEqual(capture?.snapshotID, source.id)
            XCTAssertEqual(capture?.workingDirectory, source.workingDirectory)
            XCTAssertEqual(capture?.path, source.path)
            XCTAssertFalse(capture!.text.contains("@@"))
        }
        XCTAssertEqual(pair.before.attachment(for: NSRange(location: 0, length: pair.before.text.utf16.count))?.text, "old one\nold two\nsame\nend")
        XCTAssertEqual(pair.after.attachment(for: NSRange(location: 0, length: pair.after.text.utf16.count))?.text, "new one\nsame\ninsert\nend")
        // Alignment gaps before another real row must not resolve to that next row.
        let gap = pair.after.segments[2].displayRange.location - 1
        XCTAssertNil(pair.after.attachmentRange(forLineAtUTF16Offset: gap, selection: NSRange(location: 0, length: 0)))
        XCTAssertNil(pair.after.attachment(for: NSRange(location: gap, length: 1)))
    }
    func testSelectionsKeepSideSpecificLinesUnicodeAndActualBlankSource() throws {
        let source = snapshot([
            .init(id: 0, kind: .deletion, text: "old 🐙 café", oldLine: 12),
            .init(id: 1, kind: .addition, text: "new 🐙 café", newLine: 15),
            .init(id: 2, kind: .addition, text: "", newLine: 16)
        ], scope: .staged)
        let pair = ReviewDocument.sideBySide(snapshot: source)
        for doc in [pair.before, pair.after] {
            let capture = try XCTUnwrap(doc.attachment(for: (doc.text as NSString).range(of: "🐙 café")))
            XCTAssertEqual(capture.text, "🐙 café")
            XCTAssertEqual(capture.oldLines, doc.side == .before ? 12...12 : nil)
            XCTAssertEqual(capture.newLines, doc.side == .after ? 15...15 : nil)
            XCTAssertEqual(capture.scope, .staged)
        }
        let blank = pair.after.segments[1]
        let range = try XCTUnwrap(pair.after.attachmentRange(forLineAtUTF16Offset: blank.displayRange.location, selection: NSRange(location: 0, length: 0)))
        XCTAssertEqual(pair.after.attachment(for: range)?.text, "")
        XCTAssertEqual(pair.after.attachment(for: range)?.newLines, 16...16)
        XCTAssertNil(pair.before.attachmentRange(forLineAtUTF16Offset: pair.before.text.utf16.count - 1, selection: range))
    }
    func testOnlyAddedDeletedEmptyAndMissingNewlineSnapshots() {
        for kind in [DiffLineKind.addition, .deletion] {
            let pair = ReviewDocument.sideBySide(snapshot: snapshot([
                .init(id: 0, kind: kind, text: "source", oldLine: kind == .deletion ? 1 : nil, newLine: kind == .addition ? 1 : nil)
            ]))
            let empty = kind == .addition ? pair.before : pair.after
            XCTAssertEqual(empty.text, "\n")
            XCTAssertNil(empty.attachment(for: NSRange(location: 0, length: 1)))
            XCTAssertNil(empty.attachmentRange(forLineAtUTF16Offset: 0, selection: NSRange(location: 0, length: 0)))
        }
        let empty = ReviewDocument.sideBySide(snapshot: snapshot([]))
        XCTAssertEqual(empty.before.text, ""); XCTAssertEqual(empty.after.text, "")
        let pair = ReviewDocument.sideBySide(snapshot: snapshot([
            .init(id: 0, kind: .deletion, text: "old", oldLine: 1),
            .init(id: 1, kind: .header, text: "\\ No newline at end of file"),
            .init(id: 2, kind: .addition, text: "new", newLine: 1)
        ]))
        XCTAssertEqual(row(pair.before.segments[0], in: pair.before), row(pair.after.segments[0], in: pair.after))
        XCTAssertNil(pair.before.attachment(for: pair.before.segments[1].contentRange))
    }
}
