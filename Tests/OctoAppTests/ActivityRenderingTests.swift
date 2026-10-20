import AppKit
import Darwin
import SwiftUI
import XCTest
import OctoCore
@testable import OctoApp

@MainActor final class ActivityRenderingTests: XCTestCase {
    private final class CountingHost<Content: View>: NSHostingView<Content> {
        var layouts = 0
        override func layout() { layouts += 1; super.layout() }
    }

    func testWorkingSidebarSkipsIdleAndTranscriptLayoutsButUpdatesMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(storage: WorkspaceStore(fileURL: root.appendingPathComponent("workspace.json")))
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let threads = (0..<100).map { index -> WorkspaceThread in
            var thread = WorkspaceThread(title: "Conversation \(index) with a long sidebar title", workingDirectory: root.path)
            thread.messages = [.init(role: .user, text: "Offline fixture")]
            return thread
        }
        let project = WorkspaceProject(name: "Fixture", rootPath: root.path, threads: threads)
        store.archive = WorkspaceArchive(projects: [project], selectedProjectID: project.id, selectedThreadID: threads.last!.id)
        store.running = Set(threads.suffix(2).map(\.id))
        let host = CountingHost(rootView: ProjectSidebar(store: store, switchProject: {}, didNavigate: {})
            .environment(\.scenePhase, .active))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(500))
        host.layouts = 0
        var start = rusage(), end = rusage()
        getrusage(RUSAGE_SELF, &start)
        try await Task.sleep(for: .seconds(2))
        getrusage(RUSAGE_SELF, &end)
        let cpu = Double(end.ru_utime.tv_sec - start.ru_utime.tv_sec) + Double(end.ru_utime.tv_usec - start.ru_utime.tv_usec) / 1_000_000
        print("Idle working sidebar: \(host.layouts) layouts, \(cpu) user CPU seconds / 2 wall seconds")
        XCTAssertLessThanOrEqual(host.layouts, 4, "Activity pulses must not drive the sidebar's SwiftUI layout every frame")

        let active = threads.last!.id
        store.receive(.textDelta("Starting"), threadID: active)
        store.flushStreamText()
        try await Task.sleep(for: .milliseconds(100))
        host.layouts = 0
        for _ in 0..<40 {
            store.receive(.textDelta(" more output"), threadID: active)
            store.flushStreamText()
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertLessThanOrEqual(host.layouts, 4, "Transcript-only changes must not rebuild sidebar rows or lazy placement")

        func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
        }
        func titles() -> [String] {
            descendants(MarqueeTitleView.self, in: host).compactMap {
                (($0.layer?.sublayers?.first as? CATextLayer)?.string as? NSAttributedString)?.string
            }
        }
        store.renameThread(active, title: "Renamed working conversation")
        for _ in 0..<100 {
            if titles().contains("Renamed working conversation") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(titles().contains("Renamed working conversation"), "Display metadata changes must still reach the native title")
        // Working rows ring their avatar and show typing dots in place of the streamed text.
        XCTAssertFalse(descendants(AvatarRingView.self, in: host).isEmpty)
        XCTAssertFalse(descendants(TypingDotsView.self, in: host).isEmpty)
        store.running.removeAll()
        for _ in 0..<100 {
            if descendants(AvatarRingView.self, in: host).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(descendants(AvatarRingView.self, in: host).isEmpty, "Working state must update independently of transcript text")
        XCTAssertTrue(descendants(TypingDotsView.self, in: host).isEmpty)
    }

    func testPulseKeepsItsPhaseAcrossUpdatesAndStopsWhenInactiveHiddenOrDetached() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 16, height: 16),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentLayoutRect)
        let pulse = ActivityPulseView(frame: container.bounds)
        container.addSubview(pulse); window.contentView = container
        defer { window.close() }
        pulse.update(symbol: "circle.fill", color: .systemBlue, animate: true)
        let started = try XCTUnwrap(pulse.layer?.animation(forKey: "activityPulse")?.beginTime)
        for _ in 0..<1_000 { pulse.update(symbol: "circle.fill", color: .systemBlue, animate: true) }
        pulse.update(symbol: "circle.fill", color: .systemRed, animate: true)
        XCTAssertEqual(pulse.layer?.animation(forKey: "activityPulse")?.beginTime, started,
                       "Unrelated chat updates and theme changes must not restart the pulse")
        XCTAssertEqual(pulse.contentTintColor, .systemRed)
        pulse.update(symbol: "circle.fill", color: .systemRed, animate: false)
        XCTAssertNil(pulse.layer?.animation(forKey: "activityPulse"), "Reduce Motion and inactive scenes keep a still indicator")
        XCTAssertEqual(pulse.layer?.opacity, 1)
        pulse.update(symbol: "arrow.triangle.2.circlepath", color: .systemRed, animate: true)
        XCTAssertNotNil(pulse.image)
        XCTAssertNotNil(pulse.layer?.animation(forKey: "activityPulse"))
        container.isHidden = true
        XCTAssertNil(pulse.layer?.animation(forKey: "activityPulse"))
        container.isHidden = false
        XCTAssertNotNil(pulse.layer?.animation(forKey: "activityPulse"))
        pulse.removeFromSuperview()
        XCTAssertNil(pulse.layer?.animation(forKey: "activityPulse"))
        container.addSubview(pulse)
        XCTAssertNotNil(pulse.layer?.animation(forKey: "activityPulse"))
        pulse.stopAnimation()
        XCTAssertNil(pulse.layer?.animation(forKey: "activityPulse"))
    }

    func testLiveDotKeepsItsPhaseAndStopsWhenStillHiddenOrDetached() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 16, height: 16),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentLayoutRect)
        let dot = LiveDotView(frame: container.bounds)
        container.addSubview(dot); window.contentView = container
        defer { window.close() }
        dot.update(color: .systemBlue, animate: true)
        let started = try XCTUnwrap(dot.ring.animation(forKey: "liveRing")?.beginTime)
        for _ in 0..<1_000 { dot.update(color: .systemBlue, animate: true) }
        dot.update(color: .systemRed, animate: true)
        XCTAssertEqual(dot.ring.animation(forKey: "liveRing")?.beginTime, started,
                       "Unrelated chat updates and theme changes must not restart the ring")
        dot.update(color: .systemRed, animate: false)
        XCTAssertNil(dot.ring.animation(forKey: "liveRing"), "Reduce Motion and inactive scenes keep a still dot")
        XCTAssertEqual(dot.ring.opacity, 0, "A still dot shows no ring")
        dot.update(color: .systemRed, animate: true)
        container.isHidden = true
        XCTAssertNil(dot.ring.animation(forKey: "liveRing"))
        container.isHidden = false
        XCTAssertNotNil(dot.ring.animation(forKey: "liveRing"))
        dot.removeFromSuperview()
        XCTAssertNil(dot.ring.animation(forKey: "liveRing"))
    }

    func testAvatarRingAndTypingDotsKeepTheirPhaseAndStopWhenStillHiddenOrDetached() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 44, height: 44),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentLayoutRect)
        let ring = AvatarRingView(frame: container.bounds), dots = TypingDotsView(frame: NSRect(x: 0, y: 0, width: 20, height: 10))
        container.addSubview(ring); container.addSubview(dots); window.contentView = container
        defer { window.close() }
        ring.update(color: .systemBlue, animate: true); dots.update(color: .systemGray, animate: true)
        let ringStart = try XCTUnwrap(ring.ring.animation(forKey: "avatarRing")?.beginTime)
        let dotStart = try XCTUnwrap(dots.dots[0].animation(forKey: "typing")?.beginTime)
        for _ in 0..<1_000 { ring.update(color: .systemBlue, animate: true); dots.update(color: .systemGray, animate: true) }
        ring.update(color: .systemRed, animate: true); dots.update(color: .white, animate: true)
        XCTAssertEqual(ring.ring.animation(forKey: "avatarRing")?.beginTime, ringStart, "Updates and theme changes must not restart the ring")
        XCTAssertEqual(dots.dots[0].animation(forKey: "typing")?.beginTime, dotStart, "Updates and theme changes must not restart the dots")
        XCTAssertNotEqual(dots.dots[0].animation(forKey: "typing")?.beginTime, dots.dots[1].animation(forKey: "typing")?.beginTime,
                          "The dots fade in sequence")
        ring.update(color: .systemRed, animate: false); dots.update(color: .white, animate: false)
        XCTAssertNil(ring.ring.animation(forKey: "avatarRing"), "Reduce Motion and inactive scenes keep a still ring")
        XCTAssertNil(dots.dots[0].animation(forKey: "typing"))
        ring.update(color: .systemRed, animate: true); dots.update(color: .white, animate: true)
        container.isHidden = true
        XCTAssertNil(ring.ring.animation(forKey: "avatarRing")); XCTAssertNil(dots.dots[0].animation(forKey: "typing"))
        container.isHidden = false
        XCTAssertNotNil(ring.ring.animation(forKey: "avatarRing")); XCTAssertNotNil(dots.dots[0].animation(forKey: "typing"))
        ring.removeFromSuperview(); dots.removeFromSuperview()
        XCTAssertNil(ring.ring.animation(forKey: "avatarRing")); XCTAssertNil(dots.dots[0].animation(forKey: "typing"))
    }

    func testShimmerSurvivesTimerTextChangesAndStopsWhenStill() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 20),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentLayoutRect)
        let shimmer = ShimmerTextView(frame: container.bounds)
        container.addSubview(shimmer); window.contentView = container
        defer { window.close() }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        shimmer.update(text: "Working for 9s", font: font, base: .secondaryLabelColor, highlight: .labelColor, animate: true)
        let started = try XCTUnwrap(shimmer.band.animation(forKey: "shimmer")?.beginTime)
        let narrow = shimmer.label.intrinsicContentSize.width
        shimmer.update(text: "Working for 1m 10s", font: font, base: .secondaryLabelColor, highlight: .labelColor, animate: true)
        shimmer.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(shimmer.label.intrinsicContentSize.width, narrow)
        XCTAssertEqual(shimmer.band.animation(forKey: "shimmer")?.beginTime, started,
                       "The elapsed timer changes text every second without restarting the sweep")
        XCTAssertEqual(shimmer.label.stringValue, "Working for 1m 10s")
        shimmer.update(text: "Working for 1m 10s", font: font, base: .secondaryLabelColor, highlight: .labelColor, animate: false)
        XCTAssertNil(shimmer.band.animation(forKey: "shimmer"))
        XCTAssertTrue(shimmer.shineContainer.isHidden, "Reduce Motion shows only the plain text")
        shimmer.update(text: "Working for 1m 10s", font: font, base: .secondaryLabelColor, highlight: .labelColor, animate: true)
        shimmer.removeFromSuperview()
        XCTAssertNil(shimmer.band.animation(forKey: "shimmer"))
    }

    func testShimmerTextIsNotClipped() async throws {
        let host = NSHostingView(rootView: HStack(spacing: 7) { ShimmerText(text: "Working for 56s"); Spacer(minLength: 0) }.frame(width: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 30), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> ShimmerTextView? { (view as? ShimmerTextView) ?? view.subviews.lazy.compactMap(find).first }
        let shimmer = try XCTUnwrap(find(host))
        let needed = try XCTUnwrap(shimmer.label.cell?.cellSize.width)
        XCTAssertGreaterThanOrEqual(shimmer.label.frame.width, needed, "The cell's text inset must fit, or the last glyph is clipped")
    }
}
