import AppKit
import SwiftUI
import XCTest
import OctoCore
@testable import OctoApp

/// SwiftUI's glassEffect beside a Core Animation indicator re-laid out the host ~10,000 times a
/// second (measured on macOS 26.6). Octo's glass must stay idle around working indicators.
@MainActor final class GlassLayoutTests: XCTestCase {
    private final class CountingHost<Content: View>: NSHostingView<Content> {
        var layouts = 0
        override func layout() { layouts += 1; super.layout() }
    }
    func testGlassPanelsAndControlsStayIdleAroundWorkingIndicators() async throws {
        let card = VStack(spacing: 12) {
            ThreadAvatar(harness: .claude, running: true)
            TypingIndicator(color: .gray)
            WorkingIndicator()
            Button("Settings") {}.buttonStyle(.plain).padding(8).glassControl()
        }.padding(30).glassPanel()
        let host = CountingHost(rootView: card.padding(20).environment(\.scenePhase, .active))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(400)); host.layouts = 0
        try await Task.sleep(for: .seconds(1))
        XCTAssertLessThanOrEqual(host.layouts, 2, "Glass must not drive layout while indicators animate")
    }
}
