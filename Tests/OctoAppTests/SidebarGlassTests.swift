import AppKit
import SwiftUI
import XCTest
import OctoCore
@testable import OctoApp

@MainActor final class SidebarGlassTests: XCTestCase {
    func testTimestampsFollowMessages() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let locale = Locale(identifier: "en_US_POSIX")
        // Monday 19 October 2026, 15:00 UTC.
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 15)))
        func stamp(_ days: Int, hour: Int = 11, minute: Int = 19) throws -> String {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)))
            let date = try XCTUnwrap(calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day))
            return ThreadHoverDetails.timestamp(date, now: now, calendar: calendar, locale: locale)
        }
        XCTAssertEqual(try stamp(0), "11:19\u{202F}AM")
        XCTAssertEqual(try stamp(1, hour: 23), "Yesterday")
        XCTAssertEqual(try stamp(2), "Saturday")
        XCTAssertEqual(try stamp(6), "Tuesday")
        XCTAssertEqual(try stamp(9), "10/10/26")
    }

    func testPreviewsSkipWorkingThreadsAndReduceEachMessageOnce() {
        var settled = WorkspaceThread(title: "Settled", workingDirectory: "/tmp")
        settled.messages = [.init(role: .user, text: "Hi"), .init(role: .assistant, text: "**Done.**")]
        var working = WorkspaceThread(title: "Working", workingDirectory: "/tmp")
        working.messages = [.init(role: .user, text: "Go"), .init(role: .assistant, text: "Partial")]
        var cache = SidebarPreviewCache()
        XCTAssertEqual(cache.previews([settled, working], running: [working.id]), [settled.id: "Done."],
                       "Streamed text must never reach the sidebar; working rows show typing dots")
        // A streamed delta changes only the working thread, which is still skipped.
        working.messages[1].text += " more output"
        XCTAssertEqual(cache.previews([settled, working], running: [working.id]), [settled.id: "Done."])
        XCTAssertEqual(cache.previews([settled, working], running: []), [settled.id: "Done.", working.id: "Partial more output"])
        settled.messages[1].text = "Rewritten"
        XCTAssertEqual(cache.previews([settled], running: [])[settled.id], "Rewritten", "Changed text is reduced again")
    }

    func testChromePlacesTheTrafficLightsInsideTheSidebarCardAndKeepsTheTopStripInteractive() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: Color.clear.background(WindowChrome().frame(width: 0, height: 0)))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertNil(window.toolbar, "On macOS 26 a toolbar draws a full-width glass band over the content")
        // The sidebar card is inset 8 pt with a 16 pt radius; every light must clear its corner
        // and stay inside the titlebar, where it keeps all of its clicks.
        let titlebarHeight = host.bounds.height - window.contentLayoutRect.height
        func check() throws {
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                let button = try XCTUnwrap(window.standardWindowButton(kind))
                let frame = button.convert(button.bounds, to: nil)
                let top = host.bounds.height - frame.maxY
                XCTAssertGreaterThanOrEqual(frame.minX, 18, "\(kind) sits inside the card's leading edge")
                XCTAssertGreaterThanOrEqual(top, 16, "\(kind) sits below the card's top edge")
                XCTAssertLessThanOrEqual(top + frame.height, titlebarHeight, "\(kind) stays inside the titlebar")
                let titlebar = try XCTUnwrap(button.superview)
                XCTAssertTrue(titlebar.bounds.contains(button.frame), "\(kind) is not clipped by the titlebar")
                let theme = try XCTUnwrap(host.superview)
                let hit = theme.hitTest(theme.convert(NSPoint(x: frame.midX, y: frame.minY + 2), from: nil))
                XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true, "\(kind) takes clicks across its height")
            }
        }
        try check()
        // AppKit lays the titlebar out again on resize; the buttons must return to the card.
        window.setContentSize(NSSize(width: 820, height: 520))
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        try check()
        let height = host.bounds.height
        // SwiftUI restores an opaque titlebar when the colour scheme changes outside the hidden-titlebar style.
        window.titlebarAppearsTransparent = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(window.titlebarAppearsTransparent, "An opaque titlebar would cover the content beneath it")
        // Controls in the top strip (sidebar toggle, titlebar buttons) still receive clicks.
        let theme = try XCTUnwrap(host.superview)
        let hit = theme.hitTest(theme.convert(NSPoint(x: 600, y: height - 26), from: nil))
        XCTAssertTrue(hit?.isDescendant(of: host) == true, "The transparent titlebar must not swallow clicks: \(String(describing: hit))")
    }
}
