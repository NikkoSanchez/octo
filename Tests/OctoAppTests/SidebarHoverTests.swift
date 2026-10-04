import XCTest
import AppKit
@testable import OctoApp

@MainActor final class SidebarHoverTests: XCTestCase {
    func testTrackingAreaRemainsStableThroughRepeatedLayouts() {
        let view = ThreadHoverAnchorView(frame: NSRect(x: 0, y: 0, width: 240, height: 36))
        view.updateTrackingAreas()
        let original = view.trackingAreas.first!
        var callbacks = 0
        view.onHover = { _ in callbacks += 1 }
        for index in 0..<1_000 {
            view.frame.size.width = CGFloat(200 + index % 100)
            view.updateTrackingAreas()
            view.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(view.trackingAreas.count, 1)
        XCTAssertTrue(view.trackingAreas.first === original, "Layout must not synthesize tracking exit/enter by replacing the area")
        XCTAssertEqual(callbacks, 0)
        view.dismiss()
    }

    func testHoverPublicationIsDeferredCoalescedAndCancelledOnDismissal() async throws {
        let view = ThreadHoverAnchorView()
        var values: [Bool] = []
        view.onHover = { values.append($0) }
        view.setHovered(true)
        XCTAssertTrue(values.isEmpty, "Native tracking must not synchronously mutate SwiftUI state")
        view.dismiss()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(values, [false], "An obsolete enter must not restart an animation after exit")
        view.setHovered(true); view.setHovered(true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(values, [false, true])
        view.dismiss()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(view.panel)
        XCTAssertEqual(values, [false, true, false])
    }

    func testMarqueeUsesOneLayerAnimationAndStopsForExitResizeAndDetach() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 150, height: 30), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = MarqueeTitleView(frame: NSRect(x: 0, y: 0, width: 150, height: 18))
        window.contentView = view
        let title = "Review the complete sidebar navigation and conversation title behavior"
        view.update(title: title, emphasized: false, color: .labelColor, animate: true)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.isAnimating)
        for _ in 0..<1_000 {
            view.update(title: title, emphasized: false, color: .labelColor, animate: true)
            view.layoutSubtreeIfNeeded()
        }
        XCTAssertTrue(view.isAnimating)
        for height: CGFloat in [36, 18, 24, 18] {
            view.frame.size.height = height
            view.layoutSubtreeIfNeeded()
            let textFrame = try! XCTUnwrap(view.layer?.sublayers?.first?.frame)
            XCTAssertGreaterThanOrEqual(textFrame.minY, 0)
            XCTAssertLessThanOrEqual(textFrame.maxY, height, "Height-only layout changes must keep the title inside its viewport")
        }
        view.update(title: title, emphasized: false, color: .labelColor, animate: false)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.isAnimating)
        view.update(title: "Short", emphasized: false, color: .labelColor, animate: true)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.isAnimating)
        view.update(title: title, emphasized: false, color: .labelColor, animate: true)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.isAnimating)
        view.removeFromSuperview()
        XCTAssertFalse(view.isAnimating)
        window.close()
    }

    func testNativeCardHasBoundedWidthAndStableSizeForSameContent() {
        let content = ThreadHoverContent(title: "Review the complete sidebar navigation and conversation title behavior",
                                        projectName: "Project", activityDate: Date(timeIntervalSince1970: 0), theme: .latte)
        let card = ThreadHoverCardView(content: content, now: Date(timeIntervalSince1970: 180))
        let size = card.frame.size
        XCTAssertEqual(size.width, 320)
        XCTAssertGreaterThan(size.height, 68, "Long titles should wrap")
        for _ in 0..<1_000 { card.update(content, now: Date(timeIntervalSince1970: 180)) }
        XCTAssertEqual(card.frame.size, size)
        XCTAssertNotNil(NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: nil))
    }
}
