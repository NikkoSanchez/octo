import AppKit
import SwiftUI
import XCTest
import OctoCore
@testable import OctoGhostty
@testable import OctoTerminal

@MainActor final class TerminalSplitTests: XCTestCase {
    private func tab() -> TerminalTab { TerminalTab(projectID: UUID(), directory: "/tmp", label: "Terminal") }

    func testGhosttyNewSplitAddsFocusedShellPaneInInheritedDirectory() throws {
        let tab = tab()
        let first = tab.state
        first.onSplitAction?(.new(.right, directory: NSHomeDirectory(), fontSize: 15))
        XCTAssertEqual(tab.panes.count, 2)
        let second = try XCTUnwrap(tab.panes.last)
        XCTAssertTrue(tab.state === second, "The new pane takes focus")
        XCTAssertEqual(tab.layout.leaves, [first.id, second.id])
        XCTAssertEqual(second.options.directory, NSHomeDirectory())
        XCTAssertEqual(second.options.fontSize, 15)
        XCTAssertNil(second.options.command, "Splits are shells even beside an editor")
        XCTAssertTrue(second.options.isSplit)
        XCTAssertEqual(second.options.environment, first.options.environment)

        second.onSplitAction?(.new(.down, directory: "/missing-octo-directory", fontSize: nil))
        XCTAssertEqual(tab.panes.last?.options.directory, "/tmp", "A vanished directory falls back to the checkout")
        XCTAssertEqual(tab.panes.first?.id, first.id)
    }

    func testFocusZoomAndEqualizeFollowGhosttyActions() throws {
        let tab = tab()
        let first = tab.state
        first.onSplitAction?(.new(.right, directory: nil, fontSize: nil))
        let second = tab.state
        second.onSplitAction?(.focus(.left))
        XCTAssertTrue(tab.state === first)
        first.onSplitAction?(.toggleZoom)
        XCTAssertEqual(tab.layout.zoomed, first.id)
        first.onSplitAction?(.focus(.next))
        XCTAssertNil(tab.layout.zoomed, "Moving focus leaves zoom")
        XCTAssertTrue(tab.state === second)
        tab.setRatio(0.8, at: [])
        second.onSplitAction?(.equalize)
        XCTAssertEqual(tab.layout.dividers(in: CGRect(x: 0, y: 0, width: 100, height: 100)).first?.ratio, 0.5)
        tab.bounds = CGRect(x: 0, y: 0, width: 400, height: 200)
        second.onSplitAction?(.resize(.left, points: 40))
        XCTAssertEqual(try XCTUnwrap(tab.layout.dividers(in: tab.bounds).first?.ratio), 0.4, accuracy: 1e-9)
    }

    func testSinglePaneIgnoresZoomAndClosedPanesIgnoreLateActions() {
        let tab = tab()
        let first = tab.state
        first.onSplitAction?(.toggleZoom)
        XCTAssertNil(tab.layout.zoomed)
        first.onSplitAction?(.new(.right, directory: nil, fontSize: nil))
        let second = tab.state
        second.onClose?(false)
        second.onSplitAction?(.new(.down, directory: nil, fontSize: nil))
        XCTAssertEqual(tab.panes.count, 1, "A removed pane cannot split")
    }

    func testExitedPaneClosesAndFocusMovesWhileLastPaneMarksTabExited() throws {
        let tab = tab()
        let first = tab.state
        first.onSplitAction?(.new(.right, directory: nil, fontSize: nil))
        let second = tab.state
        second.onSplitAction?(.new(.down, directory: nil, fontSize: nil))
        let third = tab.state

        third.onClose?(false)
        XCTAssertTrue(third.isClosed)
        XCTAssertEqual(tab.panes.map(\.id), [first.id, second.id])
        XCTAssertTrue(tab.state === second, "Focus goes to the previous pane")
        XCTAssertFalse(tab.exited)

        first.onClose?(false)
        XCTAssertEqual(tab.layout.root, .leaf(second.id))
        XCTAssertTrue(tab.state === second)

        second.onClose?(false)
        XCTAssertTrue(tab.exited, "The last pane stays so its exit is visible")
        XCTAssertFalse(second.isClosed)
        XCTAssertEqual(tab.panes.count, 1)
    }

    func testClosingTabClosesEveryPane() {
        let workspace = TerminalWorkspace()
        let tab = workspace.newTab(projectID: UUID(), directory: "/tmp")
        tab.state.onSplitAction?(.new(.right, directory: nil, fontSize: nil))
        let panes = tab.panes
        workspace.close(tab)
        XCTAssertTrue(panes.allSatisfy(\.isClosed))
        XCTAssertTrue(workspace.tabs.isEmpty)
    }

    func testSplitWithoutSurfaceFallsBackToTabDirectory() {
        let tab = tab()
        tab.split(.down)
        XCTAssertEqual(tab.panes.count, 2)
        guard case let .split(axis, _, _, _) = tab.layout.root else { return XCTFail("not split") }
        XCTAssertEqual(axis, .vertical)
        XCTAssertEqual(tab.state.options.directory, "/tmp")
    }

    func testEditorPaneTakesFocusBackFromItsSplits() throws {
        let tab = TerminalTab(projectID: UUID(), directory: "/tmp", label: "file.txt", editorSession: try EditorSession())
        let editor = tab.state
        editor.onSplitAction?(.new(.right, directory: nil, fontSize: nil))
        tab.toggleZoom()
        tab.focusEditorPane()
        XCTAssertTrue(tab.state === editor)
        XCTAssertNil(tab.layout.zoomed, "A zoomed shell no longer covers the editor")
        tab.close()
    }

    func testPaneFocusReportedBySurfaceBecomesTabFocus() {
        let tab = tab()
        let first = tab.state
        first.onSplitAction?(.new(.right, directory: nil, fontSize: nil))
        first.onFocus?()
        XCTAssertEqual(tab.focusedPane, first.id)
    }

    /// Splitting and closing must move and resize a surface, never remount it.
    func testSplitsKeepFirstSurfaceMountedAndResizeIt() throws {
        let workspace = TerminalWorkspace()
        let projectID = UUID()
        let tab = workspace.newTab(projectID: projectID, directory: "/tmp")
        let host = NSHostingView(rootView: TerminalSurfaces(workspace: workspace, projectID: projectID, visible: true) { _ in Color.clear })
        host.frame = NSRect(x: 0, y: 0, width: 801, height: 400)
        host.layoutSubtreeIfNeeded()
        let first = tab.state
        let view = try XCTUnwrap(first.view)
        XCTAssertNotNil(view.superview)
        XCTAssertEqual(view.frame.width, 801, accuracy: 0.5)

        tab.split(.right)
        let second = tab.state
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(first.view === view, "The first pane keeps its native view")
        XCTAssertNotNil(view.superview)
        XCTAssertEqual(view.frame.width, 400, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(second.view).frame.width, 400, accuracy: 0.5)

        second.onClose?(false)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(first.view === view)
        XCTAssertNotNil(view.superview)
        XCTAssertEqual(view.frame.width, 801, accuracy: 0.5)
        XCTAssertFalse(second.view?.isDescendant(of: host) ?? false, "A closed pane leaves the hierarchy")
        workspace.shutdown()
    }
}
