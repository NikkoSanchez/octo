import AppKit
import SwiftUI
import OctoCore

/// One native text system owns selection and scrolling. SwiftUI never renders a row per line.
public struct NativeDiffView: NSViewRepresentable {
    public var theme: AppTheme
    public var focusRequest: Int
    public var revealLine: Int?
    public var revealRequest: Int
    public var snapshot: ReviewSnapshot
    public var onSelection: (CodeAttachment?) -> Void
    public var onAskAgent: (CodeAttachment) -> Void
    public init(snapshot: ReviewSnapshot, theme: AppTheme = .system, focusRequest: Int = 0, revealLine: Int? = nil, revealRequest: Int = 0, onSelection: @escaping (CodeAttachment?) -> Void, onAskAgent: @escaping (CodeAttachment) -> Void) {
        self.theme = theme; self.focusRequest = focusRequest; self.snapshot = snapshot; self.onSelection = onSelection; self.onAskAgent = onAskAgent
        self.revealLine = revealLine; self.revealRequest = revealRequest
    }
    public func makeCoordinator() -> Coordinator { Coordinator(self) }
    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = Self.makeScrollView()
        let text = scroll.documentView as! ReviewTextView
        text.delegate = context.coordinator
        text.askAgent = { [weak coordinator = context.coordinator] in coordinator?.ask() }
        text.attachRange = { [weak coordinator = context.coordinator] range in coordinator?.attach(range) }
        context.coordinator.textView = text
        updateNSView(scroll, context: context)
        return scroll
    }
    static func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        let text = ReviewTextView(usingTextLayoutManager: true)
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        text.backgroundColor = .textBackgroundColor; text.drawsBackground = true
        text.textContainerInset = NSSize(width: 36, height: 12)
        text.isHorizontallyResizable = true; text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude)
        text.setAccessibilityLabel("Code changes. Hover a line to attach it with the plus button, or select code and choose Ask Agent.")
        scroll.documentView = text
        text.observeScrolling()
        return scroll
    }
    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator; coordinator.parent = self
        guard let text = coordinator.textView else { return }
        coordinator.updatingView = true
        defer { coordinator.updatingView = false; coordinator.scheduleSelection() }
        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { text.window?.makeFirstResponder(text) }
        }
        let changedSnapshot = coordinator.document?.snapshot.id != snapshot.id
        defer {
            if coordinator.revealRequest != revealRequest {
                coordinator.revealRequest = revealRequest
                if let line = revealLine, let segment = coordinator.document?.segments.first(where: { $0.line.newLine == line }) {
                    text.setSelectedRange(segment.contentRange)
                    text.scrollRangeToVisible(segment.contentRange)
                }
            }
        }
        guard changedSnapshot || coordinator.theme != theme else { return }
        let selection = text.selectedRange()
        let document = ReviewDocument(snapshot: snapshot); coordinator.document = document; coordinator.theme = theme
        text.reviewDocument = document
        Self.applyTheme(theme, to: text)
        text.textStorage?.setAttributedString(Self.render(document, theme: theme))
        if changedSnapshot { text.setSelectedRange(NSRange(location: 0, length: 0)); text.scrollToBeginningOfDocument(nil) }
        else { text.setSelectedRange(selection) }
    }
    static func applyTheme(_ theme: AppTheme, to text: ReviewTextView) {
        text.theme = theme
        text.backgroundColor = color(theme.palette?.base, fallback: .textBackgroundColor)
        text.insertionPointColor = color(theme.palette?.cursor, fallback: .labelColor)
        let selectionColor = theme.palette.map { color($0.selectionBackground, fallback: .selectedTextBackgroundColor).withAlphaComponent($0.selectionOpacity) } ?? .selectedTextBackgroundColor
        text.selectedTextAttributes = [.backgroundColor: selectionColor, .foregroundColor: color(theme.palette?.text, fallback: .selectedTextColor)]
    }
    public static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.textView?.delegate = nil
        coordinator.textView = nil
    }
    static func color(_ hex: String?, fallback: NSColor) -> NSColor {
        guard let hex, let value = UInt32(hex, radix: 16) else { return fallback }
        return NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
    }
    static func render(_ document: ReviewDocument, theme: AppTheme) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3
        if document.side != nil {
            // Equal paragraph height keeps Unicode, empty rows and fallback fonts aligned.
            paragraph.minimumLineHeight = 22; paragraph.maximumLineHeight = 22; paragraph.lineSpacing = 0
        }
        let result = NSMutableAttributedString(string: document.text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: color(theme.palette?.text, fallback: .labelColor), .paragraphStyle: paragraph
        ])
        for segment in document.segments {
            let full = (document.text as NSString).lineRange(for: segment.contentRange)
            let background: NSColor?
            switch segment.line.kind {
            case .addition: background = color(theme.palette?.green, fallback: .systemGreen).withAlphaComponent(theme.palette?.diffLineOpacity ?? 0.20)
            case .deletion: background = color(theme.palette?.red, fallback: .systemRed).withAlphaComponent(theme.palette?.diffLineOpacity ?? 0.20)
            case .header: background = color(theme.palette?.surface, fallback: .quaternaryLabelColor).withAlphaComponent(0.25)
            case .context: background = nil
            }
            if let background { result.addAttribute(.backgroundColor, value: background, range: full) }
            let gutter = NSRange(location: full.location, length: max(0, segment.contentRange.location - full.location))
            result.addAttribute(.foregroundColor, value: color(theme.palette?.overlay1, fallback: .secondaryLabelColor), range: gutter)
            if segment.line.kind == .header {
                let line = segment.line.text
                let syntax = theme.syntax
                let hex = line.hasPrefix("@@") ? syntax?.hunk : line.hasPrefix("diff ") ? syntax?.diffFile : (line.hasPrefix("---") || line.hasPrefix("+++")) ? syntax?.diffPath : syntax?.comment
                result.addAttribute(.foregroundColor, value: color(hex, fallback: .secondaryLabelColor), range: segment.contentRange)
            }
        }
        ReviewSyntax.apply(to: result, document: document, theme: theme)
        return result
    }
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var theme: AppTheme?
        var focusRequest = 0
        var revealRequest = 0
        var parent: NativeDiffView
        var document: ReviewDocument?
        weak var textView: ReviewTextView?
        var updatingView = false
        private var selectionGeneration = 0
        private var selectionKey: String?
        init(_ parent: NativeDiffView) { self.parent = parent }
        public func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            if !updatingView { scheduleSelection() }
            textView.updateHover()
        }
        func scheduleSelection() {
            guard let textView, let document else { return }
            let range = textView.selectedRange(), snapshotID = document.snapshot.id
            let key = "\(snapshotID):\(range.location):\(range.length)"
            guard selectionKey != key else { return }
            selectionKey = key; selectionGeneration += 1
            let generation = selectionGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectionGeneration == generation,
                      self.document?.snapshot.id == snapshotID,
                      self.textView?.selectedRange() == range else { return }
                self.parent.onSelection(self.document?.attachment(for: range))
            }
        }
        func ask() {
            guard let textView, let attachment = document?.attachment(for: textView.selectedRange()) else { return }
            parent.onAskAgent(attachment)
        }
        func attach(_ range: NSRange) {
            guard let attachment = document?.attachment(for: range) else { return }
            textView?.setSelectedRange(range)
            parent.onAskAgent(attachment)
        }
    }
}
final class ReviewTextView: NSTextView {
    // Split review fixes document geometry independently of AppKit's viewport
    // resizing. Ordinary stacked review and the file editor leave this at zero.
    var minimumReviewSize: NSSize = .zero
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(NSSize(width: max(newSize.width, minimumReviewSize.width),
                                  height: max(newSize.height, minimumReviewSize.height)))
    }
    var fileUndoManager: UndoManager?
    private var fileFocusPending = false
    override var undoManager: UndoManager? { fileUndoManager ?? super.undoManager }
    @objc func undo(_ sender: Any?) { undoManager?.undo() }
    @objc func redo(_ sender: Any?) { undoManager?.redo() }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return undoManager?.canUndo == true }
        if item.action == #selector(redo(_:)) { return undoManager?.canRedo == true }
        return super.validateUserInterfaceItem(item)
    }
    var theme: AppTheme = .system {
        didSet {
            attachButton.contentTintColor = NativeDiffView.color(theme.palette?.onAccent, fallback: .white)
            attachButton.layer?.backgroundColor = NativeDiffView.color(theme.palette?.accent, fallback: .controlAccentColor).cgColor
            needsDisplay = true
        }
    }
    var askAgent: (() -> Void)?
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
    var attachRange: ((NSRange) -> Void)?
    var reviewDocument: ReviewDocument? { didSet { clearHover() } }
    var sourceDocument: SourceDocument? { didSet { clearHover(); enclosingScrollView?.verticalRulerView?.needsDisplay = true } }
    private var hoverTracking: NSTrackingArea?
    private var hoverPoint: NSPoint?
    private var hoveredRange: NSRange?
    private var hoveredLineRect: NSRect?
    private lazy var attachButton: NSButton = {
        let button = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Attach code to draft")!, target: self, action: #selector(attachHoveredLine))
        button.isBordered = false
        button.bezelStyle = .smallSquare
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        button.layer?.cornerRadius = 4
        button.isHidden = true
        addSubview(button)
        return button
    }()

    func observeScrolling() {
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification, object: clip)
    }
    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        if fileFocusPending { requestFileFocus() }
    }
    func requestFileFocus() {
        fileFocusPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            self.fileFocusPending = false
            guard window.attachedSheet == nil else { return }
            window.makeFirstResponder(self)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverTracking = area
    }
    override func mouseEntered(with event: NSEvent) { trackHover(event) }
    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event); trackHover(event) }
    override func mouseDown(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
        updateHover()
    }
    override func mouseExited(with event: NSEvent) { hoverPoint = nil; clearHover() }
    private func trackHover(_ event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        updateHover()
    }
    @objc private func viewportChanged() { clearHover(); enclosingScrollView?.verticalRulerView?.needsDisplay = true }

    func updateHover() {
        guard let point = hoverPoint,
              let layout = textLayoutManager, let content = layout.textContentManager else { clearHover(); return }
        guard visibleRect.contains(point) else { clearHover(); return }
        // Each unwrapped source line is one TextKit 2 paragraph. Resolve vertically so
        // hovering trailing whitespace or the action gutter still targets the same line.
        let offset = characterIndexForInsertion(at: CGPoint(x: textContainerOrigin.x + 6, y: point.y))
        guard let location = content.location(content.documentRange.location, offsetBy: offset),
              let fragment = layout.textLayoutFragment(for: location) else { clearHover(); return }
        let frame = fragment.layoutFragmentFrame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        guard point.y >= frame.minY, point.y < frame.maxY else { clearHover(); return }
        guard let range = sourceDocument?.attachmentRange(forLineAtUTF16Offset: offset, selection: selectedRange())
            ?? reviewDocument?.attachmentRange(forLineAtUTF16Offset: offset, selection: selectedRange()), range.length > 0 else { clearHover(); return }
        hoveredRange = range
        hoveredLineRect = NSRect(x: visibleRect.minX, y: frame.minY, width: visibleRect.width, height: frame.height)
        let size: CGFloat = min(20, frame.height)
        attachButton.frame = NSRect(x: visibleRect.minX + 6, y: frame.minY, width: size, height: size)
        let selected = range == selectedRange()
        attachButton.toolTip = selected ? "Attach selection to draft" : "Attach line to draft"
        attachButton.setAccessibilityLabel(selected ? "Attach selection to draft" : "Attach line to draft")
        attachButton.isHidden = false
        needsDisplay = true
    }

    private func clearHover() {
        hoveredRange = nil; hoveredLineRect = nil
        attachButton.isHidden = true
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let hoveredLineRect {
            NativeDiffView.color(theme.palette?.lineHighlight, fallback: .labelColor)
                .withAlphaComponent(theme.palette?.lineHighlightOpacity ?? 0.10).setFill()
            hoveredLineRect.intersection(dirtyRect).fill()
        }
    }
    @objc private func attachHoveredLine() {
        guard let hoveredRange else { return }
        attachRange?(hoveredRange)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if selectedRange().length > 0 {
            let item = NSMenuItem(title: "Ask Agent About Selection", action: #selector(ask), keyEquivalent: "")
            item.target = self; menu.insertItem(.separator(), at: 0); menu.insertItem(item, at: 0)
        }
        return menu
    }
    @objc private func ask() { askAgent?() }
}
