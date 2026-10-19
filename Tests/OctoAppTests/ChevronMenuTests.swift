import XCTest
import AppKit
import SwiftUI
@testable import OctoApp

@MainActor final class ChevronMenuTests: XCTestCase {
    /// Clicks a hosted menu centred in a 120×60 window and reports whether it opened.
    private func menuOpens<Menu: View>(_ menu: Menu = ChevronMenu { Button("Item") {} }, clickingAt point: NSPoint) async throws -> Bool {
        let host = NSHostingView(rootView: menu.frame(width: 120, height: 60))
        let window = KeyWindow(contentRect: NSRect(x: 200, y: 200, width: 120, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        var opened = false
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            opened = true
            DispatchQueue.main.async { (note.object as? NSMenu)?.cancelTrackingWithoutAnimation() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
        try await Task.sleep(for: .milliseconds(200))
        return opened
    }

    func testTheWholeHighlightedBoxOpensTheMenu() async throws {
        // The box spans x 45...75, y 15...45; the arrow glyph covers only its centre.
        let center = try await menuOpens(clickingAt: NSPoint(x: 60, y: 30))
        XCTAssertTrue(center)
        let corner = try await menuOpens(clickingAt: NSPoint(x: 48, y: 18))
        XCTAssertTrue(corner, "A borderless-button menu ignored clicks away from its icon")
        let outside = try await menuOpens(clickingAt: NSPoint(x: 30, y: 30))
        XCTAssertFalse(outside)
    }

    func testHoverMenuStyleOpensFromItsPadding() async throws {
        // A 12 pt glyph padded 8×6 by HoverButtonStyle: about 28×24 pt around (60, 30).
        let menu = SwiftUI.Menu { Button("Item") {} } label: { Image(systemName: "plus").frame(width: 12, height: 12) }.hoverMenuStyle().fixedSize()
        let padding = try await menuOpens(menu, clickingAt: NSPoint(x: 49, y: 21))
        XCTAssertTrue(padding, "A click in the padding outside the glyph opens the menu")
        let outside = try await menuOpens(menu, clickingAt: NSPoint(x: 40, y: 30))
        XCTAssertFalse(outside)
    }
}

private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}
