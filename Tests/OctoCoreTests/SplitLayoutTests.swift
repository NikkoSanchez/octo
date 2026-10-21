import XCTest
@testable import OctoCore

final class SplitLayoutTests: XCTestCase {
    /// a | b, with b split into b over c.
    private func threePanes() -> SplitLayout<String> {
        var layout = SplitLayout("a")
        XCTAssertTrue(layout.insert("b", beside: "a", direction: .right))
        XCTAssertTrue(layout.insert("c", beside: "b", direction: .down))
        return layout
    }

    func testInsertPlacesNewPaneOnTheRequestedSide() {
        for (direction, expected) in [(SplitDirection.right, ["a", "b"]), (.down, ["a", "b"]), (.left, ["b", "a"]), (.up, ["b", "a"])] {
            var layout = SplitLayout("a")
            layout.insert("b", beside: "a", direction: direction)
            XCTAssertEqual(layout.leaves, expected, "\(direction)")
            guard case let .split(axis, ratio, _, _) = layout.root else { return XCTFail("not split") }
            XCTAssertEqual(axis, direction == .left || direction == .right ? .horizontal : .vertical)
            XCTAssertEqual(ratio, 0.5)
        }
        var layout = SplitLayout("a")
        XCTAssertFalse(layout.insert("a", beside: "a", direction: .right), "A pane appears once")
        XCTAssertFalse(layout.insert("b", beside: "missing", direction: .right))
    }

    func testRemoveCollapsesParentIntoSiblingAndKeepsLastPane() {
        var layout = threePanes()
        XCTAssertTrue(layout.remove("b"))
        XCTAssertEqual(layout.root, .split(.horizontal, ratio: 0.5, first: .leaf("a"), second: .leaf("c")))
        XCTAssertTrue(layout.remove("a"))
        XCTAssertEqual(layout.root, .leaf("c"))
        XCTAssertFalse(layout.remove("c"), "The last pane belongs to the tab")
        XCTAssertFalse(layout.remove("missing"))
    }

    func testZoomClearsWhenItsPaneLeavesOrTheTreeChanges() {
        var layout = threePanes()
        layout.zoomed = "missing"
        XCTAssertNil(layout.zoomed)
        layout.zoomed = "c"
        layout.remove("c")
        XCTAssertNil(layout.zoomed)
        layout.zoomed = "a"
        layout.insert("d", beside: "b", direction: .right)
        XCTAssertNil(layout.zoomed, "Ghostty unzooms when a split is created")
    }

    func testPreviousAndNextWrapInTreeOrder() {
        let layout = threePanes()
        XCTAssertEqual(layout.focusTarget(.next, from: "a"), "b")
        XCTAssertEqual(layout.focusTarget(.next, from: "c"), "a")
        XCTAssertEqual(layout.focusTarget(.previous, from: "a"), "c")
        XCTAssertNil(SplitLayout("a").focusTarget(.next, from: "a"))
    }

    func testSpatialFocusFindsTheNearestPaneInThatDirection() {
        let layout = threePanes()
        XCTAssertEqual(layout.focusTarget(.right, from: "a"), "b", "Nearest top-left corner wins")
        XCTAssertEqual(layout.focusTarget(.left, from: "c"), "a")
        XCTAssertEqual(layout.focusTarget(.down, from: "b"), "c")
        XCTAssertEqual(layout.focusTarget(.up, from: "c"), "b")
        XCTAssertNil(layout.focusTarget(.left, from: "a"))
        XCTAssertNil(layout.focusTarget(.up, from: "b"))
        XCTAssertNil(layout.focusTarget(.down, from: "a"), "a spans the full height")
    }

    func testSpatialFocusIgnoresRatiosLikeGhostty() {
        var layout = threePanes()
        layout.setRatio(0.9, at: [1])
        XCTAssertEqual(layout.focusTarget(.down, from: "b"), "c")
        XCTAssertEqual(layout.focusTarget(.right, from: "a"), "b")
    }

    func testFramesLeaveTheGapForDividersAndCoverTheBounds() {
        let layout = threePanes()
        let bounds = CGRect(x: 0, y: 0, width: 801, height: 401)
        let frames = layout.frames(in: bounds, gap: 1)
        XCTAssertEqual(frames["a"], CGRect(x: 0, y: 0, width: 400, height: 401))
        XCTAssertEqual(frames["b"], CGRect(x: 401, y: 0, width: 400, height: 200))
        XCTAssertEqual(frames["c"], CGRect(x: 401, y: 201, width: 400, height: 200))
        let dividers = layout.dividers(in: bounds, gap: 1)
        XCTAssertEqual(dividers.map(\.path), [[], [1]])
        XCTAssertEqual(dividers[0].frame, CGRect(x: 400, y: 0, width: 1, height: 401))
        XCTAssertEqual(dividers[1].frame, CGRect(x: 401, y: 200, width: 400, height: 1))
        XCTAssertEqual(dividers[1].container, CGRect(x: 401, y: 0, width: 400, height: 401))
    }

    func testResizeMovesNearestDividerOnTheMatchingAxis() {
        var layout = threePanes()
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 400)
        // c's nearest vertical split is its own (b over c); its horizontal one is the root.
        XCTAssertTrue(layout.resize("c", direction: .up, by: 40, in: bounds))
        XCTAssertEqual(layout.dividers(in: bounds)[1].ratio, 0.4, accuracy: 1e-9)
        XCTAssertTrue(layout.resize("c", direction: .right, by: 80, in: bounds))
        XCTAssertEqual(layout.dividers(in: bounds)[0].ratio, 0.6, accuracy: 1e-9)
        XCTAssertFalse(layout.resize("a", direction: .down, by: 10, in: bounds), "a has no vertical split above it")
        XCTAssertTrue(layout.resize("a", direction: .left, by: 10_000, in: bounds))
        XCTAssertEqual(layout.dividers(in: bounds)[0].ratio, SplitLayout<String>.minimumRatio, "Panes never collapse")
    }

    func testEqualizeWeighsPanesAlongEachAxis() {
        var layout = threePanes()
        layout.insert("d", beside: "c", direction: .right)
        layout.setRatio(0.8, at: [])
        layout.equalize()
        // a | (b over (c | d)): only splits on the same axis add weight, so each side gets half.
        guard case let .split(_, root, _, right) = layout.root, case let .split(_, column, _, _) = right else { return XCTFail() }
        XCTAssertEqual(root, 0.5)
        XCTAssertEqual(column, 0.5)
        var row = SplitLayout("a")
        row.insert("b", beside: "a", direction: .right)
        row.insert("c", beside: "b", direction: .right)
        row.equalize()
        guard case let .split(_, outer, _, _) = row.root else { return XCTFail() }
        XCTAssertEqual(outer, 1.0 / 3.0, accuracy: 1e-9)
    }
}
