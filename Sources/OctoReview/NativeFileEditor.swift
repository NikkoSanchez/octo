import AppKit
import SwiftUI
import OctoCore

/// One retained native editor per file and window keeps its undo stack, caret and scroll position.
@MainActor public final class NativeFileEditorState {
    fileprivate var scroll: NSScrollView?
    public init() {}
    public func clearUndoHistory() { (scroll?.documentView as? NSTextView)?.undoManager?.removeAllActions() }
}

public struct NativeFileEditor: NSViewRepresentable {
    @Binding public var text: String
    public let context: ReviewSnapshot
    public let state: NativeFileEditorState
    public var theme: AppTheme
    public var focusRequest: Int
    public var revealLine: Int?
    public var revealRequest: Int
    public var onSelection: (CodeAttachment?) -> Void
    public var onAskAgent: (CodeAttachment) -> Void
    public init(text: Binding<String>, context: ReviewSnapshot, state: NativeFileEditorState, theme: AppTheme = .system,
                focusRequest: Int = 0, revealLine: Int? = nil, revealRequest: Int = 0,
                onSelection: @escaping (CodeAttachment?) -> Void, onAskAgent: @escaping (CodeAttachment) -> Void) {
        _text = text; self.context = context; self.state = state; self.theme = theme
        self.focusRequest = focusRequest; self.revealLine = revealLine; self.revealRequest = revealRequest
        self.onSelection = onSelection; self.onAskAgent = onAskAgent
    }
    public func makeCoordinator() -> Coordinator { Coordinator(self) }
    public func makeNSView(context: Context) -> NSScrollView {
        if let scroll = state.scroll, let view = scroll.documentView as? ReviewTextView {
            connect(view, coordinator: context.coordinator)
            return scroll
        }
        let scroll = NSScrollView()
        scroll.clipsToBounds = true
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        let view = ReviewTextView(usingTextLayoutManager: true)
        view.fileUndoManager = UndoManager()
        view.isRichText = false; view.isEditable = true; view.isSelectable = true; view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false; view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false; view.isGrammarCheckingEnabled = false
        view.isAutomaticLinkDetectionEnabled = false; view.isAutomaticDataDetectionEnabled = false
        view.textContainerInset = NSSize(width: 32, height: 12)
        view.isHorizontallyResizable = true; view.isVerticallyResizable = true; view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude)
        view.setAccessibilityIdentifier("OctoFileEditor")
        view.setAccessibilityLabel("File contents")
        view.identifier = NSUserInterfaceItemIdentifier("OctoFileEditor")
        connect(view, coordinator: context.coordinator)
        scroll.documentView = view
        scroll.hasVerticalRuler = true
        let ruler = SourceLineRuler(scrollView: scroll, orientation: .verticalRuler)
        ruler.clientView = view
        scroll.verticalRulerView = ruler
        scroll.rulersVisible = true
        view.observeScrolling()
        context.coordinator.textView = view
        state.scroll = scroll
        return scroll
    }
    private func connect(_ view: ReviewTextView, coordinator: Coordinator) {
        coordinator.textView = view
        view.delegate = coordinator
        view.askAgent = { [weak coordinator] in coordinator?.ask() }
        view.attachRange = { [weak coordinator] in coordinator?.ask($0) }
    }
    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let view = coordinator.textView else { return }
        coordinator.updating = true
        defer { coordinator.updating = false; coordinator.scheduleSelection() }
        let changed = !view.string.utf8.elementsEqual(text.utf8)
        if changed && !view.hasMarkedText() {
            let selection = view.selectedRange()
            view.string = text
            view.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            view.undoManager?.removeAllActions()
        }
        if changed || coordinator.document == nil || coordinator.theme != theme || coordinator.document?.snapshot.baseRevision != self.context.baseRevision {
            coordinator.updateDocument()
        }
        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            view.requestFileFocus()
        }
        if coordinator.revealRequest != revealRequest {
            coordinator.revealRequest = revealRequest
            if let line = revealLine, let segments = coordinator.document?.segments, segments.indices.contains(line - 1) {
                let range = segments[line - 1].contentRange
                view.setSelectedRange(range); view.scrollRangeToVisible(range)
            }
        }
    }
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeFileEditor
        var theme: AppTheme?
        var updating = false
        var focusRequest: Int
        var revealRequest = 0
        weak var textView: ReviewTextView?
        var document: SourceDocument?
        private var selectionKey: String?
        private var selectionGeneration = 0
        init(_ parent: NativeFileEditor) { self.parent = parent; focusRequest = 0 }
        public func textDidChange(_ notification: Notification) {
            guard !updating, let view = textView else { return }
            parent.text = view.string
            updateDocument(); scheduleSelection()
        }
        public func textViewDidChangeSelection(_ notification: Notification) {
            if !updating { scheduleSelection() }
            textView?.updateHover()
        }
        func updateDocument() {
            guard let view = textView, !view.hasMarkedText() else { return }
            let document = SourceDocument(text: view.string, context: parent.context)
            self.document = document; theme = parent.theme
            view.sourceDocument = document; view.theme = parent.theme
            let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            let foreground = NativeDiffView.color(parent.theme.palette?.text, fallback: .textColor)
            view.backgroundColor = NativeDiffView.color(parent.theme.palette?.base, fallback: .textBackgroundColor)
            view.insertionPointColor = NativeDiffView.color(parent.theme.palette?.rosewater, fallback: .textColor)
            view.selectedTextAttributes = [.backgroundColor: parent.theme.palette.map { NativeDiffView.color($0.selectionBackground, fallback: .selectedTextBackgroundColor).withAlphaComponent($0.selectionOpacity) } ?? .selectedTextBackgroundColor]
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
            let rendered = NSMutableAttributedString(string: view.string, attributes: attributes)
            ReviewSyntax.apply(to: rendered, document: ReviewDocument(source: document), theme: parent.theme)
            // Attribute-only edits preserve native undo and exact source bytes.
            view.textStorage?.beginEditing()
            rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attrs, range, _ in
                view.textStorage?.setAttributes(attrs, range: range)
            }
            view.textStorage?.endEditing()
            view.font = font
            view.typingAttributes = attributes
        }
        func scheduleSelection() {
            guard let view = textView, let document else { return }
            let range = view.selectedRange(), id = document.snapshot.id
            let key = "\(id):\(range.location):\(range.length)"
            guard selectionKey != key else { return }
            selectionKey = key; selectionGeneration += 1
            let generation = selectionGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectionGeneration == generation, self.document?.snapshot.id == id,
                      self.textView?.selectedRange() == range, self.textView?.window != nil else { return }
                self.parent.onSelection(self.document?.attachment(for: range))
            }
        }
        func ask(_ range: NSRange? = nil) {
            guard let view = textView, let attachment = document?.attachment(for: range ?? view.selectedRange()) else { return }
            if let range { view.setSelectedRange(range) }
            parent.onAskAgent(attachment)
        }
    }
}

/// A separate ruler keeps line numbers fixed while source scrolls horizontally.
final class SourceLineRuler: NSRulerView {
    override var isFlipped: Bool { true }
    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        clipsToBounds = true
        ruleThickness = 44
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let view = scrollView?.documentView as? ReviewTextView else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        view.backgroundColor.setFill(); bounds.intersection(rect).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NativeDiffView.color(view.theme.palette?.overlay1, fallback: .secondaryLabelColor)
        ]
        for (number, frame) in Self.lines(in: view) {
            let position = convert(frame, from: view)
            let label = String(number) as NSString
            label.draw(at: NSPoint(x: ruleThickness - 8 - label.size(withAttributes: attributes).width, y: position.minY + 1), withAttributes: attributes)
        }
    }
    static func lines(in view: ReviewTextView) -> [(Int, NSRect)] {
        guard let document = view.sourceDocument, let layout = view.textLayoutManager,
              let content = layout.textContentManager else { return [] }
        var lines: [(Int, NSRect)] = []
        let start = layout.textViewportLayoutController.viewportRange?.location ?? content.documentRange.location
        layout.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout, .ensuresExtraLineFragment]) { fragment in
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
            guard frame.minY <= view.visibleRect.maxY else { return false }
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            if let index = document.lineIndex(at: offset) { lines.append((index + 1, frame)) }
            return true
        }
        return lines
    }
}
