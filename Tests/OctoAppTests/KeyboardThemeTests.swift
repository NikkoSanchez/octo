import XCTest
import AppKit
import SwiftUI
import OctoCore
@testable import OctoApp

@MainActor final class KeyboardThemeTests: XCTestCase {
    func testComposerReturnSendsShiftReturnAddsLineAndMarkedTextDoesNotSend() throws {
        let editor = ScreenshotTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        editor.isRichText = false
        var sends = 0
        editor.onSend = { sends += 1 }
        func event(_ flags: NSEvent.ModifierFlags = [], code: UInt16 = 36, repeated: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: repeated, keyCode: code))
        }
        editor.string = "Draft"
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        editor.keyDown(with: try event())
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(editor.string, "Draft")
        editor.keyDown(with: try event(.shift))
        XCTAssertEqual(editor.string, "Draft\n")
        XCTAssertEqual(sends, 1)
        editor.keyDown(with: try event(.capsLock, code: 76))
        editor.keyDown(with: try event(.command))
        XCTAssertEqual(sends, 3)
        editor.keyDown(with: try event(repeated: true))
        XCTAssertEqual(sends, 3)
        editor.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        editor.keyDown(with: try event())
        XCTAssertEqual(sends, 3, "Return must remain with the input method during composition")
    }

    func testAcceptedComposerInputClearsSynchronouslyAndRejectedInputStaysEditable() throws {
        var draft = "first", accept = true
        let parent = ComposerTextView(focusRequest: 0, theme: .system,
            text: Binding(get: { draft }, set: { draft = $0 }), onPasteImage: { _ in false },
            onSend: { if accept { draft = "" } })
        let coordinator = parent.makeCoordinator()
        let editor = ScreenshotTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 110))
        editor.isRichText = false; editor.string = draft; editor.delegate = coordinator
        editor.onSend = { coordinator.submit(editor) }
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        editor.keyDown(with: enter)
        XCTAssertEqual(editor.string, "")
        editor.insertText("second", replacementRange: editor.selectedRange())
        XCTAssertEqual(draft, "second", "Typing immediately must not append to previously sent text")
        accept = false; editor.keyDown(with: enter)
        XCTAssertEqual(editor.string, "second")
        XCTAssertEqual(draft, "second")
    }

    func testProjectPickerShortcutIsDistinctFromChatSearchAndWorksInTerminal() throws {
        let projects = AppCommand(id: "projects", title: "Switch Project", group: "Navigate", key: "k", modifiers: [.command, .shift]) {}
        let chats = AppCommand(id: "chats", title: "Search Chats", group: "Navigate", key: "k") {}
        func event(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: "K", charactersIgnoringModifiers: "K", isARepeat: false, keyCode: 40))
        }
        XCTAssertTrue(projects.matches(try event([.command, .shift])))
        XCTAssertFalse(chats.matches(try event([.command, .shift])))
        for flags: NSEvent.ModifierFlags in [.command, .control, .option, [.command, .option, .shift]] {
            XCTAssertFalse(projects.matches(try event(flags)))
        }
        XCTAssertTrue(projects.isAvailable(inTerminal: true))
    }

    func testShortcutHintsWaitForHoldAndCancelOnReleaseOrShortcut() {
        var pending: [DispatchWorkItem] = []
        var delays: [TimeInterval] = []
        var visible = false
        let hold = ShortcutHintHold { delay, work in delays.append(delay); pending.append(work) }
        hold.changed = { visible = $0 }

        hold.update(commandDown: true, keyDown: false)
        XCTAssertFalse(visible)
        XCTAssertEqual(delays, [0.65])
        hold.update(commandDown: false, keyDown: false)
        pending.removeFirst().perform()
        XCTAssertFalse(visible, "A tap must not reveal hints later")

        hold.update(commandDown: true, keyDown: false)
        hold.update(commandDown: true, keyDown: false)
        XCTAssertEqual(pending.count, 1, "Other modifier changes must not restart the delay")
        pending.removeFirst().perform()
        XCTAssertTrue(visible)
        hold.update(commandDown: true, keyDown: true)
        XCTAssertFalse(visible)
        hold.update(commandDown: true, keyDown: false)
        XCTAssertTrue(pending.isEmpty, "A used shortcut suppresses hints until Command is released")

        hold.update(commandDown: false, keyDown: false)
        hold.update(commandDown: true, keyDown: false)
        hold.update(commandDown: true, keyDown: true)
        pending.removeFirst().perform()
        XCTAssertFalse(visible)
    }

    func testShortcutHintsRecheckContextAndDiscardSupersededHolds() {
        var pending: [DispatchWorkItem] = []
        var visible = false
        var allowed = true
        let hold = ShortcutHintHold { _, work in pending.append(work) }
        hold.changed = { visible = $0 }
        hold.canReveal = { allowed }
        hold.update(commandDown: true, keyDown: false)
        hold.reset() // Focus loss, sheet presentation, or view teardown.
        hold.update(commandDown: true, keyDown: false)
        pending.removeFirst().perform()
        XCTAssertFalse(visible, "An old callback must not reveal a new hold early")
        allowed = false
        pending.removeFirst().perform()
        XCTAssertFalse(visible, "Context must still permit hints when the delay expires")
        hold.reset()
        allowed = true
        hold.update(commandDown: true, keyDown: false)
        pending.removeFirst().perform()
        XCTAssertTrue(visible)
        hold.reset()
        XCTAssertFalse(visible)
    }

    func testThemePersistenceAndUnknownPreferenceFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "OctoThemeTests-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let storage = WorkspaceStore(fileURL: directory.appendingPathComponent("workspace.json"))
        let store = AppStore(storage: storage, preferences: preferences)
        XCTAssertEqual(store.theme, .system)
        store.theme = .latte
        XCTAssertEqual(AppStore(storage: storage, preferences: preferences).theme, .latte)
        store.theme = .mocha
        XCTAssertEqual(AppStore(storage: storage, preferences: preferences).theme, .mocha)
        store.theme = .dracula
        XCTAssertEqual(AppStore(storage: storage, preferences: preferences).theme, .dracula)
        store.theme = .tokyoNightDay
        XCTAssertEqual(preferences.string(forKey: "appearanceTheme"), "tokyoNightDay")
        XCTAssertEqual(AppStore(storage: storage, preferences: preferences).theme, .tokyoNightDay)
        // Persisted identifiers from earlier releases must keep resolving.
        XCTAssertEqual(["latte", "mocha", "dracula"].compactMap(AppTheme.init(rawValue:)), [.latte, .mocha, .dracula])
        store.theme = .system
        XCTAssertEqual(AppStore(storage: storage, preferences: preferences).theme, .system)
        preferences.set("future-theme", forKey: "appearanceTheme")
        XCTAssertEqual(AppStore(storage: storage, preferences: preferences).theme, .system)
        store.shutdown()
    }

    func testAppKeysDoNotMatchShellControlOrOptionKeys() throws {
        let command = AppCommand(id: "chats", title: "Search Chats", group: "Navigate", key: "k") {}
        func event(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
        }
        XCTAssertTrue(command.matches(try event(.command)))
        XCTAssertTrue(command.matches(try event([.command, .capsLock])))
        for flags: NSEvent.ModifierFlags in [[], .control, .option, [.command, .control], [.command, .option], [.command, .shift]] {
            XCTAssertFalse(command.matches(try event(flags)))
        }
        let nextTab = AppCommand(id: "nextTab", title: "Next Tab", group: "Terminal", key: "]", modifiers: [.command, .shift]) {}
        let shiftedBracket = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil, characters: "}", charactersIgnoringModifiers: "}", isARepeat: false, keyCode: 30))
        XCTAssertTrue(nextTab.matches(shiftedBracket))
    }

    func testSendAndCloseStayWithinTheirWorkspaceContext() {
        let send = AppCommand(id: "send", title: "Send", group: "Conversation", key: "\r", terminalAllowed: false) {}
        let close = AppCommand(id: "close", title: "Close tab", group: "Terminal", key: "w", terminalRequired: true) {}
        let chats = AppCommand(id: "chats", title: "Chats", group: "Navigate", key: "k") {}
        XCTAssertFalse(send.isAvailable(inTerminal: true))
        XCTAssertTrue(send.isAvailable(inTerminal: false))
        XCTAssertFalse(close.isAvailable(inTerminal: false))
        XCTAssertTrue(close.isAvailable(inTerminal: true))
        XCTAssertTrue(chats.isAvailable(inTerminal: true))
        XCTAssertTrue(chats.isAvailable(inTerminal: false))
    }

    func testSharedKeysRouteToTheVisibleSurface() throws {
        let commands = [
            AppCommand(id: "closeTerminal", title: "Close Terminal Tab", group: "Terminal", key: "w", terminalRequired: true) {},
            AppCommand(id: "closePanelTab", title: "Close Panel Tab", group: "Panels", key: "w", terminalAllowed: false) {}
        ]
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        XCTAssertEqual(KeyRoutingView.command(for: event, in: commands, terminalVisible: true)?.id, "closeTerminal")
        XCTAssertEqual(KeyRoutingView.command(for: event, in: commands, terminalVisible: false)?.id, "closePanelTab")
        XCTAssertNil(KeyRoutingView.command(for: event, in: [commands[0]], terminalVisible: false), "Unclaimed keys keep their native behavior")
    }

    func testComposerStartsShortGrowsWithTextAndScrollsPastItsCap() async throws {
        let drafts = DraftStore(), id = UUID()
        let editor = DraftEditor(drafts: drafts, threadID: id, focusRequest: 0, theme: .system, commands: [], providerTitle: "Claude",
                                 commandsLoading: false, commandError: nil, refreshCommands: {}, placeholder: "Ask anything…",
                                 onChange: { drafts.values[id] = $0 }, onPasteImage: { _ in false }, onSend: {})
        let host = NSHostingView(rootView: editor.frame(width: 400).fixedSize(horizontal: false, vertical: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func scroll() throws -> NSScrollView { try XCTUnwrap(views(host).first { $0 is ScreenshotTextView }?.enclosingScrollView) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try scroll().frame.height, ComposerTextView.minHeight, accuracy: 1, "An empty composer is two lines tall")

        drafts.values[id] = "one\ntwo\nthree\nfour\nfive"
        try await Task.sleep(for: .milliseconds(300))
        let fiveLines = try scroll().frame.height
        XCTAssertGreaterThan(fiveLines, ComposerTextView.minHeight + 20)
        XCTAssertLessThan(fiveLines, ComposerTextView.maxHeight)
        XCTAssertEqual(try scroll().documentView?.frame.height ?? 0, fiveLines, accuracy: 1, "Below the cap all text is shown without scrolling")

        drafts.values[id] = (1...40).map { "Line \($0)" }.joined(separator: "\n")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try scroll().frame.height, ComposerTextView.maxHeight, accuracy: 1)
        XCTAssertGreaterThan(try scroll().documentView?.frame.height ?? 0, ComposerTextView.maxHeight + 100, "Past the cap the text scrolls")

        drafts.values[id] = ""
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try scroll().frame.height, ComposerTextView.minHeight, accuracy: 1, "Sending or clearing shrinks it again")
    }

    func testWorkspaceComposerShrinksWhenALongDraftIsCleared() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(storage: WorkspaceStore(fileURL: root.appendingPathComponent("workspace.json")), executables: fixtureExecutables)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(store.thread?.id)
        let host = NSHostingView(rootView: WorkspaceView(store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func scroll() throws -> NSScrollView { try XCTUnwrap(views(host).first { $0 is ScreenshotTextView }?.enclosingScrollView) }
        try await Task.sleep(for: .milliseconds(500))
        store.drafts[id] = (1...30).map { "Line \($0)" }.joined(separator: "\n")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(try scroll().frame.height, ComposerTextView.maxHeight, accuracy: 1)
        store.drafts[id] = ""
        try await Task.sleep(for: .milliseconds(400))
        // AppKit keeps a text view as tall as its visible area, so measuring the view never shrank it.
        XCTAssertEqual(try scroll().frame.height, ComposerTextView.minHeight, accuracy: 1)
    }
}
