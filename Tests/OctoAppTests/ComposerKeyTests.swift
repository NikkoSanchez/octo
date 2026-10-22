import AppKit
import SwiftUI
import XCTest
import OctoCore
@testable import OctoApp

@MainActor final class ComposerKeyTests: XCTestCase {
    private func composer(_ text: String) -> (ScreenshotTextView, NSTextField, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let editor = ScreenshotTextView(frame: NSRect(x: 0, y: 100, width: 400, height: 100))
        editor.isRichText = false; editor.allowsUndo = true
        let next = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        window.contentView?.addSubview(editor); window.contentView?.addSubview(next)
        editor.nextKeyView = next; next.nextKeyView = editor
        editor.string = text
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        window.makeFirstResponder(editor)
        return (editor, next, window)
    }
    private func key(_ editor: NSTextView, _ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: editor.window!.windowNumber,
                                     context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        editor.keyDown(with: event)
    }

    func testTabLeavesPlainTextAndNestsListItems() {
        let (editor, next, window) = composer("Plain")
        editor.insertTab(nil)
        XCTAssertEqual(editor.string, "Plain", "Tab never types a tab character")
        XCTAssertTrue(window.firstResponder === next.currentEditor() || window.firstResponder === next)

        let list = composer("- one\n- two")
        list.0.insertTab(nil)
        XCTAssertEqual(list.0.string, "- one\n  - two")
        XCTAssertTrue(list.2.firstResponder === list.0, "Nesting keeps focus in the composer")
        list.0.insertBacktab(nil)
        XCTAssertEqual(list.0.string, "- one\n- two")
        // The first item has nothing to nest under; Tab stays in the list.
        let first = composer("- only")
        first.0.insertTab(nil)
        XCTAssertEqual(first.0.string, "- only")
        XCTAssertTrue(first.2.firstResponder === first.0)
    }

    func testShiftReturnContinuesAListAndIsUndoable() {
        let (editor, _, _) = composer("1. first")
        var sent = 0
        editor.onSend = { sent += 1 }
        key(editor, 36, "\r", .shift)
        XCTAssertEqual(editor.string, "1. first\n2. ")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 12, length: 0))
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "1. first")
        key(editor, 36, "\r", .shift)
        key(editor, 36, "\r", .shift)
        XCTAssertEqual(editor.string, "1. first\n", "An empty item ends the list")
        key(editor, 36, "\r")
        XCTAssertEqual(sent, 1, "Return still sends inside a list")
    }
}

private final class ReportingKeyWindow: NSWindow {
    // A background test process cannot own the real key window.
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

@MainActor final class WorkspaceTabOrderTests: XCTestCase {
    private func tab(_ window: NSWindow) async throws {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                     characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
        window.sendEvent(event)
        try await Task.sleep(for: .milliseconds(120))
    }
    private func name(_ responder: NSResponder?) -> String { responder.map { String(describing: type(of: $0)) } ?? "nil" }

    /// Hidden panes stay mounted, and AppKit's key-view loop visited them: Tab from the composer
    /// landed on the closed find bar, the Files tree behind Changes and the offscreen review card.
    func testTabFromTheComposerVisitsOnlyWhatIsOnScreen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("octo-tab-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let git = try XCTUnwrap(Executables.find("git"))
        _ = try await ProcessRunner.run(git, arguments: ["init", "--quiet"], directory: root)
        for file in ["a.txt", "b.txt"] { try "text\n".write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8) }
        let store = AppStore(storage: WorkspaceStore(fileURL: root.appendingPathComponent("workspace.json")))
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let thread = WorkspaceThread(title: "Tab", harness: .claude, workingDirectory: root.path)
        let project = WorkspaceProject(name: "Fixture", rootPath: root.path, threads: [thread])
        store.archive = WorkspaceArchive(projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id)
        store.showingReview = true
        let host = NSHostingView(rootView: WorkspaceView(store: store))
        let window = ReportingKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        for _ in 0..<150 where !views(host).contains(where: { name($0) == "ReviewTextView" }) { try await Task.sleep(for: .milliseconds(30)) }
        let composer = try XCTUnwrap(views(host).first { $0 is ScreenshotTextView })
        window.makeFirstResponder(composer)

        var stops: [String] = []
        for _ in 0..<8 {
            try await tab(window)
            stops.append(name(window.firstResponder))
            if window.firstResponder === composer { break }
        }
        let afterControls = Array(stops.drop { $0 == "ComposerControlKeys" })
        XCTAssertGreaterThanOrEqual(stops.count - afterControls.count, 2, "The composer's controls come first: \(stops)")
        // Nothing is staged in the fixture, so the commit message editor is collapsed and not a stop.
        XCTAssertEqual(afterControls, ["SwiftUIOutlineListView", "ReviewTextView", "ScreenshotTextView"], "Then changed files, diff, and back")
        for stop in stops.dropLast() {
            XCTAssertNotEqual(stop, "NSTextView", "The closed find bar's field editor must not take focus")
        }

        store.showingReview = false
        try await Task.sleep(for: .milliseconds(200))
        window.makeFirstResponder(composer)
        for _ in 0..<6 {
            try await tab(window)
            if window.firstResponder === composer { break }
            XCTAssertEqual(name(window.firstResponder), "ComposerControlKeys", "Only the composer's controls are visible stops")
        }
        XCTAssertTrue(window.firstResponder === composer, "With the review card offscreen, Tab cycles the controls and returns: \(name(window.firstResponder))")
    }

    func testFocusRingShowsOnlyForKeyboardFocusInsideThePane() {
        let window = ReportingKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let pane = FocusWithinView(frame: NSRect(x: 0, y: 150, width: 400, height: 150))
        let inside = NSTextField(frame: NSRect(x: 20, y: 200, width: 200, height: 24))
        let outside = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        [pane, inside, outside].forEach { window.contentView?.addSubview($0) }
        var states: [Bool] = []
        pane.changed = { states.append($0) }
        let original = FocusWithinView.focusFromKeyboard
        defer { FocusWithinView.focusFromKeyboard = original }

        FocusWithinView.focusFromKeyboard = { false }
        window.makeFirstResponder(inside)
        XCTAssertEqual(states, [], "Clicking into the pane shows no ring")
        window.makeFirstResponder(outside)

        FocusWithinView.focusFromKeyboard = { true }
        window.makeFirstResponder(inside)
        XCTAssertEqual(states, [true], "Tabbing into the pane rings it, field editor and all")
        window.makeFirstResponder(outside)
        XCTAssertEqual(states, [true, false])
    }
}

@MainActor final class ComposerControlFocusTests: XCTestCase {
    private func key(_ window: NSWindow, _ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) async throws {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                     characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        window.sendEvent(event)
        try await Task.sleep(for: .milliseconds(80))
    }
    private func focused(_ window: NSWindow) -> ComposerStop? { (window.firstResponder as? ComposerControlKeys)?.controls?.focused }

    /// With Keyboard navigation off, SwiftUI controls are not Tab stops; Tab from the composer
    /// must still land somewhere visible.
    func testTabRingsTheComposerControlsInOrderAndEscapeOrTypingReturns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(storage: WorkspaceStore(fileURL: root.appendingPathComponent("workspace.json")))
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let thread = WorkspaceThread(title: "Tab", harness: .claude, workingDirectory: root.path)
        let project = WorkspaceProject(name: "Fixture", rootPath: root.path, threads: [thread])
        store.archive = WorkspaceArchive(projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id)
        let host = NSHostingView(rootView: ChatPane(store: store))
        let window = ReportingKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(500))
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let composer = try XCTUnwrap(views(host).first { $0 is ScreenshotTextView } as? ScreenshotTextView)
        window.makeFirstResponder(composer)

        try await key(window, 48, "\t")
        let first = try XCTUnwrap(focused(window), "Tab rings a composer control")
        XCTAssertTrue([.attach, .agent].contains(first))
        var visited = [first]
        for _ in 0..<4 { try await key(window, 48, "\t"); if let stop = focused(window) { visited.append(stop) } else { break } }
        XCTAssertEqual(visited, visited.sorted(), "Stops run left to right: \(visited)")
        XCTAssertTrue(visited.contains(.permissions))
        XCTAssertFalse(visited.contains(.send), "Send is skipped while the draft is empty")
        XCTAssertTrue(window.firstResponder === composer, "Tab past the last control has nowhere else visible and returns")

        try await key(window, 48, "\u{19}", .shift)
        XCTAssertEqual(focused(window), visited.last, "Shift-Tab from the composer rings the last control")
        try await key(window, 53, "\u{1b}")
        XCTAssertTrue(window.firstResponder === composer)
        XCTAssertNil(focused(window))

        try await key(window, 48, "\t")
        try await key(window, 0, "a")
        XCTAssertTrue(window.firstResponder === composer, "Typing goes back to the composer")
        XCTAssertEqual(composer.string, "a")
    }

    func testSpacePressesTheRingedControl() async throws {
        final class Taps: ObservableObject { var count = 0 }
        let taps = Taps(), controls = ComposerControls()
        struct Row: View {
            let taps: Taps
            var body: some View {
                Button("Press") { taps.count += 1 }.buttonStyle(HoverButtonStyle()).composerStop(.attach)
                    .frame(width: 200, height: 60)
            }
        }
        let editor = ScreenshotTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        let host = NSHostingView(rootView: Row(taps: taps).environment(\.composerControls, controls))
        host.frame = NSRect(x: 0, y: 60, width: 300, height: 80)
        let window = ReportingKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView?.addSubview(editor); window.contentView?.addSubview(host); window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(controls.enter(from: editor, forward: true))
        XCTAssertEqual(controls.focused, .attach)
        try await key(window, 49, " ")
        // The test process has no running event loop to deliver the queued mouse-up; deliver it.
        if let up = NSApp.nextEvent(matching: .leftMouseUp, until: Date().addingTimeInterval(0.5), inMode: .default, dequeue: true) { window.sendEvent(up) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(taps.count, 1)
        XCTAssertNil(controls.focused)
    }
}
