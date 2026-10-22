import AppKit
import SwiftUI
import OctoCore

/// An index action on the hovered hunk, such as Stage Hunk. `title` names it for a file's section,
/// or returns nil where that file's hunks can't be staged on their own. `perform` receives the
/// file's snapshot and the hunk header's `DiffLine.id`.
public struct HunkAction {
    public var enabled: Bool
    public var title: (ReviewSnapshot) -> String?
    public var perform: (ReviewSnapshot, Int) -> Void
    public init(enabled: Bool = true, title: @escaping (ReviewSnapshot) -> String?, perform: @escaping (ReviewSnapshot, Int) -> Void) {
        self.enabled = enabled; self.title = title; self.perform = perform
    }
    /// One file: the same title on every hunk.
    public init(title: String, enabled: Bool = true, perform: @escaping (Int) -> Void) {
        self.init(enabled: enabled, title: { _ in title }, perform: { perform($1) })
    }
}

/// One native text system owns selection and scrolling. SwiftUI never renders a row per line.
/// Given `files`, it shows every file in one continuous document under title rows.
public struct NativeDiffView: NSViewRepresentable {
    public var theme: AppTheme
    public var focusRequest: Int
    public var revealLine: Int?
    public var revealRequest: Int
    public var snapshot: ReviewSnapshot
    public var files: [ReviewSnapshot]?
    /// Scrolls the given file's title row to the top whenever the request count changes.
    public var revealFile: Int?
    public var revealFileRequest = 0
    /// Reports the file at the top of the viewport as the user scrolls.
    public var onVisibleFile: ((Int) -> Void)?
    public var onSelection: (CodeAttachment?) -> Void
    public var onAskAgent: (CodeAttachment) -> Void
    public var hunkAction: HunkAction?
    public init(snapshot: ReviewSnapshot, theme: AppTheme = .system, focusRequest: Int = 0, revealLine: Int? = nil, revealRequest: Int = 0, hunkAction: HunkAction? = nil, onSelection: @escaping (CodeAttachment?) -> Void, onAskAgent: @escaping (CodeAttachment) -> Void) {
        self.theme = theme; self.focusRequest = focusRequest; self.snapshot = snapshot; self.onSelection = onSelection; self.onAskAgent = onAskAgent
        self.revealLine = revealLine; self.revealRequest = revealRequest; self.hunkAction = hunkAction
    }
    public init(files: [ReviewSnapshot], theme: AppTheme = .system, focusRequest: Int = 0, revealFile: Int? = nil, revealFileRequest: Int = 0,
                hunkAction: HunkAction? = nil, onVisibleFile: ((Int) -> Void)? = nil,
                onSelection: @escaping (CodeAttachment?) -> Void, onAskAgent: @escaping (CodeAttachment) -> Void) {
        self.init(snapshot: files.first ?? ReviewSnapshot(projectID: UUID(), workingDirectory: "", path: "", scope: .working, baseRevision: "", lines: []),
                  theme: theme, focusRequest: focusRequest, hunkAction: hunkAction, onSelection: onSelection, onAskAgent: onAskAgent)
        self.files = files; self.revealFile = revealFile; self.revealFileRequest = revealFileRequest; self.onVisibleFile = onVisibleFile
    }
    /// Cheap identity: snapshot IDs already hash their content.
    var documentKey: String { files.map { "files:" + $0.map(\.id).joined(separator: ":") } ?? snapshot.id }
    public func makeCoordinator() -> Coordinator { Coordinator(self) }
    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = Self.makeScrollView()
        let text = scroll.documentView as! ReviewTextView
        text.delegate = context.coordinator
        text.askAgent = { [weak coordinator = context.coordinator] in coordinator?.ask() }
        text.attachRange = { [weak coordinator = context.coordinator] range in coordinator?.attach(range) }
        text.onScroll = { [weak coordinator = context.coordinator] in coordinator?.reportVisibleFile() }
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
        text.hunkAction = hunkAction
        coordinator.updatingView = true
        defer { coordinator.updatingView = false; coordinator.scheduleSelection() }
        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { text.window?.makeFirstResponder(text) }
        }
        let key = documentKey, changedSnapshot = coordinator.documentKey != key
        defer {
            if files != nil, coordinator.revealFileRequest != revealFileRequest {
                coordinator.revealFileRequest = revealFileRequest
                if let revealFile {
                    coordinator.lastVisibleFile = revealFile
                    // After any text replacement above has been laid out.
                    DispatchQueue.main.async { [weak text] in text?.reveal(file: revealFile) }
                }
            }
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
        // Refreshing every file (after staging, say) keeps the reader's place in the same file.
        let anchor = changedSnapshot && files != nil ? text.scrollAnchor() : nil
        let document = files.map(ReviewDocument.init(files:)) ?? ReviewDocument(snapshot: snapshot)
        coordinator.document = document; coordinator.documentKey = key; coordinator.theme = theme
        text.reviewDocument = document
        Self.applyTheme(theme, to: text)
        text.textStorage?.setAttributedString(Self.render(document, theme: theme))
        if changedSnapshot && files != nil {
            text.setSelectedRange(NSRange(location: 0, length: 0))
            text.restore(anchor)
        } else if changedSnapshot { text.setSelectedRange(NSRange(location: 0, length: 0)); text.scrollToBeginningOfDocument(nil) }
        else { text.setSelectedRange(selection) }
        // Header rows have frames once TextKit lays out the new text.
        DispatchQueue.main.async { [weak text] in text?.layoutHunkButtons() }
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
        // File title rows: the path in semibold, its scope dimmed, with room above.
        for (index, file) in document.files.enumerated() {
            guard let header = file.headerRange else { continue }
            let style = NSMutableParagraphStyle(); style.lineSpacing = 3
            style.paragraphSpacingBefore = index == 0 ? 2 : 10; style.paragraphSpacing = 6
            result.addAttributes([.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .paragraphStyle: style,
                                  .foregroundColor: color(theme.palette?.text, fallback: .labelColor)], range: header)
            let separator = (document.text as NSString).range(of: "  ·  ", options: .backwards, range: header)
            if separator.location != NSNotFound {
                result.addAttributes([.font: NSFont.systemFont(ofSize: 12, weight: .regular),
                                      .foregroundColor: color(theme.palette?.overlay1, fallback: .secondaryLabelColor)],
                                     range: NSRange(location: separator.location, length: NSMaxRange(header) - separator.location))
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
        var documentKey: String?
        var revealFileRequest = 0
        var lastVisibleFile: Int?
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
        /// Scrolls made by the view itself (reveal, restore) are not the reader moving on.
        func reportVisibleFile() {
            guard parent.files != nil, let textView, !textView.scrollingProgrammatically, let file = textView.topVisibleFile(),
                  file != lastVisibleFile else { return }
            lastVisibleFile = file
            let key = documentKey
            DispatchQueue.main.async { [weak self] in
                guard let self, self.documentKey == key, self.lastVisibleFile == file else { return }
                self.parent.onVisibleFile?(file)
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
    var reviewDocument: ReviewDocument? { didSet { clearHover(); hoveredHunk = nil } }
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
        clip.postsBoundsChangedNotifications = true; clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(viewportResized), name: NSView.frameDidChangeNotification, object: clip)
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
    override func mouseExited(with event: NSEvent) { hoverPoint = nil; clearHover(); hoverHunk(nil) }
    private func trackHover(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoverPoint = point
        updateHover()
        hoverHunk(hunkHeader(at: point))
    }
    @objc private func viewportChanged() {
        clearHover(); enclosingScrollView?.verticalRulerView?.needsDisplay = true; layoutHunkButtons()
        onScroll?()
    }
    @objc private func viewportResized() { layoutHunkButtons() }

    // MARK: Multi-file scrolling

    var onScroll: (() -> Void)?
    /// True while the view moves itself, so the move is not reported as the reader's.
    private(set) var scrollingProgrammatically = false
    struct ScrollAnchor { var path: String; var scope: DiffScope; var offset: CGFloat }
    /// The file whose section is at the top of the viewport.
    func topVisibleFile() -> Int? {
        guard let document = reviewDocument, !document.files.isEmpty, let layout = textLayoutManager, let content = layout.textContentManager else { return nil }
        let y = max(0, visibleRect.minY - textContainerOrigin.y + 1)
        guard let fragment = layout.textLayoutFragment(for: CGPoint(x: 0, y: y)) else { return 0 }
        let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        return document.file(atUTF16Offset: offset) ?? 0
    }
    /// The top of a file's section (its title row), laying out the text up to it if needed.
    private func sectionTop(_ file: Int) -> CGFloat? {
        guard let document = reviewDocument, document.files.indices.contains(file),
              let layout = textLayoutManager, let content = layout.textContentManager else { return nil }
        let section = document.files[file]
        guard let location = content.location(content.documentRange.location, offsetBy: section.headerRange?.location ?? section.range.location) else { return nil }
        // Positions are only exact once everything above is laid out; otherwise TextKit estimates them.
        if let range = NSTextRange(location: content.documentRange.location, end: location) { layout.ensureLayout(for: range) }
        return layout.textLayoutFragment(for: location).map { $0.layoutFragmentFrame.minY + textContainerOrigin.y }
    }
    private func scroll(toY y: CGFloat) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        scrollingProgrammatically = true
        defer { scrollingProgrammatically = false }
        // The document can be shorter than the target: the last files cannot reach the top.
        let target = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: clip.bounds.minX, y: max(0, y)), size: clip.bounds.size))
        clip.scroll(to: target.origin)
        scroll.reflectScrolledClipView(clip)
    }
    func scrollAnchor() -> ScrollAnchor? {
        guard let document = reviewDocument, document.isMultiFile, let file = topVisibleFile(), let top = sectionTop(file) else { return nil }
        let snapshot = document.files[file].snapshot
        return ScrollAnchor(path: snapshot.path, scope: snapshot.scope, offset: visibleRect.minY - top)
    }
    /// After the files change, returns to the same place in the same file, or to the top if it is gone.
    func restore(_ anchor: ScrollAnchor?) {
        guard let anchor, let document = reviewDocument,
              let file = document.files.firstIndex(where: { $0.snapshot.path == anchor.path && $0.snapshot.scope == anchor.scope }),
              let top = sectionTop(file) else { scroll(toY: 0); return }
        scroll(toY: top + anchor.offset)
    }
    func reveal(file: Int) {
        guard let top = sectionTop(file) else { return }
        scroll(toY: top - 4)
    }

    // MARK: Hunk actions

    var hunkAction: HunkAction? { didSet { layoutHunkButtons() } }
    /// The segment index of the hovered hunk's `@@` header. Like the gutter +, the action appears
    /// only while a hunk is hovered.
    var hoveredHunk: Int? { didSet { if hoveredHunk != oldValue { layoutHunkButtons() } } }
    /// Side by side: the Before pane reports its hovered hunk's header line ID so the After pane,
    /// whose rows are padded differently, can show the action.
    var onHoveredHunk: ((Int?) -> Void)?
    private func hoverHunk(_ index: Int?) {
        if hunkAction != nil { hoveredHunk = index }
        onHoveredHunk?(index.flatMap { reviewDocument?.segments[$0].line.id })
    }
    func hoverHunk(lineID: Int?) {
        hoveredHunk = lineID.flatMap { id in reviewDocument?.segments.firstIndex { $0.line.id == id && $0.line.kind == .header && $0.line.text.hasPrefix("@@") } }
    }
    private lazy var hunkButton: NSButton = {
        let button = NSButton(title: "", target: self, action: #selector(performHunkButton(_:)))
        button.isBordered = false; button.wantsLayer = true
        button.layer?.cornerCurve = .continuous
        button.isHidden = true
        addSubview(button)
        return button
    }()
    private static func isHunkHeader(_ segment: ReviewDocument.Segment) -> Bool { segment.line.kind == .header && segment.line.text.hasPrefix("@@") }
    /// A capsule on the hovered hunk's `@@` row, styled like the panel's Push and Open in capsules.
    /// When the header has scrolled away it stays at the top of the hunk's visible part.
    func layoutHunkButtons() {
        guard let action = hunkAction, let start = hoveredHunk, let document = reviewDocument, sourceDocument == nil,
              document.segments.indices.contains(start), Self.isHunkHeader(document.segments[start]),
              let title = action.title(document.files[document.segments[start].file].snapshot),
              let layout = textLayoutManager, let content = layout.textContentManager else {
            if !hunkButton.isHidden { hunkButton.isHidden = true }
            return
        }
        let visible = visibleRect, origin = textContainerOrigin, file = document.segments[start].file
        func row(_ segment: ReviewDocument.Segment) -> NSRect? {
            guard let location = content.location(content.documentRange.location, offsetBy: segment.displayRange.location),
                  let fragment = layout.textLayoutFragment(for: location) else { return nil }
            return fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
        }
        // The hunk ends before the next hunk or the next file.
        let end = document.segments[(start + 1)...].firstIndex { Self.isHunkHeader($0) || $0.file != file }
            .map { $0 - 1 } ?? document.segments.count - 1
        let header = row(document.segments[start]), last = row(document.segments[end])

        let label = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NativeDiffView.color(theme.palette?.text, fallback: .labelColor)
        ])
        hunkButton.title = title; hunkButton.attributedTitle = label
        hunkButton.isEnabled = action.enabled; hunkButton.alphaValue = action.enabled ? 1 : 0.45
        hunkButton.tag = start
        hunkButton.layer?.backgroundColor = NativeDiffView.color(theme.palette?.surface, fallback: .quaternaryLabelColor).cgColor
        let text = document.segments[start].line.text, path = document.files[file].snapshot.path
        hunkButton.toolTip = "\(title): \(text)"
        hunkButton.setAccessibilityLabel("\(title) \(text) in \(path)")
        let size = NSSize(width: ceil(label.size().width) + 20, height: 22)
        hunkButton.layer?.cornerRadius = size.height / 2
        var y = max(header.map { $0.midY - size.height / 2 } ?? visible.minY + 4, visible.minY + 4)
        if let last { y = min(y, last.maxY - size.height) }
        hunkButton.frame = NSRect(x: max(visible.minX, visible.maxX - size.width - 12), y: y, width: size.width, height: size.height)
        hunkButton.isHidden = false
    }
    /// The button's and menu item's tag is the header's segment index.
    @objc private func performHunkButton(_ sender: Any?) {
        guard let index = (sender as? NSButton)?.tag ?? (sender as? NSMenuItem)?.tag, let document = reviewDocument,
              document.segments.indices.contains(index) else { return }
        let segment = document.segments[index]
        hunkAction?.perform(document.files[segment.file].snapshot, segment.line.id)
    }
    /// The `@@` header segment of the hunk containing a point, within that point's file.
    private func hunkHeader(at point: NSPoint) -> Int? {
        guard let document = reviewDocument else { return nil }
        return document.hunkHeader(atUTF16Offset: characterIndexForInsertion(at: CGPoint(x: textContainerOrigin.x + 6, y: point.y)))
    }

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
        if let action = hunkAction, action.enabled, sourceDocument == nil, let document = reviewDocument,
           let index = hunkHeader(at: convert(event.locationInWindow, from: nil)),
           let title = action.title(document.files[document.segments[index].file].snapshot) {
            let item = NSMenuItem(title: title, action: #selector(performHunkButton(_:)), keyEquivalent: "")
            item.target = self; item.tag = index
            menu.insertItem(.separator(), at: 0); menu.insertItem(item, at: 0)
        }
        if selectedRange().length > 0 {
            let item = NSMenuItem(title: "Ask Agent About Selection", action: #selector(ask), keyEquivalent: "")
            item.target = self; menu.insertItem(.separator(), at: 0); menu.insertItem(item, at: 0)
        }
        return menu
    }
    @objc private func ask() { askAgent?() }
}
