import AppKit
import Combine
import SwiftUI
import XCTest
import OctoCore
@testable import OctoApp

@MainActor final class ThreadFindHighlightTests: XCTestCase {
    func testHighlightingMarksEachOccurrenceAndTheCurrentMessageStrongly() {
        let text = AttributedString("Find me, then find me again")
        let other = text.highlighting(FindHighlight(query: "find", current: false), theme: .system)
        XCTAssertEqual(other.runs.filter { $0.backgroundColor != nil }.map { String(other[$0.range].characters) }, ["Find", "find"])
        let current = text.highlighting(FindHighlight(query: "find", current: true), theme: .system)
        XCTAssertEqual(current.runs.filter { $0.foregroundColor == .black }.count, 2, "The current message's matches use dark text on yellow")
        XCTAssertEqual(text.highlighting(nil, theme: .system), text)
    }

    func testTypingInFindDoesNotRepublishTheStore() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(storage: WorkspaceStore(fileURL: root.appendingPathComponent("workspace.json")))
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        var publications = 0
        let subscription = store.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        for prefix in ["c", "ca", "caf", "cafe"] { store.threadFind.query = prefix }
        store.threadFind.move(1)
        XCTAssertEqual(publications, 0, "Each keystroke used to re-render every view observing the store")
    }
}

private final class FindKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

@MainActor final class ThreadFindFocusTests: XCTestCase {
    /// ⌘F used to open the bar without focusing it: the command asked a field that still refused
    /// focus, and only a second ⌘F reached it.
    func testFirstCommandFFocusesTheFindField() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(storage: WorkspaceStore(fileURL: root.appendingPathComponent("workspace.json")))
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        var thread = WorkspaceThread(title: "Find", harness: .claude, workingDirectory: root.path)
        thread.messages = [.init(role: .user, text: "Find the café"), .init(role: .assistant, text: "Found the **cafe**.")]
        let project = WorkspaceProject(name: "Fixture", rootPath: root.path, threads: [thread])
        store.archive = WorkspaceArchive(projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id)
        let host = NSHostingView(rootView: WorkspaceView(store: store))
        let window = FindKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(500))
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        XCTAssertNil(views(host).first { $0.identifier?.rawValue == "OctoThreadFind" }, "A closed find bar is not mounted")
        window.makeFirstResponder(views(host).first { $0 is ScreenshotTextView })

        let commandF = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                                        context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
        NSApp.sendEvent(commandF)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(store.findingThread)
        let field = try XCTUnwrap(views(host).first { $0.identifier?.rawValue == "OctoThreadFind" } as? NSSearchField)
        let editor = window.firstResponder as? NSTextView
        XCTAssertTrue(editor?.delegate === field, "The first ⌘F puts the caret in the find field")
        editor?.insertText("cafe", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.threadFind.query, "cafe")
    }
}
