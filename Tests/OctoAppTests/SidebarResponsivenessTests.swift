import AppKit
import Darwin
import SwiftUI
import XCTest
import OctoCore
@testable import OctoApp

@MainActor final class SidebarResponsivenessTests: XCTestCase {
    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }

    func testCollapsingAProjectKeepsItsRowsMountedAndHidden() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(storage: WorkspaceStore(fileURL: root.appendingPathComponent("workspace.json")))
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let threads = (0..<12).map { index -> WorkspaceThread in
            var thread = WorkspaceThread(title: "Thread \(index)", workingDirectory: root.path)
            thread.messages = [.init(role: .user, text: "Offline fixture")]
            return thread
        }
        let project = WorkspaceProject(name: "Fixture", rootPath: root.path, threads: threads)
        store.archive = WorkspaceArchive(projects: [project], selectedProjectID: project.id, selectedThreadID: threads[0].id)
        store.archive.recentSectionCollapsed = true
        let host = NSHostingView(rootView: ProjectSidebar(store: store, switchProject: {}, didNavigate: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        let expanded = descendants(ThreadHoverAnchorView.self, in: host)
        // Long lists start at the default page; the rest wait behind Show more.
        XCTAssertGreaterThanOrEqual(expanded.count, SidebarThreadLimit.initial)
        XCTAssertTrue(expanded.allSatisfy { !$0.visibleRect.isEmpty })

        store.toggleProjectCollapse(project.id)
        try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
        let collapsed = descendants(ThreadHoverAnchorView.self, in: host)
        XCTAssertEqual(Set(collapsed.map(ObjectIdentifier.init)), Set(expanded.map(ObjectIdentifier.init)),
                       "Collapsing must not destroy rows; rebuilding them made expand/collapse slow")
        XCTAssertTrue(collapsed.allSatisfy { $0.visibleRect.isEmpty }, "Collapsed rows must not be visible")

        store.toggleProjectCollapse(project.id)
        try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(descendants(ThreadHoverAnchorView.self, in: host).allSatisfy { !$0.visibleRect.isEmpty })
    }

    func testRowsUnderAScrollDoNotHover() async throws {
        let view = ThreadHoverAnchorView(frame: NSRect(x: 0, y: 0, width: 240, height: 36))
        var values: [Bool] = []
        view.onHover = { values.append($0) }
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                         windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        SidebarScrollActivity.recordScroll()
        view.mouseEntered(with: event)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(values, [], "Content scrolling beneath the pointer must not hover each row")
        try await Task.sleep(for: .seconds(SidebarScrollActivity.quietPeriod))
        view.mouseMoved(with: event)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(values, [true], "Moving the pointer after scrolling settles restores hover")
        XCTAssertNil(view.panel, "The hover card waits for the pointer to rest")
        view.dismiss()
    }
}
