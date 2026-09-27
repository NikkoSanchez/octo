import XCTest
import AppKit
import OctoCore
@testable import OctoApp

@MainActor final class KeyboardThemeTests: XCTestCase {
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
