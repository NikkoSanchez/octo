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
    private var scrollTask: Task<Void, Never>?
    private var scrollToEnd: (() -> Void)?

    func connect(_ scroll: NSScrollView, threadID: UUID, suspended: Bool, searching: Bool, scrollToEnd: @escaping () -> Void) {
        if scrollView !== scroll {
            disconnect()
            scrollView = scroll
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
        self.scrollToEnd = scrollToEnd
        if self.threadID != threadID {
            cancelScroll()
            self.threadID = threadID
            tracking = false
            setFollowing(true)
        }
        self.suspended = suspended || searching
        if searching { setFollowing(false) }
        if self.suspended { cancelScroll() }
        else { scheduleScroll() }
    }

    func disconnect() {
        cancelScroll()
        NotificationCenter.default.removeObserver(self)
        scrollView = nil
        scrollToEnd = nil
        tracking = false
    }

    func resumeFollowing() {
        setFollowing(true)
        scheduleScroll()
    }

    func contentChanged() { scheduleScroll() }

    private func setFollowing(_ value: Bool) {
        if isFollowing != value { isFollowing = value }
        if !value { cancelScroll() }
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
    @objc private func layoutChanged() { scheduleScroll() }

    private var distanceFromEnd: CGFloat? {
        guard let scroll = scrollView, let document = scroll.documentView else { return nil }
        let visible = scroll.documentVisibleRect
        return max(0, document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY)
    }

    private func scheduleScroll() {
        guard isFollowing, !suspended, !tracking, scrollTask == nil, scrollView != nil else { return }
        // Defer/coalesce scrolling beyond SwiftUI's current layout transaction.
        scrollTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            guard let self else { return }
            self.scrollTask = nil
            guard self.isFollowing, !self.suspended, !self.tracking else { return }
            // SwiftUI must own the jump so LazyVStack realizes its bottom target.
            self.scrollToEnd?()
        }
    }

    deinit { scrollTask?.cancel(); NotificationCenter.default.removeObserver(self) }
}

/// Observes the enclosing native scroll view without replacing SwiftUI's transcript,
/// search targets, selection handling or lazy layout. Configuration is deferred so
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
