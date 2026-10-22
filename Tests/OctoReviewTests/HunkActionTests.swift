import AppKit
import XCTest
import OctoCore
@testable import OctoReview

@MainActor final class HunkActionTests: XCTestCase {
    private func snapshot() -> ReviewSnapshot {
        var lines: [DiffLine] = [.init(id: 0, kind: .header, text: "@@ -1,2 +1,2 @@"),
                                 .init(id: 1, kind: .deletion, text: "old", oldLine: 1),
                                 .init(id: 2, kind: .addition, text: "new", newLine: 1),
                                 .init(id: 3, kind: .header, text: "@@ -40,1 +40,1 @@ func later()")]
        lines.append(.init(id: 4, kind: .addition, text: "later", newLine: 40))
        lines.append(.init(id: 5, kind: .header, text: "\\ No newline at end of file"))
        return ReviewSnapshot(projectID: UUID(), workingDirectory: "/tmp/repo", path: "code.swift", scope: .working, baseRevision: "abc", lines: lines)
    }
    private func host(_ scroll: NSScrollView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scroll.frame = window.contentView!.bounds
        window.contentView?.addSubview(scroll)
        scroll.layoutSubtreeIfNeeded()
        return window
    }
    private func buttons(_ text: NSView) -> [NSButton] { text.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden && $0.title.hasSuffix("Hunk") } }

    func testEachHunkHeaderGetsAButtonThatReportsItsHeader() {
        let scroll = NativeDiffView.makeScrollView(), text = scroll.documentView as! ReviewTextView
        let window = host(scroll); defer { window.close() }
        let document = ReviewDocument(snapshot: snapshot())
        text.reviewDocument = document
        text.textStorage?.setAttributedString(NativeDiffView.render(document, theme: .system))
        var performed: [Int] = []
        text.hunkAction = HunkAction(title: "Stage Hunk") { performed.append($0) }
        text.layoutHunkButtons()

        let shown = buttons(text)
        XCTAssertEqual(shown.count, 2, "Only @@ rows get the action; Git's missing-newline note does not")
        XCTAssertEqual(shown.map(\.tag), [0, 3])
        XCTAssertTrue(shown.allSatisfy { $0.frame.maxX <= text.visibleRect.maxX && $0.frame.minX > text.visibleRect.midX }, "Trailing edge of the visible row")
        guard shown.count == 2 else { return }
        XCTAssertLessThan(shown[0].frame.minY, shown[1].frame.minY)
        shown[1].performClick(nil)
        XCTAssertEqual(performed, [3])

        text.hunkAction = HunkAction(title: "Unstage Hunk") { _ in }
        XCTAssertEqual(buttons(text).map(\.title), ["Unstage Hunk", "Unstage Hunk"])
        text.hunkAction = nil
        XCTAssertTrue(buttons(text).isEmpty, "Ineligible files show no hunk actions")
    }

    func testSideBySideShowsHunkActionsOnTheAfterPaneOnly() {
        var performed: [Int] = []
        let view = SideBySideReviewView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; defer { window.close() }
        view.texts[1].hunkAction = HunkAction(title: "Stage Hunk") { performed.append($0) }
        view.update(snapshot: snapshot(), theme: .system, focusRequest: 0)
        view.layoutSubtreeIfNeeded()
        view.texts[1].layoutHunkButtons()
        XCTAssertTrue(buttons(view.texts[0]).isEmpty)
        let after = buttons(view.texts[1])
        XCTAssertEqual(after.map(\.tag), [0, 3])
        after[0].performClick(nil)
        XCTAssertEqual(performed, [0])
    }
}
