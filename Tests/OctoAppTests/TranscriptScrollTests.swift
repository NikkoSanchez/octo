import AppKit
import XCTest
@testable import OctoApp

@MainActor final class TranscriptScrollTests: XCTestCase {
    private final class Document: NSView { override var isFlipped: Bool { true } }
    private func fixture() -> (TranscriptScrollController, NSScrollView, NSView, UUID) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let document = Document(frame: NSRect(x: 0, y: 0, width: 500, height: 2_000))
        scroll.documentView = document
        let controller = TranscriptScrollController(), thread = UUID()
        connect(controller, scroll, threadID: thread, suspended: false, searching: false)
        return (controller, scroll, document, thread)
    }
    private func connect(_ controller: TranscriptScrollController, _ scroll: NSScrollView, threadID: UUID, suspended: Bool, searching: Bool) {
        controller.connect(scroll, threadID: threadID, suspended: suspended, searching: searching) { [weak scroll] in
            guard let scroll, let document = scroll.documentView else { return }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.maxY - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    private enum WaitError: Error { case timedOut }

    // Task.sleep is a minimum delay, not a guarantee that the controller's
    // separately scheduled MainActor task has finished. Wait for its effect so
    // busy CI runners cannot begin a gesture before the initial scroll occurs.
    private func waitUntil(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail(message, file: file, line: line)
                throw WaitError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForBottom(_ scroll: NSScrollView, at height: CGFloat,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil("Expected visible bottom at \(height); deferred scrolling did not finish",
                            file: file, line: line) {
            abs(scroll.documentVisibleRect.maxY - height) <= 1
        }
    }

    // Negative assertions deliberately observe a quiet interval: polling an
    // already-true position would pass before an unwanted scroll could run.
    private func observeQuietInterval() async throws { try await Task.sleep(for: .milliseconds(150)) }
    private func scroll(_ scroll: NSScrollView, to y: CGFloat) {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
    }
    func testUserScrollCancelsPendingFollowAndGrowthPreservesReadingPosition() async throws {
        let (controller, view, document, _) = fixture()
        defer { controller.disconnect() }
        try await waitForBottom(view, at: 2_000)
        XCTAssertEqual(view.documentVisibleRect.maxY, 2_000, accuracy: 1)
        document.setFrameSize(NSSize(width: 500, height: 2_100))
        scroll(view, to: 500) // Also covers legacy mice with no start/end pair.
        XCTAssertFalse(controller.isFollowing)
        try await observeQuietInterval()
        XCTAssertEqual(view.documentVisibleRect.minY, 500, accuracy: 1)
        document.setFrameSize(NSSize(width: 500, height: 2_400))
        try await observeQuietInterval()
        XCTAssertEqual(view.documentVisibleRect.minY, 500, accuracy: 1)
        controller.resumeFollowing()
        try await waitForBottom(view, at: 2_400)
        XCTAssertTrue(controller.isFollowing)
        XCTAssertEqual(view.documentVisibleRect.maxY, 2_400, accuracy: 1)
    }
    func testReturningToBottomResumesAndLateLayoutKeepsFollowing() async throws {
        let (controller, view, document, _) = fixture()
        defer { controller.disconnect() }
        try await waitForBottom(view, at: 2_000)
        scroll(view, to: 200)
        XCTAssertFalse(controller.isFollowing)
        scroll(view, to: 1_600)
        XCTAssertTrue(controller.isFollowing)
        document.setFrameSize(NSSize(width: 500, height: 2_600))
        try await waitForBottom(view, at: 2_600)
        XCTAssertEqual(view.documentVisibleRect.maxY, 2_600, accuracy: 1)
        view.setFrameSize(NSSize(width: 500, height: 300))
        try await waitForBottom(view, at: 2_600)
        XCTAssertEqual(view.documentVisibleRect.maxY, 2_600, accuracy: 1)
    }
    func testSearchAndHiddenTerminalDoNotStealPositionAndThreadSwitchResets() async throws {
        let (controller, view, document, thread) = fixture()
        defer { controller.disconnect() }
        connect(controller, view, threadID: thread, suspended: false, searching: true)
        view.contentView.scroll(to: NSPoint(x: 0, y: 300))
        connect(controller, view, threadID: thread, suspended: false, searching: false)
        try await observeQuietInterval()
        XCTAssertFalse(controller.isFollowing)
        XCTAssertEqual(view.documentVisibleRect.minY, 300, accuracy: 1)
        connect(controller, view, threadID: UUID(), suspended: false, searching: false)
        try await waitForBottom(view, at: 2_000)
        XCTAssertTrue(controller.isFollowing)
        XCTAssertEqual(view.documentVisibleRect.maxY, 2_000, accuracy: 1)
        connect(controller, view, threadID: thread, suspended: true, searching: false)
        document.setFrameSize(NSSize(width: 500, height: 2_500))
        try await observeQuietInterval()
        XCTAssertEqual(view.documentVisibleRect.maxY, 2_000, accuracy: 1)
        connect(controller, view, threadID: thread, suspended: false, searching: false)
        try await waitForBottom(view, at: 2_500)
        XCTAssertEqual(view.documentVisibleRect.maxY, 2_500, accuracy: 1)
    }
    func testLiveTrackingAndDisconnectCancelDeferredScrolling() async throws {
        let (controller, view, document, _) = fixture()
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: view)
        try await observeQuietInterval()
        XCTAssertEqual(view.documentVisibleRect.minY, 0, accuracy: 1)
        scroll(view, to: 500)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: view)
        controller.resumeFollowing()
        controller.disconnect()
        try await observeQuietInterval()
        XCTAssertEqual(view.documentVisibleRect.minY, 500, accuracy: 1)
        document.setFrameSize(NSSize(width: 500, height: 3_000))
        try await observeQuietInterval()
        XCTAssertEqual(view.documentVisibleRect.minY, 500, accuracy: 1)
    }
    func testScrollPositionAndUnchangedConnectionsDoNotRequestBottomJumps() async throws {
        let (controller, view, _, thread) = fixture()
        defer { controller.disconnect() }
        try await waitForBottom(view, at: 2_000)
        var jumps = 0
        controller.connect(view, threadID: thread, suspended: false, searching: false) { jumps += 1 }
        // Ordinary scrolling inside the follow threshold must not snap to the end.
        scroll(view, to: 1_580)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: view)
        controller.connect(view, threadID: thread, suspended: false, searching: false) { jumps += 1 }
        try await observeQuietInterval()
        XCTAssertTrue(controller.isFollowing)
        XCTAssertEqual(jumps, 0)
        XCTAssertEqual(view.documentVisibleRect.minY, 1_580, accuracy: 1)
        controller.contentChanged()
        try await waitUntil("Content changes should request a bottom jump") { jumps == 1 }
        XCTAssertEqual(jumps, 1, "Actual content changes still follow while near the bottom")
        scroll(view, to: 1_600)
        controller.contentChanged()
        try await observeQuietInterval()
        XCTAssertEqual(jumps, 1, "An already-visible end needs no programmatic scroll")
    }

    func testGrowthDuringLiveScrollFollowsAfterGestureEnds() async throws {
        let (controller, view, document, _) = fixture()
        defer { controller.disconnect() }
        try await waitForBottom(view, at: 2_000)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: view)
        document.setFrameSize(NSSize(width: 500, height: 2_020))
        try await observeQuietInterval()
        XCTAssertEqual(view.documentVisibleRect.maxY, 2_000, accuracy: 1)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: view)
        try await waitForBottom(view, at: 2_020)
        XCTAssertEqual(view.documentVisibleRect.maxY, 2_020, accuracy: 1)
    }

    func testWheelMomentumPreventsPendingFollowBetweenNativeNotifications() async throws {
        let (controller, view, document, _) = fixture()
        defer { controller.disconnect() }
        try await waitForBottom(view, at: 2_000)
        controller.receivedWheelEvent()
        // End-of-finger can precede momentum; native didEnd alone must not release follow.
        scroll(view, to: 1_580)
        document.setFrameSize(NSSize(width: 500, height: 2_010))
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: view)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(view.documentVisibleRect.minY, 1_580, accuracy: 1)
        controller.receivedWheelEvent()
        scroll(view, to: 1_400)
        try await Task.sleep(for: .milliseconds(240))
        XCTAssertFalse(controller.isFollowing)
        XCTAssertEqual(view.documentVisibleRect.minY, 1_400, accuracy: 1)
    }

    func testNativeFollowTracksMeasuredDocumentWithoutSwiftUIReanchoring() async throws {
        let (controller, view, document, thread) = fixture()
        defer { controller.disconnect() }
        controller.connect(view, threadID: thread, suspended: false, searching: false) { controller.scrollToEnd() }
        try await waitForBottom(view, at: 2_000)
        XCTAssertEqual(view.documentVisibleRect.maxY, 2_000, accuracy: 1)
        for height in stride(from: 2_020, through: 2_200, by: 20) {
            document.setFrameSize(NSSize(width: 500, height: height))
            try await waitForBottom(view, at: CGFloat(height))
            XCTAssertEqual(view.documentVisibleRect.maxY, CGFloat(height), accuracy: 1)
        }
        scroll(view, to: 800)
        document.setFrameSize(NSSize(width: 700, height: 1_800))
        try await observeQuietInterval()
        XCTAssertEqual(view.documentVisibleRect.minY, 800, accuracy: 1)
    }

}
