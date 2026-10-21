import AppKit
import SwiftUI
import XCTest
import GhosttyKit
import OctoCore
@testable import OctoGhostty
@testable import OctoTerminal

/// Drives real Ghostty surfaces and the user's shell in a window, so it only runs on request:
/// `OCTO_LIVE_TERMINAL_TESTS=1 swift test --filter LiveSplitSmokeTests`.
@MainActor final class LiveSplitSmokeTests: XCTestCase {
    private func spin(_ seconds: Double, until condition: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !condition() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testRealGhosttySplitsRoundTrip() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OCTO_LIVE_TERMINAL_TESTS"] == "1", "Set OCTO_LIVE_TERMINAL_TESTS=1 to run")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let workspace = TerminalWorkspace()
        let projectID = UUID()
        let tab = workspace.newTab(projectID: projectID, directory: "/tmp")
        let host = NSHostingView(rootView: TerminalSurfaces(workspace: workspace, projectID: projectID, visible: true) { _ in Color.red })
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 801, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { workspace.shutdown(); window.orderOut(nil) }
        let first = tab.state
        spin(5) { first.surface != nil }
        XCTAssertNotNil(first.surface, "notice: \(first.notice ?? "none")")
        let firstView = try XCTUnwrap(first.view)
        // cd so the split can inherit a different directory. A shell still starting up may
        // discard typeahead, so retype until it answers.
        let command = "cd /usr && echo OCTO_$((40+2))\n"
        for _ in 0..<8 where !first.visibleText().contains("OCTO_42") {
            command.withCString { ghostty_surface_text(first.surface, $0, UInt(command.utf8.count)) }
            spin(2.5) { first.visibleText().contains("OCTO_42") }
        }
        XCTAssertTrue(first.visibleText().contains("OCTO_42"), "The shell never ran the command")
        spin(0.5)

        // Ghostty's binding path: the same one ⌘D takes.
        XCTAssertTrue(first.perform("new_split:right"))
        spin(3) { tab.panes.count == 2 && tab.panes[1].surface != nil }
        XCTAssertEqual(tab.panes.count, 2)
        let second = tab.panes[1]
        XCTAssertEqual(second.options.directory, "/usr", "The split starts in the shell's current directory")
        XCTAssertNotNil(second.surface)
        XCTAssertTrue(first.view === firstView)
        XCTAssertEqual(firstView.frame.width, 400, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(second.view).frame.width, 400, accuracy: 1)
        XCTAssertEqual(tab.focusedPane, second.id)

        XCTAssertTrue(second.perform("goto_split:left"))
        spin(1) { tab.focusedPane == first.id }
        XCTAssertEqual(tab.focusedPane, first.id)
        XCTAssertTrue(first.perform("resize_split:right,80"))
        spin(1) { firstView.frame.width > 450 }
        XCTAssertEqual(firstView.frame.width, 480, accuracy: 2)
        XCTAssertTrue(first.perform("equalize_splits"))
        spin(1) { abs(firstView.frame.width - 400) < 1 }
        XCTAssertEqual(firstView.frame.width, 400, accuracy: 1)
        XCTAssertTrue(first.perform("toggle_split_zoom"))
        spin(1) { firstView.frame.width > 790 }
        XCTAssertEqual(tab.layout.zoomed, first.id)
        XCTAssertEqual(firstView.frame.width, 801, accuracy: 1)
        XCTAssertFalse(second.isSurfaceVisible, "The hidden pane stays mounted but invisible")
        XCTAssertNotNil(second.surface)
        XCTAssertTrue(first.perform("toggle_split_zoom"))
        spin(1) { tab.layout.zoomed == nil && second.isSurfaceVisible }
        XCTAssertTrue(second.isSurfaceVisible)

        // The shell exiting closes its pane, as in Ghostty.
        let exit = "exit\n"
        exit.withCString { ghostty_surface_text(second.surface, $0, UInt(exit.utf8.count)) }
        spin(5) { tab.panes.count == 1 }
        XCTAssertEqual(tab.panes.count, 1)
        XCTAssertTrue(second.isClosed)
        XCTAssertFalse(tab.exited)
        spin(0.5)
        XCTAssertTrue(first.view === firstView)
        XCTAssertEqual(firstView.frame.width, 801, accuracy: 1)
        XCTAssertNotNil(first.surface)

        // The keyboard path: the calls GhosttyNativeView makes for ⇧⌘D. A test process cannot
        // take key focus, so the view's own focus guard is not exercised here.
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "D", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2))
        var key = GhosttyInput.key(event, action: GHOSTTY_ACTION_PRESS)
        var flags = ghostty_binding_flags_e(0)
        let text = event.characters ?? ""
        XCTAssertTrue(text.withCString { key.text = $0; return ghostty_surface_key_is_binding(first.surface, key, &flags) }, "⇧⌘D is a Ghostty binding")
        XCTAssertTrue(text.withCString { key.text = $0; return ghostty_surface_key(first.surface, key) })
        spin(3) { tab.panes.count == 2 }
        guard case let .split(axis, _, _, _) = tab.layout.root else { return XCTFail("⇧⌘D did not split") }
        XCTAssertEqual(axis, .vertical)
    }
}
