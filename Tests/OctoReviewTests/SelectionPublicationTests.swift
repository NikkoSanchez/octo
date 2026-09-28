import AppKit
import XCTest
import OctoCore
@testable import OctoReview

@MainActor final class SelectionPublicationTests: XCTestCase {
    private func document(_ text: String) -> ReviewDocument {
        ReviewDocument(snapshot: ReviewSnapshot(projectID: UUID(), workingDirectory: "/tmp/repo", path: "code.swift", scope: .working, baseRevision: "abc", lines: [.init(id: 0, kind: .addition, text: text, newLine: 12)]))
    }
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
    func testSelectionIsDeferredAndDuplicateUpdatesDoNotRepublish() async {
        let doc = document("let octo = 1")
        var selections: [CodeAttachment?] = []
        let coordinator = NativeDiffView(snapshot: doc.snapshot, onSelection: { selections.append($0) }, onAskAgent: { _ in }).makeCoordinator()
        let text = ReviewTextView(usingTextLayoutManager: true)
        coordinator.document = doc; coordinator.textView = text; text.delegate = coordinator
        coordinator.updatingView = true
        text.textStorage?.setAttributedString(NativeDiffView.render(doc, theme: .system))
        text.setSelectedRange(doc.segments[0].contentRange)
        XCTAssertTrue(selections.isEmpty)
        coordinator.updatingView = false
        coordinator.scheduleSelection()
        XCTAssertTrue(selections.isEmpty)
        await drainMainQueue()
        XCTAssertEqual(selections.count, 1)
        XCTAssertEqual(selections[0]?.text, "let octo = 1")
        XCTAssertEqual(selections[0]?.newLines, 12...12)
        for _ in 0..<100 { coordinator.scheduleSelection() }
        await drainMainQueue()
        XCTAssertEqual(selections.count, 1)
    }
    func testSnapshotReplacementDiscardsQueuedSelection() async {
        let old = document("old"), new = document("new")
        var selections: [CodeAttachment?] = []
        let coordinator = NativeDiffView(snapshot: old.snapshot, onSelection: { selections.append($0) }, onAskAgent: { _ in }).makeCoordinator()
        let text = ReviewTextView(usingTextLayoutManager: true)
        coordinator.textView = text; coordinator.document = old
        text.string = old.text; text.setSelectedRange(old.segments[0].contentRange)
        coordinator.scheduleSelection()
        coordinator.document = new
        text.string = new.text; text.setSelectedRange(new.segments[0].contentRange)
        coordinator.scheduleSelection()
        await drainMainQueue()
        XCTAssertEqual(selections.count, 1)
        XCTAssertEqual(selections[0]?.text, "new")
        text.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.scheduleSelection()
        await drainMainQueue()
        XCTAssertEqual(selections.count, 2)
        XCTAssertNil(selections[1])
    }
}
