import AppKit
import SwiftUI

/// Owns follow intent independently of document height. Only a user scroll changes
/// that intent; streamed Markdown/layout changes must never masquerade as scrolling up.
@MainActor final class TranscriptScrollController: NSObject, ObservableObject {
    @Published private(set) var isFollowing = true
    private weak var scrollView: NSScrollView?
    private var threadID: UUID?
    private var suspended = false
    private var tracking = false
    private var wheelActive = false
    private var wheelMonitor: Any?
    private var wheelIdleTask: Task<Void, Never>?
    private var observedDocumentSize: NSSize?
    private var observedViewportSize: NSSize?
    private var needsScroll = false
    private var forceScroll = false
    private var scrollTask: Task<Void, Never>?
    private var performScrollToEnd: (() -> Void)?

    func connect(_ scroll: NSScrollView, threadID: UUID, suspended: Bool, searching: Bool, scrollToEnd: @escaping () -> Void) {
        let connectionChanged = scrollView !== scroll
        let threadChanged = self.threadID != threadID
        let wasSuspended = self.suspended
        if connectionChanged {
            disconnect()
            scrollView = scroll
            observedDocumentSize = scroll.documentView?.frame.size
            observedViewportSize = scroll.contentView.bounds.size
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak scroll] event in
                guard let self, let scroll, event.window === scroll.window,
                      let content = event.window?.contentView,
                      let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)),
                      hit === scroll || hit.isDescendant(of: scroll) else { return event }
                self.receivedWheelEvent()
                return event
            }
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(userWillScroll), name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            center.addObserver(self, selector: #selector(userDidScroll), name: NSScrollView.didLiveScrollNotification, object: scroll)
            center.addObserver(self, selector: #selector(userEndedScroll), name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.contentView.postsFrameChangedNotifications = true
            scroll.documentView?.postsFrameChangedNotifications = true
            center.addObserver(self, selector: #selector(layoutChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            center.addObserver(self, selector: #selector(layoutChanged), name: NSView.frameDidChangeNotification, object: scroll.contentView)
            if let document = scroll.documentView {
                center.addObserver(self, selector: #selector(layoutChanged), name: NSView.frameDidChangeNotification, object: document)
            }
        }
        self.performScrollToEnd = scrollToEnd
        if self.threadID != threadID {
            cancelScroll()
            self.threadID = threadID
            tracking = false
            setFollowing(true)
        }
        self.suspended = suspended || searching
        if searching { setFollowing(false) }
        if self.suspended { cancelScroll() }
        else if connectionChanged || threadChanged || wasSuspended {
            requestScroll(force: connectionChanged || threadChanged)
        }
    }

    func disconnect() {
        cancelScroll()
        NotificationCenter.default.removeObserver(self)
        scrollView = nil
        performScrollToEnd = nil
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
        wheelIdleTask?.cancel(); wheelIdleTask = nil; wheelActive = false
        tracking = false
        needsScroll = false
        forceScroll = false
        observedDocumentSize = nil
        observedViewportSize = nil
    }

    func resumeFollowing() {
        setFollowing(true)
        requestScroll(force: true)
    }

    func contentChanged() { requestScroll() }

    /// All transcript turns are measured. Move the native clip directly instead
    /// of asking ScrollViewReader to realize/re-anchor its content on every delta.
    func scrollToEnd() {
        guard let scroll = scrollView, let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let y = document.isFlipped ? max(document.bounds.minY, document.bounds.maxY - clip.bounds.height) : document.bounds.minY
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            scroll.reflectScrolledClipView(clip)
        }
    }

    /// Track wheel and momentum events before AppKit moves the viewport. A short
    /// quiet interval covers both legacy wheels and the finger-to-momentum gap.
    func receivedWheelEvent() {
        wheelActive = true
        cancelScroll()
        wheelIdleTask?.cancel()
        wheelIdleTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self else { return }
            self.wheelActive = false; self.wheelIdleTask = nil
            self.userDidScroll()
        }
    }

    private func requestScroll(force: Bool = false) {
        guard isFollowing, !suspended else { return }
        needsScroll = true
        forceScroll = forceScroll || force
        scheduleScroll()
    }

    private func setFollowing(_ value: Bool) {
        if isFollowing != value { isFollowing = value }
        if !value { cancelScroll(); needsScroll = false; forceScroll = false }
    }

    private func cancelScroll() { scrollTask?.cancel(); scrollTask = nil }

    @objc private func userWillScroll() {
        tracking = true
        cancelScroll()
    }
    @objc private func userDidScroll() {
        guard !suspended, let distance = distanceFromEnd else { return }
        // Legacy mouse-wheel events also arrive here without a willStart/didEnd pair.
        setFollowing(distance <= 32)
        if isFollowing { scheduleScroll() }
    }
    @objc private func userEndedScroll() {
        tracking = false
        userDidScroll()
    }
    @objc private func layoutChanged() {
        guard let scroll = scrollView else { return }
        let documentSize = scroll.documentView?.frame.size
        let viewportSize = scroll.contentView.bounds.size
        guard documentSize != observedDocumentSize || viewportSize != observedViewportSize else { return }
        observedDocumentSize = documentSize
        observedViewportSize = viewportSize
        requestScroll()
    }

    private var distanceFromEnd: CGFloat? {
        guard let scroll = scrollView, let document = scroll.documentView else { return nil }
        let visible = scroll.documentVisibleRect
        return max(0, document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY)
    }

    private func scheduleScroll() {
        guard needsScroll, isFollowing, !suspended, !tracking, !wheelActive, scrollTask == nil, scrollView != nil else { return }
        // Defer/coalesce scrolling beyond SwiftUI's current layout transaction.
        scrollTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard let self else { return }
            self.scrollTask = nil
            guard self.isFollowing, !self.suspended, !self.tracking, !self.wheelActive else { return }
            let force = self.forceScroll
            self.needsScroll = false
            self.forceScroll = false
            // At/past the end, let AppKit finish its elastic bounce untouched.
            guard force || (self.distanceFromEnd ?? 0) > 1 else { return }
            self.performScrollToEnd?()
        }
    }

    deinit {
        scrollTask?.cancel(); wheelIdleTask?.cancel()
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        NotificationCenter.default.removeObserver(self)
    }
}

/// Observes the enclosing native scroll view without replacing SwiftUI's transcript,
/// search targets or selection handling. Configuration is deferred so
/// native view updates never synchronously publish SwiftUI state.
struct TranscriptScrollProbe: NSViewRepresentable {
    let controller: TranscriptScrollController
    let threadID: UUID
    let suspended: Bool
    let searching: Bool
    let scrollToEnd: () -> Void

    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) {
        view.controller = controller
        view.threadID = threadID
        view.suspended = suspended
        view.searching = searching
        view.scrollToEnd = scrollToEnd
        view.scheduleConnection()
    }
    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        view.controller?.disconnect()
        view.controller = nil
        view.scrollToEnd = nil
    }

    final class ProbeView: NSView {
        weak var controller: TranscriptScrollController?
        var threadID: UUID?
        var suspended = false
        var searching = false
        var scrollToEnd: (() -> Void)?
        private var connectionScheduled = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleConnection() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleConnection() }
        func scheduleConnection() {
            guard !connectionScheduled else { return }
            connectionScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.connectionScheduled = false
                guard self.window != nil, let scroll = self.enclosingScrollView, let threadID = self.threadID, let scrollToEnd = self.scrollToEnd else { return }
                self.controller?.connect(scroll, threadID: threadID, suspended: self.suspended, searching: self.searching, scrollToEnd: scrollToEnd)
            }
        }
    }
}

struct TranscriptHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
