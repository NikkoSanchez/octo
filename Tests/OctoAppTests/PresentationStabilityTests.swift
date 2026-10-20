import AppKit
import SwiftUI
import XCTest
import OctoCore
@testable import OctoApp

@MainActor final class PresentationStabilityTests: XCTestCase {
    private final class Input: ObservableObject {
        @Published var source = "A short **formatted** response"
        @Published var reviewVisible = false
    }

    private struct Response: View {
        @ObservedObject var input: Input
        var body: some View { MarkdownResponseView(source: input.source).frame(width: 600) }
    }

    func testStreamingAppendDoesNotInsertTemporaryParagraph() async throws {
        let input = Input()
        let host = NSHostingView(rootView: Response(input: input))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let height = host.fittingSize.height
        XCTAssertGreaterThan(height, 10)
        for tail in [" with", " more", " text", " 🐙"] {
            input.source += tail
            host.layoutSubtreeIfNeeded()
            // Before the asynchronous parse can publish, the prior paragraph
            // must retain its height instead of gaining a second literal row.
            XCTAssertEqual(host.fittingSize.height, height, accuracy: 1)
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertEqual(host.fittingSize.height, height, accuracy: 1)
        }
    }

    func testCachedRenderingMatchesFreshParseThroughBlockBoundaries() {
        var previous: RenderedMarkdown?
        var source = ""
        for fragment in ["# Heading\n\n", "A **bold", " phrase** 🐙\n\n", "```swift\n", "let a = 1\n", "```\n\n", "| A | B |\n", "| --- | --- |\n", "| One | Two |\n"] {
            source += fragment
            let current = RenderedMarkdown(source, previous: previous)
            let fresh = RenderedMarkdown(source)
            XCTAssertEqual(current.document, fresh.document)
            XCTAssertEqual(current.inline, fresh.inline)
            XCTAssertEqual(current.document.blocks.map(\.source).joined(), source)
            previous = current
        }
    }

    private final class Widths { var values: [CGFloat] = [] }
    private struct Probe: NSViewRepresentable {
        let widths: Widths
        func makeNSView(context: Context) -> NativeProbe { NativeProbe(widths: widths) }
        func updateNSView(_ view: NativeProbe, context: Context) {}
        final class NativeProbe: NSView {
            let widths: Widths
            init(widths: Widths) { self.widths = widths; super.init(frame: .zero) }
            required init?(coder: NSCoder) { fatalError() }
            override func setFrameSize(_ size: NSSize) {
                super.setFrameSize(size)
                widths.values.append(size.width)
            }
        }
    }
    private struct Panels: View {
        @ObservedObject var input: Input
        let widths: Widths
        var body: some View {
            ResizableColumns(minLeading: 300, minTrailing: 430, initialFraction: 0.42,
                             trailingVisible: input.reviewVisible, singleColumnWhenNarrow: true) {
                Probe(widths: widths)
            } trailing: { Color.red }
        }
    }

    func testReviewToggleImmediatelyResizesChatAndPreservesFullClip() async throws {
        let input = Input(), widths = Widths()
        let host = NSHostingView(rootView: Panels(input: input, widths: widths))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(60))
        for visible in [true, false, true, false] {
            widths.values.removeAll()
            input.reviewVisible = visible
            for _ in 0..<20 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(16))
            }
            let expected: CGFloat = visible ? 993 * 0.42 : 1_000
            XCTAssertFalse(widths.values.isEmpty)
            XCTAssertFalse(widths.values.contains { $0 > 993 * 0.42 + 2 && $0 < 998 },
                           "Chat width must change immediately without intermediate animation frames: \(widths.values)")
            XCTAssertEqual(widths.values.last ?? 0, expected, accuracy: 1)
            if visible {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide * 9 / 10,
                                                        y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
                XCTAssertGreaterThan(color.redComponent, color.greenComponent + 0.3,
                                     "The trailing panel must draw across the split's full clip bounds")
            }
        }
    }
    private final class Probes { var leading: [NSView] = []; var trailing: [NSView] = [] }
    private struct FrameProbe: NSViewRepresentable {
        let record: (NSView) -> Void
        func makeNSView(context: Context) -> NSView { let view = NSView(); record(view); return view }
        func updateNSView(_ view: NSView, context: Context) {}
    }
    private struct StackedPanels: View {
        @ObservedObject var input: Input
        let probes: Probes
        var body: some View {
            ResizableColumns(minLeading: 150, maxLeading: 260, minTrailing: 270, initialFraction: 0.3,
                             stackedLeadingHeight: input.reviewVisible ? 120 : nil, opaqueTrailing: false) {
                FrameProbe { probes.leading.append($0) }
            } trailing: { FrameProbe { probes.trailing.append($0) } }
        }
    }

    /// Changes stacks its file rows above the diff and Files puts its tree beside the editor; switching
    /// between them must move the same mounted panes, never rebuild the editor.
    func testStackedColumnsPlaceLeadingAboveTrailingWithoutRemounting() async throws {
        let input = Input(), probes = Probes()
        let host = NSHostingView(rootView: StackedPanels(input: input, probes: probes))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        func frames() async throws -> (leading: CGRect, trailing: CGRect) {
            for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(16)) }
            let leading = try XCTUnwrap(probes.leading.last), trailing = try XCTUnwrap(probes.trailing.last)
            XCTAssertTrue(host.isFlipped)
            return (leading.convert(leading.bounds, to: host), trailing.convert(trailing.bounds, to: host))
        }
        // 30% of the 493 pt beside the divider is under the 150 pt minimum.
        let side = try await frames()
        XCTAssertEqual(side.leading, CGRect(x: 0, y: 0, width: 150, height: 600))
        XCTAssertEqual(side.trailing, CGRect(x: 157, y: 0, width: 343, height: 600))
        input.reviewVisible = true
        let stacked = try await frames()
        XCTAssertEqual(stacked.leading, CGRect(x: 0, y: 0, width: 500, height: 120))
        XCTAssertEqual(stacked.trailing, CGRect(x: 0, y: 120, width: 500, height: 480))
        input.reviewVisible = false
        _ = try await frames()
        XCTAssertEqual(probes.leading.count, 1, "The leading pane must stay mounted across layouts")
        XCTAssertEqual(probes.trailing.count, 1, "The trailing pane must stay mounted across layouts")
    }

    func testLongTranscriptKeepsMeasuredHeightAndReadingPositionAcrossScrolls() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(storage: WorkspaceStore(fileURL: directory.appendingPathComponent("workspace.json")))
        defer { store.shutdown() }
        var thread = WorkspaceThread(harness: .claude, workingDirectory: directory.path)
        for index in 0..<24 {
            thread.messages.append(ChatMessage(role: .user, text: "Question \(index)"))
            thread.messages.append(ChatMessage(role: .assistant, text: "## Answer \(index)\n\n" + String(repeating: "A measured **Markdown** paragraph with `code` and enough text to wrap. ", count: 20)))
        }
        let project = WorkspaceProject(name: "Fixture", rootPath: directory.path, threads: [thread])
        store.archive = WorkspaceArchive(projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id)
        let host = NSHostingView(rootView: ChatPane(store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(800))
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        let scroll = try XCTUnwrap(scrollViews(host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        let document = try XCTUnwrap(scroll.documentView)
        let height = document.frame.height
        XCTAssertGreaterThan(height, 5_000)
        for fraction in [0.7, 0.3, 0.05, 0.5] {
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            let position = height * fraction
            scroll.contentView.scroll(to: NSPoint(x: 0, y: position))
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            try await Task.sleep(for: .milliseconds(120))
            XCTAssertEqual(document.frame.height, height, accuracy: 1, "Scrolling must not realize empty/reparsed historical rows")
            XCTAssertEqual(scroll.documentVisibleRect.minY, position, accuracy: 1, "User reading position must stay put")
        }
    }

}
