import XCTest
import AppKit
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
}
