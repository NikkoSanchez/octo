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
        XCTAssertFalse(descendants(ActivityPulseView.self, in: host).isEmpty)
        store.running.removeAll()
        for _ in 0..<100 {
            if descendants(ActivityPulseView.self, in: host).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(descendants(ActivityPulseView.self, in: host).isEmpty, "Working state must update independently of transcript text")
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
}
