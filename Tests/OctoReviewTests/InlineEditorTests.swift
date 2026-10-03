import AppKit
import SwiftUI
import XCTest
import OctoCore
@testable import OctoReview

@MainActor final class InlineEditorTests: XCTestCase {
    func testNativeSourceAttributesKeepTextKitAndExactSource() {
        var source = "let octopus = \"🐙\"\r\n\r\nprint(octopus)\r\n"
        let snapshot = ReviewSnapshot(projectID: UUID(), workingDirectory: "/tmp/repo", path: "file.swift", scope: .file, baseRevision: "abc", lines: [])
        let editor = NativeFileEditor(text: Binding(get: { source }, set: { source = $0 }), context: snapshot, state: NativeFileEditorState(), onSelection: { _ in }, onAskAgent: { _ in })
        let coordinator = editor.makeCoordinator()
        let view = ReviewTextView(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.textContainerInset = NSSize(width: 82, height: 12)
        coordinator.textView = view; view.delegate = coordinator
        view.string = source
        coordinator.updateDocument()
        XCTAssertEqual(view.string, source)
        XCTAssertNotNil(view.textLayoutManager)
        let layout = view.textLayoutManager!
        layout.ensureLayout(for: layout.documentRange)
        let lines = SourceLineRuler.lines(in: view)
        XCTAssertEqual(lines.map { $0.0 }, [1, 2, 3])
        XCTAssertTrue(lines[0].1.minY < lines[1].1.minY)
    }
    func testUndoHistoryIsIndependentForEachFile() {
        let first = ReviewTextView(usingTextLayoutManager: true), second = ReviewTextView(usingTextLayoutManager: true)
        for view in [first, second] { view.fileUndoManager = UndoManager(); view.allowsUndo = true; view.isEditable = true }
        first.insertText("first", replacementRange: NSRange(location: 0, length: 0))
        second.insertText("second", replacementRange: NSRange(location: 0, length: 0))
        first.undo(nil)
        XCTAssertEqual(first.string, "")
        XCTAssertEqual(second.string, "second")
        first.redo(nil)
        XCTAssertEqual(first.string, "first")
        second.undo(nil)
        XCTAssertEqual(second.string, "")
        XCTAssertEqual(first.string, "first")
    }

}
