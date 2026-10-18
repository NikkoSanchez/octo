import AppKit
import Darwin
import SwiftUI
import XCTest
import OctoCore
@testable import OctoApp

@MainActor final class ComposerLayoutTests: XCTestCase {
    private func popups(_ view: NSView) -> [NSPopUpButton] {
        (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(popups)
    }
    private func cpuSeconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    /// The agent controls replaced ViewThatFits (which re-measured native menus on every
    /// publication) with a measured compact switch. It must still compact, and settle.
    func testAgentControlsCompactWhenNarrowAndSettle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(storage: WorkspaceStore(fileURL: root.appendingPathComponent("workspace.json")))
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let thread = WorkspaceThread(title: "Layout", harness: .claude, workingDirectory: root.path)
        let project = WorkspaceProject(name: "Fixture", rootPath: root.path, threads: [thread])
        store.archive = WorkspaceArchive(projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id)
        var widths: [CGFloat: [CGFloat]] = [:]
        for width: CGFloat in [360, 900] {
            let host = NSHostingView(rootView: ChatPane(store: store))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(500))
            let start = cpuSeconds()
            try await Task.sleep(for: .seconds(1))
            XCTAssertLessThan(cpuSeconds() - start, 0.1, "Width measurement must not feed back into layout at \(width) points")
            widths[width] = popups(host).map(\.frame.width)
            window.close()
        }
        let narrow = try XCTUnwrap(widths[360]), wide = try XCTUnwrap(widths[900])
        XCTAssertEqual(narrow.count, 2); XCTAssertEqual(wide.count, 2)
        XCTAssertTrue(narrow.contains { $0 < 60 }, "Narrow composers show the permissions icon only: \(narrow)")
        XCTAssertTrue(wide.allSatisfy { $0 > 60 }, "Wide composers show the permissions title: \(wide)")
    }
}
