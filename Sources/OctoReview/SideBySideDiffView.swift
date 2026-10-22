import AppKit
import SwiftUI
import OctoCore

/// Two native text systems share aligned source rows and vertical scrolling.
public struct SideBySideDiffView: NSViewRepresentable {
    public var snapshot: ReviewSnapshot
    public var theme: AppTheme
    public var focusRequest: Int
    public var onSelection: (CodeAttachment?) -> Void
    public var onAskAgent: (CodeAttachment) -> Void
    /// Shown on the After pane's hunk headers.
    public var hunkAction: HunkAction?

    public init(snapshot: ReviewSnapshot, theme: AppTheme = .system, focusRequest: Int = 0, hunkAction: HunkAction? = nil,
                onSelection: @escaping (CodeAttachment?) -> Void, onAskAgent: @escaping (CodeAttachment) -> Void) {
        self.snapshot = snapshot; self.theme = theme; self.focusRequest = focusRequest; self.hunkAction = hunkAction
        self.onSelection = onSelection; self.onAskAgent = onAskAgent
    }
    public func makeNSView(context: Context) -> SideBySideReviewView {
        let view = SideBySideReviewView()
        updateNSView(view, context: context)
        return view
    }
    public func updateNSView(_ view: SideBySideReviewView, context: Context) {
        view.onSelection = onSelection; view.onAskAgent = onAskAgent
        view.texts[1].hunkAction = hunkAction
        view.update(snapshot: snapshot, theme: theme, focusRequest: focusRequest)
    }
    public static func dismantleNSView(_ view: SideBySideReviewView, coordinator: ()) {
        view.invalidate()
    }
}

public final class SideBySideReviewView: NSView, NSTextViewDelegate {
    let scrolls = [NativeDiffView.makeScrollView(), NativeDiffView.makeScrollView()]
    private let labels = [NSTextField(labelWithString: ""), NSTextField(labelWithString: "")]
    var texts: [ReviewTextView] { scrolls.map { $0.documentView as! ReviewTextView } }
    private(set) var documents: [ReviewDocument] = []
    private var theme: AppTheme?
    private var focusRequest = 0
    private var activePane = 1
    private var updating = false
    private var syncingScroll = false
    private var selectionGeneration = 0
    private var selectionKey: String?
    private var contentWidths: [CGFloat] = [0, 0]
    var onSelection: ((CodeAttachment?) -> Void)?
    var onAskAgent: ((CodeAttachment) -> Void)?
    public override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for index in 0...1 {
            let scroll = scrolls[index], text = texts[index], label = labels[index]
            // Both panes reserve identical scroller space, including when only one
            // has long lines. Horizontal scrolling remains independent.
            scroll.autohidesScrollers = false
            scroll.horizontalScrollElasticity = .none; scroll.verticalScrollElasticity = .none
            text.textContainerInset = NSSize(width: 30, height: 12)
            text.autoresizingMask = []
            text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.delegate = self
            text.setAccessibilityLabel(index == 0 ? "Before changes" : "After changes")
            text.onFocus = { [weak self] in self?.activate(index) }
            text.askAgent = { [weak self] in
                guard let self else { return }
                self.attach(self.texts[index].selectedRange(), in: index)
            }
            text.attachRange = { [weak self] range in self?.attach(range, in: index) }
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.lineBreakMode = .byTruncatingTail
            addSubview(scroll); addSubview(label)
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)),
                name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    public override func layout() {
        super.layout()
        let half = floor((bounds.width - 1) / 2)
        for index in 0...1 {
            let x = index == 0 ? 0 : half + 1
            let width = index == 0 ? half : bounds.width - x
            labels[index].frame = NSRect(x: x + 10, y: 6, width: max(0, width - 20), height: 18)
            scrolls[index].frame = NSRect(x: x, y: 30, width: max(0, width), height: max(0, bounds.height - 30))
            texts[index].setFrameSize(NSSize(width: max(contentWidths[index], scrolls[index].contentSize.width),
                height: max(texts[index].minSize.height, scrolls[index].contentSize.height)))
        }
        synchronize(from: activePane)
    }
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NativeDiffView.color(theme?.palette?.surface, fallback: .separatorColor).setFill()
        NSRect(x: floor((bounds.width - 1) / 2), y: 0, width: 1, height: bounds.height).fill()
    }
    func update(snapshot: ReviewSnapshot, theme: AppTheme, focusRequest: Int) {
        let changed = documents.first?.snapshot.id != snapshot.id
        if changed || self.theme != theme {
            updating = true; syncingScroll = true
            let pair = ReviewDocument.sideBySide(snapshot: snapshot)
            documents = [pair.before, pair.after]; self.theme = theme
            labels[0].stringValue = snapshot.scope == .staged ? "Before · HEAD" : "Before · Index"
            labels[1].stringValue = snapshot.scope == .staged ? "After · Index" : "After · Working Tree"
            // The terminal newline has its own empty paragraph in both text views.
            let height = CGFloat(pair.before.text.filter { $0 == "\n" }.count + 1) * 22 + 24
            for index in 0...1 {
                let text = texts[index], selection = text.selectedRange(), origin = scrolls[index].contentView.bounds.origin
                text.reviewDocument = documents[index]
                NativeDiffView.applyTheme(theme, to: text)
                labels[index].textColor = NativeDiffView.color(theme.palette?.secondary, fallback: .secondaryLabelColor)
                let rendered = NativeDiffView.render(documents[index], theme: theme)
                contentWidths[index] = ceil(rendered.size().width) + text.textContainerInset.width * 2
                // NSTextView can resize itself again during window/viewport layout.
                // Keep its document width at least as wide as the longest line.
                text.minimumReviewSize = NSSize(width: contentWidths[index], height: height)
                text.minSize = text.minimumReviewSize
                text.textStorage?.setAttributedString(rendered)
                text.setSelectedRange(changed ? NSRange(location: 0, length: 0) : selection)
                text.setFrameSize(NSSize(width: max(contentWidths[index], scrolls[index].contentSize.width), height: max(height, scrolls[index].contentSize.height)))
                scrolls[index].contentView.scroll(to: changed ? .zero : origin)
                scrolls[index].reflectScrolledClipView(scrolls[index].contentView)
            }
            syncingScroll = false; updating = false
            synchronize(from: activePane); scheduleSelection(); needsDisplay = true
            DispatchQueue.main.async { [weak self] in self?.texts[1].layoutHunkButtons() }
        }
        if self.focusRequest != focusRequest {
            self.focusRequest = focusRequest
            texts[activePane].requestFileFocus()
        }
    }
    private func activate(_ pane: Int) {
        guard !updating, activePane != pane else { return }
        activePane = pane
        updating = true
        texts[1 - pane].setSelectedRange(NSRange(location: 0, length: 0))
        updating = false
        selectionKey = nil
        scheduleSelection()
    }
    public func textViewDidChangeSelection(_ notification: Notification) {
        guard !updating, let text = notification.object as? ReviewTextView,
              let index = texts.firstIndex(where: { $0 === text }) else { return }
        activate(index); scheduleSelection(); text.updateHover()
    }
    func scheduleSelection() {
        guard documents.count == 2 else { return }
        let pane = activePane, range = texts[pane].selectedRange(), snapshotID = documents[pane].snapshot.id
        let key = "\(snapshotID):\(pane):\(range.location):\(range.length)"
        guard selectionKey != key else { return }
        selectionKey = key; selectionGeneration += 1
        let generation = selectionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.selectionGeneration == generation, self.activePane == pane,
                  self.documents[pane].snapshot.id == snapshotID, self.texts[pane].selectedRange() == range else { return }
            self.onSelection?(self.documents[pane].attachment(for: range))
        }
    }
    func attach(_ range: NSRange, in pane: Int) {
        guard documents.count == 2, let attachment = documents[pane].attachment(for: range) else { return }
        activate(pane); texts[pane].setSelectedRange(range)
        onAskAgent?(attachment)
    }
    @objc private func scrolled(_ notification: Notification) {
        guard let clip = notification.object as? NSClipView,
              let index = scrolls.firstIndex(where: { $0.contentView === clip }) else { return }
        synchronize(from: index)
    }
    private func synchronize(from pane: Int) {
        guard !syncingScroll else { return }
        syncingScroll = true
        defer { syncingScroll = false }
        let other = scrolls[1 - pane], y = scrolls[pane].contentView.bounds.minY
        guard other.contentView.bounds.minY != y else { return }
        other.contentView.scroll(to: NSPoint(x: other.contentView.bounds.minX, y: y))
        other.reflectScrolledClipView(other.contentView)
    }
    func invalidate() {
        selectionGeneration += 1; onSelection = nil; onAskAgent = nil
        for text in texts { text.delegate = nil; text.onFocus = nil; text.askAgent = nil; text.attachRange = nil; text.hunkAction = nil }
        NotificationCenter.default.removeObserver(self)
    }
}
