import AppKit
import Darwin
import SwiftUI
import XCTest
import OctoCore
@testable import OctoApp

@MainActor final class ComposerLayoutTests: XCTestCase {
    /// The agent and permissions menus are SwiftUI hover buttons, so they have no AppKit control of
    /// their own; each focusable SwiftUI control is backed by a focus-ring view of its size.
    private func agentControlWidths(_ host: NSView) -> [CGFloat] {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let row = all(host).filter { String(describing: type(of: $0)).contains("FocusRing") }
            .map { $0.convert($0.bounds, to: nil) }.filter { $0.minY < 100 }.sorted { $0.minX < $1.minX }
        // The agent menu is the widest control in the composer's bottom row; permissions follows it.
        guard let agent = row.indices.max(by: { row[$0].width < row[$1].width }), agent + 1 < row.count else { return [] }
        return [row[agent].width, row[agent + 1].width]
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
            widths[width] = agentControlWidths(host)
            window.close()
        }
        let narrow = try XCTUnwrap(widths[360]), wide = try XCTUnwrap(widths[900])
        XCTAssertEqual(narrow.count, 2); XCTAssertEqual(wide.count, 2)
        XCTAssertLessThan(narrow[1], 60, "Narrow composers show the permissions icon only: \(narrow)")
        XCTAssertGreaterThan(wide[1], narrow[1] + 20, "Wide composers show the permissions title: \(wide)")
    }
}
