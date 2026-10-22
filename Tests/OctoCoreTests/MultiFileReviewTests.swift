import XCTest
@testable import OctoCore

final class MultiFileReviewTests: XCTestCase {
    private let project = UUID()
    private func snapshot(_ path: String, scope: DiffScope = .working, lines: [DiffLine], notice: String? = nil) -> ReviewSnapshot {
        ReviewSnapshot(projectID: project, workingDirectory: "/repo", path: path, scope: scope, baseRevision: "abc", lines: lines, notice: notice)
    }
    private func fixture() -> ReviewDocument {
        let a = snapshot("Sources/A.swift", lines: [.init(id: 0, kind: .header, text: "@@ -1,2 +1,2 @@"),
                                                   .init(id: 1, kind: .deletion, text: "old a", oldLine: 1),
                                                   .init(id: 2, kind: .addition, text: "new a", newLine: 1)])
        let b = snapshot("B.md", scope: .staged, lines: [.init(id: 0, kind: .header, text: "@@ -5 +5 @@"),
                                                        .init(id: 1, kind: .addition, text: "new b", newLine: 5),
                                                        .init(id: 2, kind: .header, text: "@@ -9 +9 @@"),
                                                        .init(id: 3, kind: .context, text: "same", oldLine: 9, newLine: 9)])
        let image = snapshot("image.png", lines: [], notice: "Binary file changed.")
        return ReviewDocument(files: [a, b, image])
    }
    private func range(of needle: String, in document: ReviewDocument) -> NSRange { (document.text as NSString).range(of: needle) }

    func testFilesHaveTitleRowsAndKeepTheirOwnSnapshotsInCaptures() {
        let document = fixture()
        XCTAssertTrue(document.isMultiFile)
        XCTAssertEqual(document.files.map(\.snapshot.path), ["Sources/A.swift", "B.md", "image.png"])
        XCTAssertTrue(document.text.hasPrefix("Sources/A.swift  ·  Unstaged\n"))
        XCTAssertTrue(document.text.contains("\n\nB.md  ·  Staged\n"), "A blank row separates files")
        XCTAssertTrue(document.text.contains("Binary file changed."))

        let captured = document.attachment(for: range(of: "new b", in: document))
        XCTAssertEqual(captured?.path, "B.md")
        XCTAssertEqual(captured?.scope, .staged)
        XCTAssertEqual(captured?.newLines, 5...5)
        XCTAssertEqual(captured?.snapshotID, document.files[1].snapshot.id)

        // A selection starting in one file and ending in the next captures only the first file.
        let start = range(of: "old a", in: document), end = range(of: "new b", in: document)
        let spanning = document.attachment(for: NSRange(location: start.location, length: NSMaxRange(end) - start.location))
        XCTAssertEqual(spanning?.path, "Sources/A.swift")
        XCTAssertEqual(spanning?.text, "old a\nnew a")

        // Title rows and notes are never attachable.
        XCTAssertNil(document.attachment(for: range(of: "B.md  ·  Staged", in: document)))
        XCTAssertNil(document.attachmentRange(forLineAtUTF16Offset: range(of: "B.md  ·", in: document).location, selection: NSRange(location: 0, length: 0)))
        XCTAssertNil(document.attachment(for: range(of: "Binary file changed.", in: document)))
    }

    func testHunksStayWithinTheirFile() {
        let document = fixture()
        let headerB = document.segments.firstIndex { $0.file == 1 && $0.line.id == 0 }
        let secondB = document.segments.firstIndex { $0.file == 1 && $0.line.id == 2 }
        XCTAssertEqual(document.hunkHeader(atUTF16Offset: range(of: "new b", in: document).location), headerB)
        XCTAssertEqual(document.hunkHeader(atUTF16Offset: range(of: "same", in: document).location), secondB)
        XCTAssertEqual(document.segments[secondB!].file, 1)
        XCTAssertNil(document.hunkHeader(atUTF16Offset: range(of: "B.md  ·", in: document).location), "The title row belongs to no hunk")
        XCTAssertNil(document.hunkHeader(atUTF16Offset: range(of: "Binary", in: document).location), "Not the previous file's last hunk")
        XCTAssertEqual(document.file(atUTF16Offset: range(of: "B.md  ·", in: document).location), 1)
        XCTAssertEqual(document.file(atUTF16Offset: range(of: "old a", in: document).location), 0)
        XCTAssertNil(document.file(atUTF16Offset: (document.text as NSString).length))
    }

    func testIdentityFollowsEveryFile() {
        let one = fixture(), two = fixture()
        XCTAssertEqual(one.snapshot.id, two.snapshot.id, "Unchanged files keep the document's identity, so a refresh does not redraw")
        var files = one.files.map(\.snapshot)
        files[1] = snapshot("B.md", scope: .staged, lines: [.init(id: 0, kind: .addition, text: "changed", newLine: 5)])
        XCTAssertNotEqual(ReviewDocument(files: files).snapshot.id, one.snapshot.id)
        XCTAssertTrue(ReviewDocument(files: []).text.isEmpty)
        // Single-file documents are unchanged: one section, no title row.
        let single = ReviewDocument(snapshot: files[0])
        XCTAssertFalse(single.isMultiFile)
        XCTAssertEqual(single.files.count, 1)
        XCTAssertEqual(single.hunkHeader(atUTF16Offset: 0), 0, "A single file has no title row before its first hunk")
    }
}
