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

    func testOnlyTheHoveredHunkShowsItsActionAndReportsItsHeader() {
        let scroll = NativeDiffView.makeScrollView(), text = scroll.documentView as! ReviewTextView
        let window = host(scroll); defer { window.close() }
        let document = ReviewDocument(snapshot: snapshot())
        text.reviewDocument = document
        text.textStorage?.setAttributedString(NativeDiffView.render(document, theme: .system))
        var performed: [Int] = []
        text.hunkAction = HunkAction(title: "Stage Hunk") { performed.append($0) }
        XCTAssertTrue(buttons(text).isEmpty, "Hidden until a hunk is hovered, like the gutter +")

        text.hoveredHunk = 3
        var shown = buttons(text)
        XCTAssertEqual(shown.map(\.tag), [3])
        XCTAssertTrue(shown.allSatisfy { $0.frame.maxX <= text.visibleRect.maxX && $0.frame.minX > text.visibleRect.midX }, "Trailing edge of the visible row")
        shown.first?.performClick(nil)
        XCTAssertEqual(performed, [3])

        text.hoveredHunk = 5
        XCTAssertTrue(buttons(text).isEmpty, "Git's missing-newline note is not a hunk")
        text.hoveredHunk = 0
        shown = buttons(text)
        XCTAssertEqual(shown.map(\.tag), [0])
        text.hunkAction = HunkAction(title: "Unstage Hunk") { _ in }
        XCTAssertEqual(buttons(text).map(\.title), ["Unstage Hunk"])
        text.hunkAction = nil
        XCTAssertTrue(buttons(text).isEmpty, "Ineligible files show no hunk actions")
        text.hunkAction = HunkAction(title: "Stage Hunk") { _ in }
        text.reviewDocument = document
        XCTAssertTrue(buttons(text).isEmpty, "A replaced diff forgets the hovered hunk")
    }

    func testSideBySideShowsTheActionOnTheAfterPaneWhenEitherPaneIsHovered() {
        var performed: [Int] = []
        let view = SideBySideReviewView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; defer { window.close() }
        view.texts[1].hunkAction = HunkAction(title: "Stage Hunk") { performed.append($0) }
        view.update(snapshot: snapshot(), theme: .system, focusRequest: 0)
        view.layoutSubtreeIfNeeded()
        view.texts[0].onHoveredHunk?(0)
        XCTAssertTrue(buttons(view.texts[0]).isEmpty)
        let after = buttons(view.texts[1])
        XCTAssertEqual(after.map(\.tag), [0])
        after.first?.performClick(nil)
        XCTAssertEqual(performed, [0])
        view.texts[0].onHoveredHunk?(nil)
        XCTAssertTrue(buttons(view.texts[1]).isEmpty)
    }
}

@MainActor final class ContinuousDiffTests: XCTestCase {
    private func file(_ path: String, scope: DiffScope = .working, hunks: Int, linesPerHunk: Int = 20) -> ReviewSnapshot {
        var lines: [DiffLine] = [], id = 0
        for hunk in 0..<hunks {
            lines.append(.init(id: id, kind: .header, text: "@@ -\(hunk * 100 + 1),\(linesPerHunk) +\(hunk * 100 + 1),\(linesPerHunk) @@")); id += 1
            for line in 0..<linesPerHunk {
                lines.append(.init(id: id, kind: line == 3 ? .addition : .context, text: "\(path) line \(line)", oldLine: line == 3 ? nil : line, newLine: line)); id += 1
            }
        }
        return ReviewSnapshot(projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, workingDirectory: "/repo", path: path, scope: scope, baseRevision: "abc", lines: lines)
    }
    private func host(_ files: [ReviewSnapshot], hunkAction: HunkAction? = nil, onVisibleFile: ((Int) -> Void)? = nil) -> (NSWindow, NSScrollView, ReviewTextView, NativeDiffView.Coordinator) {
        let view = NativeDiffView(files: files, hunkAction: hunkAction, onVisibleFile: onVisibleFile, onSelection: { _ in }, onAskAgent: { _ in })
        let coordinator = view.makeCoordinator()
        let scroll = NativeDiffView.makeScrollView(), text = scroll.documentView as! ReviewTextView
        coordinator.textView = text; text.delegate = coordinator; text.hunkAction = hunkAction
        text.onScroll = { [weak coordinator] in coordinator?.reportVisibleFile() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scroll.frame = window.contentView!.bounds; window.contentView?.addSubview(scroll)
        let document = ReviewDocument(files: files)
        coordinator.document = document; text.reviewDocument = document
        text.textStorage?.setAttributedString(NativeDiffView.render(document, theme: .system))
        scroll.layoutSubtreeIfNeeded()
        return (window, scroll, text, coordinator)
    }
    private func drain() async { await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } } }

    func testRevealScrollsAFileToTheTopAndScrollingReportsTheTopFile() async {
        var reported: [Int] = []
        let files = (0..<6).map { file("File\($0).swift", hunks: 2) }
        let (window, _, text, coordinator) = host(files, onVisibleFile: { reported.append($0) }); defer { window.close(); _ = coordinator }
        XCTAssertEqual(text.topVisibleFile(), 0)
        text.reveal(file: 3)
        XCTAssertEqual(text.topVisibleFile(), 3)
        await drain()
        XCTAssertTrue(reported.isEmpty, "The view's own scroll is not reported as the reader's")
        // A reader's scroll is reported, once per file change.
        text.scroll(NSPoint(x: 0, y: text.visibleRect.minY + 900))
        await drain()
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.last, text.topVisibleFile())
        XCTAssertGreaterThan(reported.last ?? 0, 3)
    }

    func testRefreshKeepsThePlaceInTheSameFileWhenEarlierFilesGrow() {
        var files = [file("A.swift", hunks: 1), file("B.swift", hunks: 2), file("C.swift", hunks: 2)]
        let (window, _, text, coordinator) = host(files); defer { window.close(); _ = coordinator }
        text.reveal(file: 1)
        text.scroll(NSPoint(x: 0, y: text.visibleRect.minY + 60))
        let anchor = text.scrollAnchor()
        XCTAssertEqual(anchor?.path, "B.swift")
        let before = text.visibleRect.minY
        // Another file is staged above it: B's section moves down by a whole file.
        files.insert(file("Z.swift", scope: .staged, hunks: 2), at: 0)
        let document = ReviewDocument(files: files)
        text.reviewDocument = document
        text.textStorage?.setAttributedString(NativeDiffView.render(document, theme: .system))
        text.restore(anchor)
        XCTAssertEqual(text.topVisibleFile(), 2, "Still reading B.swift")
        XCTAssertGreaterThan(text.visibleRect.minY, before)
        XCTAssertEqual(text.scrollAnchor()?.offset ?? 0, anchor?.offset ?? -1, accuracy: 1)
    }

    func testHunkActionsResolveToTheirOwnFileAndSkipIneligibleFiles() {
        var performed: [(String, Int)] = []
        let files = [file("Staged.swift", scope: .staged, hunks: 1), file("Added.swift", hunks: 1), file("Edited.swift", hunks: 2)]
        let action = HunkAction(title: { $0.path == "Added.swift" ? nil : ($0.scope == .staged ? "Unstage Hunk" : "Stage Hunk") },
                                perform: { performed.append(($0.path, $1)) })
        let (window, _, text, coordinator) = host(files, hunkAction: action); defer { window.close(); _ = coordinator }
        func shown() -> [NSButton] { text.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden && $0.title.hasSuffix("Hunk") } }
        let document = text.reviewDocument!
        let editedSecond = document.segments.firstIndex { $0.file == 2 && $0.line.id == 21 }!
        text.reveal(file: 2)
        text.hoveredHunk = editedSecond
        XCTAssertEqual(shown().map(\.title), ["Stage Hunk"])
        shown().first?.performClick(nil)
        XCTAssertEqual(performed.map(\.0), ["Edited.swift"]); XCTAssertEqual(performed.map(\.1), [21], "The header's own line ID in its file")
        text.hoveredHunk = document.segments.firstIndex { $0.file == 1 && $0.line.id == 0 }
        XCTAssertTrue(shown().isEmpty, "No hunk action where the file can't stage hunks")
        text.reveal(file: 0)
        text.hoveredHunk = document.segments.firstIndex { $0.file == 0 && $0.line.id == 0 }
        XCTAssertEqual(shown().map(\.title), ["Unstage Hunk"])
    }
}
