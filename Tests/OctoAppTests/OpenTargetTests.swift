import AppKit
import SwiftUI
import XCTest
@testable import OctoApp

@MainActor final class OpenTargetTests: XCTestCase {
    func testLineURLsEncodeThePathAndKeepTheLine() throws {
        let url = try XCTUnwrap(OpenTarget.fileURL(scheme: "vscode", path: "/tmp/My Project/a#b.swift", line: 42))
        XCTAssertEqual(url.absoluteString, "vscode://file/tmp/My%20Project/a%23b.swift:42")
        XCTAssertEqual(OpenTarget.fileURL(scheme: "zed", path: "/tmp/x.swift", line: 0)?.absoluteString, "zed://file/tmp/x.swift:1")
    }

    func testOnlyEditorsWithAFileSchemeGetLineURLs() {
        let schemes = Dictionary(uniqueKeysWithValues: OpenTarget.all.compactMap { target in target.fileScheme.map { (target.id, $0) } })
        XCTAssertEqual(schemes, ["cursor": "cursor", "vscode": "vscode", "vscode-insiders": "vscode-insiders", "zed": "zed", "windsurf": "windsurf"])
        XCTAssertEqual(Set(OpenTarget.all.filter(\.isTerminal).map(\.id)), ["terminal", "ghostty", "iterm", "warp"])
    }

    func testUnknownPreferenceFallsBackToLazyVim() {
        XCTAssertEqual(OpenTarget.preferred("zed").title, "Zed")
        XCTAssertEqual(OpenTarget.preferred("removed-editor").kind, .lazyVim)
    }

    func testStackedFileListResizesBetweenOneRowAndItsNaturalHeight() {
        // Twelve files want 538 pt; a 1,000 pt panel opens the list at 45% and lets it grow to fit them.
        let tall = StackedSplit.limits(natural: 538, total: 1000)
        XCTAssertEqual(tall.initial, 450); XCTAssertEqual(tall.lower, 44); XCTAssertEqual(tall.upper, 538)
        // The diff keeps at least 160 pt.
        XCTAssertEqual(StackedSplit.limits(natural: 538, total: 600).upper, 440)
        // A short list never grows past its rows or shrinks below them.
        let short = StackedSplit.limits(natural: 98, total: 1000)
        XCTAssertEqual(short.initial, 98); XCTAssertEqual(short.upper, 98); XCTAssertEqual(short.lower, 44)
        XCTAssertEqual(StackedSplit.limits(natural: 10, total: 1000).lower, 10)
    }

    func testHostedStackedDividerHoversOnlyOverItsOwnStrip() throws {
        let columns = ResizableColumns(minLeading: 150, minTrailing: 270, initialFraction: 0.3, stackedLeadingHeight: 200, opaqueTrailing: false) {
            ScrollView { VStack { ForEach(0..<10) { Text("Row \($0)").frame(height: 40) } } }
        } trailing: { Color.red }
        let host = NSHostingView(rootView: columns.frame(width: 400, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let divider = try XCTUnwrap(views(host).compactMap { $0 as? ResizeCursorView }.first { $0.vertical })
        XCTAssertEqual(divider.convert(divider.bounds, to: nil), NSRect(x: 0, y: 396.5, width: 400, height: 7))
        // SwiftUI reports a visible rect as tall as the whole panel; tracking it lit the divider on entering the panel.
        XCTAssertEqual(divider.trackingAreas.map(\.rect), [divider.bounds])
        XCTAssertTrue(window.contentView?.hitTest(NSPoint(x: 200, y: 400)) === divider)
    }

    func testVerticalHandleMeasuresDownwardDrags() {
        let view = ResizeCursorView(frame: NSRect(x: 0, y: 0, width: 300, height: 7))
        view.vertical = true; view.enabled = true
        var translations: [CGFloat] = []
        view.onDrag = { translations.append($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [], backing: .buffered, defer: true)
        window.contentView?.addSubview(view)
        func event(_ type: NSEvent.EventType, y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: 10, y: y), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, y: 200))
        view.mouseDragged(with: event(.leftMouseDragged, y: 170))
        view.mouseUp(with: event(.leftMouseUp, y: 170))
        XCTAssertEqual(translations, [0, 30])
    }
}
