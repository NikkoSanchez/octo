import AppKit
import SwiftUI

/// Keyboard focus for the composer's controls. With macOS Keyboard navigation off (the default),
/// SwiftUI buttons and menus are not Tab stops, and making them `.focusable()` did not let Space
/// press them. So Tab from the composer moves a focus ring across these stops while a small key
/// view takes the keys: Space or Return presses the ringed control, Escape or typing returns to
/// the composer, and Tab past the last stop moves on to the rest of the window.
enum ComposerStop: Int, CaseIterable, Comparable {
    case attach, agent, permissions, stop, send
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

@MainActor final class ComposerControls: ObservableObject {
    @Published private(set) var focused: ComposerStop?
    private var anchors: [ComposerStop: WeakView] = [:]
    private var enabled: [ComposerStop: Bool] = [:]
    private weak var composer: ScreenshotTextView?
    let keys = ComposerControlKeys()

    init() { keys.controls = self }

    func register(_ stop: ComposerStop, anchor: NSView, enabled isEnabled: Bool) {
        anchors[stop] = WeakView(view: anchor)
        enabled[stop] = isEnabled
    }

    /// The stops that are mounted in a window and enabled, in order. A control that unmounts
    /// (stop gives way to send) drops out because its anchor leaves the window.
    var available: [ComposerStop] {
        ComposerStop.allCases.filter { stop in
            enabled[stop] == true && anchors[stop]?.view?.window != nil
        }
    }

    /// Tab or Shift-Tab from the composer. False when there is no enabled control to go to.
    func enter(from composer: ScreenshotTextView, forward: Bool) -> Bool {
        self.composer = composer
        guard let stop = forward ? available.first : available.last, let window = composer.window else { return false }
        if keys.superview !== window.contentView { keys.removeFromSuperview(); window.contentView?.addSubview(keys) }
        keys.frame = .zero
        focused = stop
        window.makeFirstResponder(keys)
        return true
    }

    func move(forward: Bool) {
        let stops = available
        guard let current = focused, let index = stops.firstIndex(of: current) else { return returnToComposer() }
        let next = index + (forward ? 1 : -1)
        if stops.indices.contains(next) { focused = stops[next]; return }
        focused = nil
        // Back past the first control is the composer; on past the last is the rest of the window.
        guard let composer, composer.window?.makeFirstResponder(composer) == true else { return }
        if forward { composer.focusNextVisibleView(forward: true) }
    }

    /// Presses the ringed control as a click would, so menus open and buttons fire through
    /// their own handling.
    func activate() {
        guard let stop = focused, let view = anchors[stop]?.view, let window = view.window else { return }
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        focused = nil
        // A menu tracks the mouse from mouse-down; the queued mouse-up makes it a click that leaves it open.
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
    }

    func returnToComposer() {
        focused = nil
        if let composer, keys.window?.firstResponder === keys { composer.window?.makeFirstResponder(composer) }
    }

    /// Typing while a control is ringed goes back to the composer, keystroke included.
    func forwardToComposer(_ event: NSEvent) {
        returnToComposer()
        composer?.keyDown(with: event)
    }

    fileprivate func resigned() { focused = nil }
}

private struct WeakView { weak var view: NSView? }

final class ComposerControlKeys: NSView {
    weak var controls: ComposerControls?
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func keyDown(with event: NSEvent) {
        guard let controls else { return super.keyDown(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (event.keyCode, modifiers) {
        case (48, []), (124, []): controls.move(forward: true)
        case (48, .shift), (123, []): controls.move(forward: false)
        case (49, []), (36, []), (76, []): controls.activate()
        case (53, []): controls.returnToComposer()
        default:
            if modifiers.isEmpty || modifiers == .shift { controls.forwardToComposer(event) } else { super.keyDown(with: event) }
        }
    }
    override func resignFirstResponder() -> Bool {
        controls?.resigned()
        return super.resignFirstResponder()
    }
}

private struct ComposerControlsKey: EnvironmentKey { static let defaultValue: ComposerControls? = nil }
extension EnvironmentValues {
    var composerControls: ComposerControls? {
        get { self[ComposerControlsKey.self] }
        set { self[ComposerControlsKey.self] = newValue }
    }
}

extension View {
    /// Makes this control a composer Tab stop with a focus ring.
    func composerStop(_ stop: ComposerStop, enabled: Bool = true) -> some View {
        modifier(ComposerStopModifier(stop: stop, enabled: enabled))
    }
}

private struct ComposerStopModifier: ViewModifier {
    let stop: ComposerStop
    let enabled: Bool
    @Environment(\.composerControls) private var controls
    func body(content: Content) -> some View {
        if let controls {
            content
                .background(ComposerStopAnchor(stop: stop, enabled: enabled, controls: controls))
                .overlay(ComposerStopRing(controls: controls, stop: stop))
        } else { content }
    }
}

/// A separate view so the ring follows focus even inside an equatable parent that skips updates.
private struct ComposerStopRing: View {
    @ObservedObject var controls: ComposerControls
    let stop: ComposerStop
    @Environment(\.octoTheme) private var theme
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(theme.accent.opacity(controls.focused == stop ? 0.85 : 0), lineWidth: 2)
            .padding(-3).allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct ComposerStopAnchor: NSViewRepresentable {
    let stop: ComposerStop
    let enabled: Bool
    let controls: ComposerControls
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) { controls.register(stop, anchor: view, enabled: enabled) }
    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
