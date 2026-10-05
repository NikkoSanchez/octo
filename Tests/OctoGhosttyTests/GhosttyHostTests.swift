import AppKit
import Carbon
import GhosttyKit
import XCTest
@testable import OctoGhostty

final class GhosttyHostTests: XCTestCase {
    func testControlAndFunctionKeysAreNotSentAsPrintableText() {
        for text in ["\r", "\n", "\t", "\u{1b}", "\u{7f}", "\u{f700}", "a\0b", ""] { XCTAssertNil(GhosttyInput.keyText(text)) }
        for text in ["λ", "🐙", "你好", "e\u{301}"] { XCTAssertEqual(GhosttyInput.keyText(text), text) }
    }
    func testNativeModifiersPreserveSidesAndExcludeCommandControlFromConsumed() throws {
        let flags = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | NSEvent.ModifierFlags.control.rawValue | NSEvent.ModifierFlags.command.rawValue | UInt(NX_DEVICERSHIFTKEYMASK))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: "A", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        let key = GhosttyInput.key(event, action: GHOSTTY_ACTION_PRESS)
        XCTAssertNotEqual(key.mods.rawValue & GHOSTTY_MODS_SHIFT_RIGHT.rawValue, 0)
        XCTAssertNotEqual(key.mods.rawValue & GHOSTTY_MODS_SUPER.rawValue, 0)
        XCTAssertEqual(key.consumed_mods.rawValue & (GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_SUPER.rawValue), 0)
        XCTAssertEqual(key.keycode, 0)
        XCTAssertEqual(GhosttyInput.scrollModifiers(precise: true, momentum: .changed), 1 | Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue << 1))
    }
    func testColorsRejectConfigInjection() throws {
        var colors = GhosttyColors(background: "1e1e2e", foreground: "#cdd6f4", cursor: "f5e0dc", cursorText: "1e1e2e", selectionBackground: "45475a", selectionForeground: "cdd6f4", palette: ["abcdef"])
        XCTAssertTrue(try colors.rendered().contains("palette = 0=abcdef\n"))
        colors.background = "000000\ncommand = bad"
        XCTAssertThrowsError(try colors.rendered())
        XCTAssertFalse(GhosttyColors.isColor("ffffff\0"))
    }
    @MainActor func testClipboardRequestResolvesExactlyOnce() {
        var decisions: [Bool] = []
        let request = GhosttyClipboardRequest { decisions.append($0) }
        request.resolve(allow: false); request.resolve(allow: true)
        XCTAssertEqual(decisions, [false])
    }
    @MainActor func testCloseDeniesPendingClipboardRequestsBeforeDisposal() {
        let session = GhosttySession(options: .init(directory: "/tmp"))
        var decisions: [Bool] = []
        let request = GhosttyClipboardRequest { decisions.append($0) }
        session.clipboardRequests[request.id] = request
        session.close(); session.close()
        request.resolve(allow: true)
        XCTAssertEqual(decisions, [false])
        XCTAssertTrue(session.clipboardRequests.isEmpty)
        XCTAssertTrue(session.isClosed)
        XCTAssertNil(session.surface)
    }
    @MainActor func testLateCallbacksCannotReachClosedSession() async {
        let session = GhosttySession(options: .init(directory: "/tmp"))
        let context = GhosttySurfaceContext(session)
        var delivered = false
        context.enqueue { _ in delivered = true }
        context.isClosed = true
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertFalse(delivered)
    }
    @MainActor func testSessionOwnsSameViewAcrossVisibilityAndExitIsReportedOnce() {
        let session = GhosttySession(options: .init(directory: "/tmp"))
        let view = session.nativeView()
        var exits = 0
        session.onClose = { _ in exits += 1 }
        session.isSurfaceVisible = true; session.isSurfaceVisible = false
        XCTAssertTrue(view === session.nativeView())
        session.markExited(); session.requestClose(processAlive: false)
        XCTAssertEqual(exits, 1)
        XCTAssertTrue(session.processExited)
        session.close()
    }
    @MainActor func testFilePasteQuotesLiteralPathsOnPrivatePasteboard() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let url = URL(fileURLWithPath: "/tmp/a ' $(never-run); file")
        board.writeObjects([url as NSURL])
        XCTAssertEqual(GhosttyClipboard.pasteText(board), "'/tmp/a '\\'' $(never-run); file'")
    }
    func testClipboardCopyUsesStableCStringContractAndRejectsInvalidData() {
        let result = "text/plain".withCString { mime in
            "λ🐙".withCString { bytes in
                var item = ghostty_clipboard_content_s(mime: mime, data: bytes)
                return GhosttyClipboard.copy(&item, count: 1)
            }
        }
        XCTAssertEqual(result?.first?.bytes, Data("λ🐙".utf8))
        XCTAssertNil(GhosttyClipboard.copy(nil, count: 1))
        XCTAssertNil(GhosttyClipboard.copy(nil, count: 33))
        "four".withCString { XCTAssertNil(GhosttyClipboard.text($0, limit: 3)) }
        [CChar(-1), 0].withUnsafeBufferPointer { XCTAssertNil(GhosttyClipboard.text($0.baseAddress)) }
        [CChar(65), 0, 66, 0].withUnsafeBufferPointer { XCTAssertEqual(GhosttyClipboard.text($0.baseAddress), "A") }
    }
}
