import AppKit
import Carbon
import GhosttyKit

@MainActor final class GhosttyNativeView: NSView, @preconcurrency NSTextInputClient {
    weak var session: GhosttySession?
    private var observations: [NSObjectProtocol] = []
    private var keyUpMonitor: Any?
    private var tracking: NSTrackingArea?
    private var marked = NSMutableAttributedString(string: "")
    private var markedSelection = NSRange(location: 0, length: 0)
    private var accumulatedText: [String]?
    private var pendingHighSurrogate: UInt16?
    private var equivalentEvent: NSEvent?
    private var lastMetrics: [Double] = []
    private var attached = false
    private var terminalCursor: NSCursor = .iBeam
    private var surface: ghostty_surface_t? { session?.surface }
    private var canReceiveInput: Bool { attached && session?.isSurfaceVisible == true && session?.isClosed == false }
    private var isFocused: Bool { canReceiveInput && window?.isKeyWindow == true && window?.firstResponder === self }
    override var acceptsFirstResponder: Bool { canReceiveInput }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    init(session: GhosttySession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        setAccessibilityElement(true)
        setAccessibilityHidden(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Project terminal")
        registerForDraggedTypes([.fileURL, .string])
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self, self.isFocused, event.window === self.window, event.modifierFlags.contains(.command) else { return event }
            self.keyUp(with: event); return nil
        }
    }
    required init?(coder: NSCoder) { nil }
    deinit {
        observations.forEach { NotificationCenter.default.removeObserver($0) }
        if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor) }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observations.forEach { NotificationCenter.default.removeObserver($0) }
        observations.removeAll()
        attached = window != nil
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didChangeScreenNotification, NSWindow.didChangeOcclusionStateNotification] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.synchronizeMetrics(); self?.synchronizeVisibility(); self?.session?.replayFocus()
                    }
                })
            }
            session?.attach(to: self)
            synchronizeMetrics()
            DispatchQueue.main.async { [weak self] in self?.session?.replayFocus() }
        }
        synchronizeVisibility()
    }
    override func layout() { super.layout(); synchronizeMetrics() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); synchronizeMetrics() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        session?.setDarkAppearance(effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }
    func synchronizeMetrics() {
        guard let surface, attached, bounds.width > 0, bounds.height > 0 else { return }
        let pixels = convertToBacking(bounds.size)
        let scale = window?.backingScaleFactor ?? 1
        let display = (window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let values = [pixels.width, pixels.height, scale, Double(display)]
        guard values != lastMetrics else { return }
        lastMetrics = values
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_display_id(surface, display)
        ghostty_surface_set_size(surface, UInt32(clamping: Int(pixels.width)), UInt32(clamping: Int(pixels.height)))
        layer?.contentsScale = scale
        session?.setDarkAppearance(effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        session?.refresh()
    }
    func synchronizeVisibility() {
        setAccessibilityHidden(!canReceiveInput)
        guard let surface else { return }
        let visible = canReceiveInput && window?.occlusionState.contains(.visible) == true
        ghostty_surface_set_occlusion(surface, visible)
        if !canReceiveInput, window?.firstResponder === self { window?.makeFirstResponder(nil) }
        ghostty_surface_set_focus(surface, isFocused)
        if visible { session?.refresh() }
    }
    func detach() { attached = false; synchronizeVisibility() }
    func sessionClosed() {
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        marked.mutableString.setString("")
        layer = nil
    }
    override func becomeFirstResponder() -> Bool {
        guard canReceiveInput, super.becomeFirstResponder() else { return false }
        if let surface { ghostty_surface_set_focus(surface, window?.isKeyWindow == true) }
        return true
    }
    override func resignFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, false) }
        equivalentEvent = nil
        return super.resignFirstResponder()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited], owner: self)
        tracking = area; addTrackingArea(area)
    }
    override func resetCursorRects() { super.resetCursorRects(); if canReceiveInput { addCursorRect(bounds, cursor: terminalCursor) } }
    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT: terminalCursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: terminalCursor = .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_POINTER: terminalCursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR, GHOSTTY_MOUSE_SHAPE_CELL: terminalCursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB: terminalCursor = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: terminalCursor = .closedHand
        case GHOSTTY_MOUSE_SHAPE_COPY: terminalCursor = .dragCopy
        case GHOSTTY_MOUSE_SHAPE_ALIAS: terminalCursor = .dragLink
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: terminalCursor = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE: terminalCursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE: terminalCursor = .resizeUpDown
        default: terminalCursor = .arrow
        }
        window?.invalidateCursorRects(for: self)
        if isFocused { terminalCursor.set() }
    }

    @discardableResult private func sendKey(_ event: NSEvent, action: ghostty_input_action_e,
                                           translation: NSEvent? = nil, text: String? = nil, composing: Bool = false) -> Bool {
        guard let surface, canReceiveInput else { return false }
        var key = GhosttyInput.key(event, action: action, translated: translation)
        key.composing = composing
        if let text = GhosttyInput.keyText(text) {
            return text.withCString { key.text = $0; return ghostty_surface_key(surface, key) }
        }
        return ghostty_surface_key(surface, key)
    }
    private func committedText(_ value: String) {
        guard let surface, canReceiveInput, let text = GhosttyInput.keyText(value) else { return }
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.keycode = UInt32.max
        text.withCString { key.text = $0; _ = ghostty_surface_key(surface, key) }
    }
    override func keyDown(with event: NSEvent) {
        guard let surface, isFocused else { return }
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        if event.modifierFlags.contains(.command) && !hasMarkedText() {
            _ = sendKey(event, action: action, text: event.characters); return
        }
        let translatedMods = GhosttyInput.translationFlags(event.modifierFlags,
            ghostty: ghostty_surface_key_translation_mods(surface, GhosttyInput.modifiers(event.modifierFlags)))
        let translated: NSEvent
        if translatedMods == event.modifierFlags { translated = event }
        else {
            translated = NSEvent.keyEvent(with: event.type, location: event.locationInWindow, modifierFlags: translatedMods,
                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                characters: event.characters(byApplyingModifiers: translatedMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "", isARepeat: event.isARepeat,
                keyCode: event.keyCode) ?? event
        }
        let wasMarked = hasMarkedText()
        let layout = GhosttyInput.keyboardLayoutID
        accumulatedText = []
        equivalentEvent = nil
        defer { accumulatedText = nil }
        interpretKeyEvents([translated])
        if !wasMarked && layout != GhosttyInput.keyboardLayoutID { return }
        synchronizePreedit()
        let composing = wasMarked || hasMarkedText()
        let text = accumulatedText ?? []
        if wasMarked && !text.isEmpty {
            text.forEach { committedText($0) }
            // A committed preedit may also move the terminal cursor. Plain left
            // is excluded because Korean composition already keeps its caret.
            if [124, 125, 126].contains(event.keyCode) || (event.keyCode == 123 && !event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty) {
                _ = sendKey(event, action: action, translation: translated)
            }
        } else if !text.isEmpty {
            for value in text {
                if composing && value.unicodeScalars.count == 1 && (value.unicodeScalars.first?.value ?? 32) < 32 { continue }
                _ = sendKey(event, action: action, translation: translated, text: value)
            }
        } else {
            if composing, let value = event.characters, value.unicodeScalars.count == 1,
               (value.unicodeScalars.first?.value ?? 32) < 32 { return }
            let value = translated.characters(byApplyingModifiers: translated.modifierFlags.subtracting(.control))
            _ = sendKey(event, action: action, translation: translated, text: value, composing: composing)
        }
    }
    override func keyUp(with event: NSEvent) { _ = sendKey(event, action: GHOSTTY_ACTION_RELEASE) }
    override func flagsChanged(with event: NSEvent) {
        guard isFocused, !hasMarkedText() else { return }
        let flag: NSEvent.ModifierFlags
        let sideMask: Int32?
        switch event.keyCode {
        case 56: flag = .shift; sideMask = NX_DEVICELSHIFTKEYMASK
        case 60: flag = .shift; sideMask = NX_DEVICERSHIFTKEYMASK
        case 59: flag = .control; sideMask = NX_DEVICELCTLKEYMASK
        case 62: flag = .control; sideMask = NX_DEVICERCTLKEYMASK
        case 58: flag = .option; sideMask = NX_DEVICELALTKEYMASK
        case 61: flag = .option; sideMask = NX_DEVICERALTKEYMASK
        case 55: flag = .command; sideMask = NX_DEVICELCMDKEYMASK
        case 54: flag = .command; sideMask = NX_DEVICERCMDKEYMASK
        case 57: flag = .capsLock; sideMask = nil
        default: return
        }
        let pressed = event.modifierFlags.contains(flag) && (sideMask.map { event.modifierFlags.rawValue & UInt($0) != 0 } ?? true)
        _ = sendKey(event, action: pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, isFocused, !hasMarkedText(), let surface else { return false }
        // App menus (Settings/Quit/Edit) must win over equivalent Ghostty
        // bindings. Octo's workspace monitor already handles its own shortcuts.
        if event.modifierFlags.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        var key = GhosttyInput.key(event, action: GHOSTTY_ACTION_PRESS)
        var flags = ghostty_binding_flags_e(0)
        let binding = (event.characters ?? "").withCString { key.text = $0; return ghostty_surface_key_is_binding(surface, key, &flags) }
        if binding || event.modifierFlags.contains(.control) { keyDown(with: event); return true }
        equivalentEvent = event.modifierFlags.contains(.command) ? event : nil
        return false
    }
    override func doCommand(by selector: Selector) {
        if let event = equivalentEvent { equivalentEvent = nil; keyDown(with: event) }
        // During interpretKeyEvents, control keys are encoded by keyDown itself.
    }
    override func mouseDown(with event: NSEvent) {
        guard canReceiveInput else { return }
        window?.makeFirstResponder(self)
        mouseMoved(with: event)
        mouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT)
    }
    override func mouseUp(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT) }
    override func rightMouseDown(with event: NSEvent) {
        mouseMoved(with: event)
        if !mouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT) { super.rightMouseDown(with: event) }
    }
    override func rightMouseUp(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT) }
    override func otherMouseDown(with event: NSEvent) { mouseMoved(with: event); mouseButton(event, GHOSTTY_MOUSE_PRESS, ghostty_input_mouse_button_e(UInt32(event.buttonNumber + 1))) }
    override func otherMouseUp(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_RELEASE, ghostty_input_mouse_button_e(UInt32(event.buttonNumber + 1))) }
    @discardableResult private func mouseButton(_ event: NSEvent, _ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e) -> Bool {
        guard canReceiveInput, let surface else { return false }
        return ghostty_surface_mouse_button(surface, state, button, GhosttyInput.modifiers(event.modifierFlags))
    }
    override func mouseMoved(with event: NSEvent) {
        guard canReceiveInput, let surface else { return }
        let location = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, location.x, bounds.height - location.y, GhosttyInput.modifiers(event.modifierFlags))
    }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) {
        if let surface, NSEvent.pressedMouseButtons == 0 { ghostty_surface_mouse_pos(surface, -1, -1, GhosttyInput.modifiers(event.modifierFlags)) }
    }
    override func scrollWheel(with event: NSEvent) {
        guard canReceiveInput, let surface else { return }
        let factor = event.hasPreciseScrollingDeltas ? 2.0 : 1.0
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX * factor, event.scrollingDeltaY * factor,
            GhosttyInput.scrollModifiers(precise: event.hasPreciseScrollingDeltas, momentum: event.momentumPhase))
    }
    override func pressureChange(with event: NSEvent) {
        if canReceiveInput, let surface { ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure)) }
    }
    @discardableResult func binding(_ value: String) -> Bool {
        guard canReceiveInput, let surface else { return false }
        return value.withCString { ghostty_surface_binding_action(surface, $0, UInt(value.utf8.count)) }
    }
    @objc func copy(_ sender: Any?) { binding("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { binding("paste_from_clipboard") }
    override func selectAll(_ sender: Any?) { binding("select_all") }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard canReceiveInput else { return nil }
        let menu = NSMenu()
        for (title, action) in [("Copy", #selector(copy(_:))), ("Paste", #selector(paste(_:))), ("Select All", #selector(selectAll(_:)))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self
        }
        return menu
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { canReceiveInput ? .copy : [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard canReceiveInput, let surface, let text = GhosttyClipboard.pasteText(sender.draggingPasteboard) else { return false }
        text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
        return true
    }

    func hasMarkedText() -> Bool { marked.length > 0 }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { hasMarkedText() ? markedSelection : NSRange(location: NSNotFound, length: 0) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let value = string as? NSAttributedString { marked = NSMutableAttributedString(attributedString: value) }
        else if let value = string as? String { marked = NSMutableAttributedString(string: value) }
        markedSelection = NSIntersectionRange(selectedRange, NSRange(location: 0, length: marked.length))
        if accumulatedText == nil { synchronizePreedit() }
    }
    func unmarkText() { marked.mutableString.setString(""); markedSelection = NSRange(location: 0, length: 0); synchronizePreedit() }
    private func synchronizePreedit() {
        guard let surface else { return }
        if hasMarkedText() { marked.string.withCString { ghostty_surface_preedit(surface, $0, UInt(marked.string.utf8.count)) } }
        else { ghostty_surface_preedit(surface, nil, 0) }
        inputContext?.invalidateCharacterCoordinates()
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        var value = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if let raw = string as? NSString, raw.length == 1 {
            let unit = raw.character(at: 0)
            if (0xD800...0xDBFF).contains(unit) { pendingHighSurrogate = unit; return }
            if (0xDC00...0xDFFF).contains(unit) {
                guard let high = pendingHighSurrogate else { return }
                value = String(decoding: [high, unit], as: UTF16.self)
            }
        }
        pendingHighSurrogate = nil
        unmarkText()
        if accumulatedText != nil { accumulatedText?.append(value) } else { committedText(value) }
    }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard hasMarkedText(), range.location != NSNotFound else { return nil }
        let clipped = NSIntersectionRange(range, NSRange(location: 0, length: marked.length))
        actualRange?.pointee = clipped
        return marked.attributedSubstring(from: clipped)
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let local = NSRect(x: x, y: bounds.height - y, width: width, height: height)
        let rect = convert(local, to: nil)
        actualRange?.pointee = range
        return window?.convertToScreen(rect) ?? rect
    }
    override func accessibilityValue() -> Any? { session?.visibleText() }
    func accessibilityTextChanged() {
        if canReceiveInput { NSAccessibility.post(element: self, notification: .valueChanged) }
    }
    override func accessibilitySelectedText() -> String? {
        guard let surface else { return nil }
        var result = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &result) else { return nil }
        defer { ghostty_surface_free_text(surface, &result) }
        guard let text = result.text else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: text, count: Int(result.text_len)), as: UTF8.self)
    }
}
