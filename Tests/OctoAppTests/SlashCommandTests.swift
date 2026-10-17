import XCTest
import AppKit
import OctoAgents
@testable import OctoApp

@MainActor final class SlashCommandTests: XCTestCase {
    func testLoginRefreshKeepsDraftsAndOtherProviderCatalogs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(fileURL: root.appendingPathComponent("workspace.json")))
        defer { store.shutdown() }
        let thread = try XCTUnwrap(store.thread)
        store.drafts[thread.id] = "/review explain"
        store.commandCatalogs = ["claude:/tmp": [.init(name: "review")], "codex:/tmp": [.init(name: "code")]]
        store.commandErrors = ["claude:/tmp": "Old error", "codex:/tmp": "Codex error"]
        store.loadingCommands = ["claude:/tmp", "codex:/tmp"]
        let oldConfiguration = store.claudeConfigurationID
        store.claudeSetupClosed()
        XCTAssertNotEqual(oldConfiguration, store.claudeConfigurationID)
        XCTAssertNil(store.commandCatalogs["claude:/tmp"])
        XCTAssertEqual(store.commandCatalogs["codex:/tmp"]?.map(\.name), ["code"])
        XCTAssertEqual(store.commandErrors, ["codex:/tmp": "Codex error"])
        XCTAssertEqual(store.loadingCommands, ["codex:/tmp"])
        XCTAssertEqual(store.drafts[thread.id], "/review explain")
        XCTAssertEqual(store.thread?.agentSettings, thread.agentSettings)
    }
    func testFilterOnlyLeadingCommandTokenAndInsertionStaysInDraft() {
        let commands: [AgentCommand] = [.init(name: "review"), .init(name: "plugin:review")]
        XCTAssertEqual(SlashCommandQuery.matches(commands, text: "/").count, 2)
        XCTAssertEqual(SlashCommandQuery.matches(commands, text: "/ReV").map(\.name), ["review"])
        for text in ["hello /", "/review argument", "/review\n", " /review", ""] {
            XCTAssertNil(SlashCommandQuery.prefix(in: text))
        }
        XCTAssertEqual(SlashCommandQuery.insertion(commands[0]), "/review ")
    }
    func testNativeCommandSelectionConsumesReturnBeforeSendAndPreservesShiftReturn() throws {
        let editor = ScreenshotTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 110))
        editor.isRichText = false; editor.string = "/"
        var sends = 0, inserts = 0
        editor.onSend = { sends += 1 }
        editor.onCommandKey = { code in
            guard code == 36 || code == 48 else { return false }
            inserts += 1; editor.string = "/review "; return true
        }
        func event(_ key: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: key == 48 ? "\t" : "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: key))
        }
        editor.keyDown(with: try event(36)); editor.keyDown(with: try event(48))
        XCTAssertEqual(inserts, 2); XCTAssertEqual(sends, 0)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.keyDown(with: try event(36, flags: .shift))
        XCTAssertTrue(editor.string.hasSuffix("\n")); XCTAssertEqual(inserts, 2)
        editor.onCommandKey = { _ in false }
        editor.keyDown(with: try event(36)); XCTAssertEqual(sends, 1)
    }
}
