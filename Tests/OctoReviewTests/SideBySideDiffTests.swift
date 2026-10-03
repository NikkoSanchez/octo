import AppKit
import SwiftUI
import XCTest
import OctoCore
@testable import OctoReview

@MainActor final class SideBySideDiffTests: XCTestCase {
    private func snapshot(_ value: String = "new 🐙") -> ReviewSnapshot {
        let lines: [DiffLine] = [
            .init(id: 0, kind: .deletion, text: "/* old", oldLine: 1),
            .init(id: 1, kind: .deletion, text: "", oldLine: 2),
            .init(id: 2, kind: .addition, text: value, newLine: 1)
        ] + (3..<100).map { .init(id: $0, kind: .context, text: "context \($0)", oldLine: $0, newLine: $0 - 1) }
        return ReviewSnapshot(projectID: UUID(), workingDirectory: "/tmp/repo", path: "code.swift", scope: .working, baseRevision: "abc", lines: lines)
    }
    private func view() -> SideBySideReviewView {
        let view = SideBySideReviewView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.layoutSubtreeIfNeeded()
        view.update(snapshot: snapshot(), theme: .mocha, focusRequest: 0)
        return view
    }
    private func drain() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
    func testNativeRowsAlignAndScrollBothDirectionsWithoutLinkingHorizontalOffset() throws {
        let view = view()
        for text in view.texts {
            let layout = try XCTUnwrap(text.textLayoutManager)
            layout.ensureLayout(for: layout.documentRange)
        }
        func y(_ index: Int, _ segment: ReviewDocument.Segment) throws -> CGFloat {
            let layout = view.texts[index].textLayoutManager!
            let content = try XCTUnwrap(layout.textContentManager)
            let location = try XCTUnwrap(content.location(content.documentRange.location, offsetBy: segment.contentRange.location))
            return try XCTUnwrap(layout.textLayoutFragment(for: location)).layoutFragmentFrame.minY
        }
        XCTAssertEqual(try y(0, view.documents[0].segments[0]), try y(1, view.documents[1].segments[0]), accuracy: 0.01)
        XCTAssertEqual(try y(0, view.documents[0].segments[2]), try y(1, view.documents[1].segments[1]), accuracy: 0.01)
        let before = view.scrolls[0].contentView, after = view.scrolls[1].contentView
        before.scroll(to: NSPoint(x: 0, y: 440))
        XCTAssertEqual(after.bounds.minY, before.bounds.minY, accuracy: 0.01)
        after.scroll(to: NSPoint(x: 0, y: 880))
        XCTAssertEqual(before.bounds.minY, after.bounds.minY, accuracy: 0.01)
        before.setBoundsOrigin(NSPoint(x: 20, y: 880))
        XCTAssertEqual(after.bounds.minX, 0)
        view.setFrameSize(NSSize(width: 420, height: 500)); view.layoutSubtreeIfNeeded()
        XCTAssertEqual(before.bounds.minY, after.bounds.minY, accuracy: 0.01)
        view.update(snapshot: snapshot(String(repeating: "long text ", count: 30)), theme: .mocha, focusRequest: 0)
        XCTAssertGreaterThan(view.texts[1].frame.width, after.bounds.width)
        XCTAssertGreaterThan(view.texts[1].minSize.width, after.bounds.width)
        after.scroll(to: NSPoint(x: 240, y: 0))
        XCTAssertEqual(after.bounds.minX, 240, accuracy: 0.01)
        XCTAssertEqual(before.bounds.minX, 0, accuracy: 0.01)
        // Old-side multiline syntax state must continue through unchanged context.
        let range = view.documents[0].segments[2].contentRange
        let color = view.texts[0].textStorage?.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, NativeDiffView.color(AppTheme.mocha.palette?.overlay2, fallback: .labelColor))
    }
    func testActivePaneSelectionIsDeferredAndAttachmentsRetainTheSnapshot() async {
        let view = view()
        await drain()
        var selected: [CodeAttachment?] = [], attached: [CodeAttachment] = []
        view.onSelection = { selected.append($0) }; view.onAskAgent = { attached.append($0) }
        view.texts[0].setSelectedRange(view.documents[0].segments[0].contentRange)
        XCTAssertTrue(selected.isEmpty)
        await drain()
        XCTAssertEqual(selected.last??.text, "/* old")
        XCTAssertEqual(selected.last??.oldLines, 1...1)
        view.texts[1].setSelectedRange(view.documents[1].segments[0].contentRange)
        await drain()
        XCTAssertEqual(selected.last??.text, "new 🐙")
        XCTAssertEqual(selected.last??.newLines, 1...1)
        XCTAssertEqual(view.texts[0].selectedRange().length, 0)
        XCTAssertTrue(attached.isEmpty)
        view.attach(view.documents[0].segments[1].contentRange.union(NSRange(location: view.documents[0].segments[1].contentRange.location, length: 1)), in: 0)
        XCTAssertEqual(attached.first?.text, "")
        XCTAssertEqual(attached.first?.oldLines, 2...2)
        XCTAssertEqual(attached.first?.snapshotID, view.documents[0].snapshot.id)
    }
    func testRefreshThemeAndTeardownCannotPublishStaleSelections() async {
        let view = view()
        await drain()
        var selected: [CodeAttachment?] = []
        view.onSelection = { selected.append($0) }
        view.texts[1].setSelectedRange(view.documents[1].segments[0].contentRange)
        let range = view.texts[1].selectedRange()
        view.update(snapshot: view.documents[0].snapshot, theme: .latte, focusRequest: 0)
        XCTAssertEqual(view.texts[1].selectedRange(), range)
        view.update(snapshot: snapshot("replacement"), theme: .latte, focusRequest: 0)
        await drain()
        XCTAssertEqual(selected.count, 1); XCTAssertNil(selected[0])
        view.texts[1].setSelectedRange(view.documents[1].segments[0].contentRange)
        view.invalidate()
        await drain()
        XCTAssertEqual(selected.count, 1)
    }
    func testMountedPaneKeepsLongLinesHorizontallyScrollable() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: SideBySideDiffView(snapshot: snapshot(String(repeating: "long text ", count: 30)), onSelection: { _ in }, onAskAgent: { _ in }))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func find(_ root: NSView) -> SideBySideReviewView? {
            if let view = root as? SideBySideReviewView { return view }
            return root.subviews.compactMap(find).first
        }
        await drain()
        guard let view = find(host) else { return XCTFail("Missing native diff") }
        for scroll in view.scrolls { scroll.reflectScrolledClipView(scroll.contentView) }
        view.texts[1].setFrameSize(view.scrolls[1].contentSize)
        XCTAssertGreaterThan(view.texts[1].frame.width, view.scrolls[1].contentSize.width)
        XCTAssertTrue(view.scrolls[1].horizontalScroller?.isEnabled == true)
    }
}
