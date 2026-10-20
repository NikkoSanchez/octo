import AppKit
import SwiftUI
import OctoCore

/// A floating panel card after the macOS 26 Messages sidebar: Liquid Glass where available,
/// tinted with the palette's panel colour, and opaque when Reduce Transparency is on.
struct GlassPanel: ViewModifier {
    /// Small enough that a corner control centred on the traffic lights can follow its curve.
    var cornerRadius: CGFloat = 16
    @Environment(\.octoTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            // Concentric controls inside the card take their corners from this shape.
            .containerShape(shape)
            .clipShape(shape)
            .background {
                // The shadow belongs to the card's outline only; on the content it would shadow every glyph.
                shape.fill(theme.background).shadow(color: .black.opacity(theme.colorScheme == .dark ? 0.35 : 0.08), radius: 14, y: 6)
                if reduceTransparency { shape.fill(theme.panel) } else { NativeGlass(cornerRadius: cornerRadius, tint: theme.glassTint) }
            }
            .overlay(shape.strokeBorder(theme.hairline, lineWidth: 0.5).allowsHitTesting(false))
    }
}

/// Small floating controls: round buttons and capsules that sit on glass.
struct GlassControl: ViewModifier {
    @Environment(\.octoTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content.background {
            if reduceTransparency { Capsule().fill(theme.field) } else { NativeGlass(cornerRadius: nil, tint: theme.glassTint) }
        }
    }
}

/// AppKit's Liquid Glass rather than SwiftUI's `glassEffect`. A SwiftUI glass effect laid out
/// beside any Core Animation indicator (the working dot, avatar ring or typing dots) re-laid out
/// the hosting view about 10,000 times a second; this view composites without touching layout.
private struct NativeGlass: NSViewRepresentable {
    /// nil rounds the shorter side fully, for circles and capsules.
    let cornerRadius: CGFloat?
    let tint: Color?
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) { return CapsuleGlassView() }
        return RoundedMaterialView()
    }
    func updateNSView(_ view: NSView, context: Context) {
        if #available(macOS 26.0, *), let glass = view as? CapsuleGlassView {
            glass.fixedRadius = cornerRadius
            let color = tint.map(NSColor.init)
            if glass.tintColor != color { glass.tintColor = color }
        } else if let material = view as? RoundedMaterialView {
            material.fixedRadius = cornerRadius
        }
    }
}

/// The pre-Tahoe fallback: a window-blended material with the same rounding.
private final class RoundedMaterialView: NSVisualEffectView {
    var fixedRadius: CGFloat? { didSet { if fixedRadius != oldValue { needsLayout = true } } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow; blendingMode = .withinWindow; state = .active
        wantsLayer = true; layer?.cornerCurve = .continuous; layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        layer?.cornerRadius = fixedRadius ?? min(bounds.width, bounds.height) / 2
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@available(macOS 26.0, *)
private final class CapsuleGlassView: NSGlassEffectView {
    var fixedRadius: CGFloat? { didSet { if fixedRadius != oldValue { needsLayout = true } } }
    override func layout() {
        super.layout()
        let radius = fixedRadius ?? min(bounds.width, bounds.height) / 2
        if cornerRadius != radius { cornerRadius = radius }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 16) -> some View { modifier(GlassPanel(cornerRadius: cornerRadius)) }
    /// Content that floats over a scroll view's edge while the list scrolls beneath it.
    @ViewBuilder func floatingBar<Bar: View>(_ edge: VerticalEdge, @ViewBuilder content: () -> Bar) -> some View {
        if #available(macOS 26.0, *) { safeAreaBar(edge: edge, content: content) }
        else { safeAreaInset(edge: edge, content: content) }
    }
    /// A circle or capsule of glass behind a small control.
    func glassControl() -> some View { modifier(GlassControl()) }
}

/// A control in the card's top-trailing corner. Its background's outer corner is concentric with
/// the card's (macOS 26), so the two curves keep an even gap.
struct CornerButton: View {
    let systemImage: String
    let action: () -> Void
    @Environment(\.octoTheme) private var theme
    @State private var hovering = false
    private var shape: AnyShape {
        if #available(macOS 26.0, *) { return AnyShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(8)), isUniform: false)) }
        return AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 14, weight: .medium)).foregroundStyle(theme.accent)
                .frame(width: 36, height: 24)
                .background(theme.accent.opacity(hovering ? 0.2 : 0.12), in: shape)
                .contentShape(shape)
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}

/// A button in a glass toolbar capsule or a panel's control row: a 32×28 pt capsule lit on hover.
struct CapsuleToolbarButtonStyle: ButtonStyle {
    /// Draws the glyph in the accent colour, for a toggle whose panel is showing.
    var active = false
    func makeBody(configuration: Configuration) -> some View { CapsuleToolbarButton(configuration: configuration, active: active) }
    private struct CapsuleToolbarButton: View {
        let configuration: ButtonStyle.Configuration
        let active: Bool
        @Environment(\.octoTheme) private var theme
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            configuration.label.font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? theme.accent : hovering ? theme.foreground : theme.secondary)
                .frame(width: 32, height: 28)
                .background(Color.primary.opacity(enabled ? (configuration.isPressed ? 0.12 : hovering ? 0.07 : 0) : 0), in: Capsule())
                .contentShape(Capsule())
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovering = $0 }
        }
    }
}

/// A segmented capsule, as in the panel's tab strip: the selected segment is raised on the track.
struct CapsulePicker<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @Environment(\.octoTheme) private var theme
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index], selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        .foregroundStyle(selected ? theme.foreground : theme.secondary)
                        .padding(.horizontal, 9).frame(minHeight: 22)
                        .background {
                            if selected { Capsule().fill(theme.background).shadow(color: .black.opacity(0.12), radius: 1.5, y: 1) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3).background(theme.field, in: Capsule()).fixedSize()
        .accessibilityElement(children: .contain).accessibilityLabel(label)
    }
}

/// The capsule search field at the top of the sidebar. Clicking it (or ⌘K while the sidebar shows)
/// edits in place and the sidebar lists the results, as in Messages.
struct SidebarSearchField: View {
    @Binding var text: String
    let active: Bool
    var focus: FocusState<Bool>.Binding
    let activate: () -> Void
    /// Escape clears the text first, then leaves search.
    let cancel: () -> Void
    let submit: () -> Void
    /// Moves the highlighted result by this many rows.
    let move: (Int) -> Void
    @Environment(\.octoTheme) private var theme
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium))
            if active {
                TextField("Search", text: $text).textFieldStyle(.plain).foregroundStyle(theme.foreground)
                    .focused(focus)
                    .onSubmit(submit)
                    .onExitCommand(perform: cancel)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .accessibilityLabel("Search all chats")
                Button { text = ""; cancel() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 13)) }
                    .buttonStyle(.plain).foregroundStyle(theme.subtle).help("End search").accessibilityLabel("End search")
            } else {
                Text("Search")
                Spacer(minLength: 0)
                Text("⌘K").font(.system(size: 11)).foregroundStyle(theme.subtle)
            }
        }
        .font(.system(size: 13.5)).foregroundStyle(theme.secondary)
        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 34)
        .background(Color.primary.opacity(hovering && !active ? 0.05 : 0), in: Capsule())
        .overlay(Capsule().strokeBorder(theme.accent.opacity(active ? 0.55 : 0), lineWidth: 1))
        .glassControl()
        .contentShape(Capsule())
        .onTapGesture { if !active { activate() } }
        .onHover { hovering = $0 }
        .accessibilityElement(children: active ? .contain : .ignore)
        .accessibilityAddTraits(active ? [] : .isButton)
        .accessibilityLabel(active ? "" : "Search all chats")
        .accessibilityAction { if !active { activate() } }
        .shortcutHint("chats").help(active ? "" : "Search all chats (⌘K)")
    }
}

/// A provider mark on a monogram circle, after Messages' contact avatars; a native ring pulses while working.
struct ThreadAvatar: View {
    let harness: HarnessID
    var size: CGFloat = 36
    var running = false
    /// The ring takes the row's own background colour so it reads on a selection fill.
    var outline: Color?
    @Environment(\.octoTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Circle().fill(theme.avatarFill)
            .overlay { ProviderIcon(harness: harness, size: size * 0.5).foregroundStyle(theme.avatarForeground) }
            .frame(width: size, height: size)
            .overlay {
                if running {
                    NativeAvatarRing(color: NSColor(outline ?? theme.accent), animate: !reduceMotion && phase == .active)
                        .frame(width: size + 8, height: size + 8).allowsHitTesting(false)
                }
            }
            .accessibilityHidden(true)
    }
}

private struct NativeAvatarRing: NSViewRepresentable {
    let color: NSColor
    let animate: Bool
    func makeNSView(context: Context) -> AvatarRingView { AvatarRingView() }
    func updateNSView(_ view: AvatarRingView, context: Context) { view.update(color: color, animate: animate) }
    static func dismantleNSView(_ view: AvatarRingView, coordinator: ()) { view.stopAnimation() }
}

/// Drawn and animated in Core Animation for the same reason as `LiveDotView`: a repeating
/// SwiftUI animation invalidates the window graph, including sidebar placement.
final class AvatarRingView: NSView {
    let ring = CAShapeLayer()
    private var color = NSColor.controlAccentColor
    private var animate = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ring.fillColor = nil; ring.lineWidth = 2
        layer?.addSublayer(ring)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func update(color: NSColor, animate: Bool) {
        if self.color != color { self.color = color; applyColor() }
        self.animate = animate
        updateAnimation()
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 2, dy: 2), transform: nil)
        CATransaction.commit()
    }
    private func applyColor() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance { ring.strokeColor = color.cgColor }
        CATransaction.commit()
    }
    private func updateAnimation() {
        guard animate, window != nil, !isHiddenOrHasHiddenAncestor else { stopAnimation(); return }
        guard ring.animation(forKey: "avatarRing") == nil else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.9; scale.toValue = 1.14
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9; fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 1.6; group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.beginTime = CACurrentMediaTime()
        ring.add(group, forKey: "avatarRing")
    }
    /// Still, the ring stays visible as a static working mark.
    func stopAnimation() { ring.removeAnimation(forKey: "avatarRing") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColor() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyColor(); updateAnimation() }
    override func viewDidHide() { super.viewDidHide(); updateAnimation() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateAnimation() }
}

/// Messages' typing dots for a working thread's preview line.
struct TypingIndicator: View {
    let color: NSColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NativeTypingDots(color: color, animate: !reduceMotion && phase == .active)
            .frame(width: 20, height: 10).accessibilityHidden(true)
    }
}

private struct NativeTypingDots: NSViewRepresentable {
    let color: NSColor
    let animate: Bool
    func makeNSView(context: Context) -> TypingDotsView { TypingDotsView() }
    func updateNSView(_ view: TypingDotsView, context: Context) { view.update(color: color, animate: animate) }
    static func dismantleNSView(_ view: TypingDotsView, coordinator: ()) { view.stopAnimation() }
}

final class TypingDotsView: NSView {
    let dots = (0..<3).map { _ in CALayer() }
    private var color = NSColor.secondaryLabelColor
    private var animate = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        dots.forEach { layer?.addSublayer($0) }
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func update(color: NSColor, animate: Bool) {
        if self.color != color { self.color = color; applyColor() }
        self.animate = animate
        updateAnimation()
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let side: CGFloat = 5, gap = (bounds.width - side * 3) / 2
        for (index, dot) in dots.enumerated() {
            dot.frame = CGRect(x: (CGFloat(index) * (side + gap)).rounded(), y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
            dot.cornerRadius = side / 2
        }
        CATransaction.commit()
    }
    private func applyColor() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance { dots.forEach { $0.backgroundColor = color.cgColor } }
        CATransaction.commit()
    }
    private func updateAnimation() {
        guard animate, window != nil, !isHiddenOrHasHiddenAncestor else { stopAnimation(); return }
        guard dots[0].animation(forKey: "typing") == nil else { return }
        let start = CACurrentMediaTime()
        for (index, dot) in dots.enumerated() {
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0.35, 1, 0.35, 0.35]; fade.keyTimes = [0, 0.25, 0.5, 1]
            fade.duration = 1.2; fade.repeatCount = .infinity
            fade.beginTime = start + Double(index) * 0.18
            dot.add(fade, forKey: "typing")
        }
    }
    func stopAnimation() { dots.forEach { $0.removeAnimation(forKey: "typing") } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColor() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyColor(); updateAnimation() }
    override func viewDidHide() { super.viewDidHide(); updateAnimation() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateAnimation() }
}

/// Messages' window chrome: content runs beneath a transparent titlebar, and the traffic lights
/// move into the sidebar card's top row. A toolbar would lower them too, but on macOS 26 its
/// `NSToolbarView` draws a full-width glass band over the content, so there is none.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowChromeView { WindowChromeView() }
    func updateNSView(_ view: WindowChromeView, context: Context) { view.apply() }
}

final class WindowChromeView: NSView {
    /// The close button's top-left corner in window coordinates, measured from the top. It must stay
    /// inside the 32 pt titlebar: a button extending below it is clipped and loses its lower clicks.
    static let buttonOrigin = CGPoint(x: 20, y: 17)
    private static let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    private var observers: [NSObjectProtocol] = []
    private var transparency: NSKeyValueObservation?
    /// Each button's horizontal offset from the close button, as AppKit lays them out.
    private var spacing: [CGFloat]?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []; transparency = nil
        apply()
        guard let window else { return }
        // The scene's hidden-titlebar style keeps the titlebar transparent; restore it should anything else reset it.
        transparency = window.observe(\.titlebarAppearsTransparent) { [weak self] window, _ in
            guard !window.titlebarAppearsTransparent else { return }
            DispatchQueue.main.async { self?.apply() }
        }
        // AppKit restores the buttons' frames whenever it lays out the titlebar (resizing,
        // full screen, appearance changes); put them back in the same pass.
        for button in Self.kinds.compactMap(window.standardWindowButton) {
            button.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: button, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeButtons() }
            })
        }
        for name in [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeButtons() }
            })
        }
    }
    func apply() {
        guard let window else { return }
        if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
        placeButtons()
    }
    func placeButtons() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let buttons = Self.kinds.compactMap(window.standardWindowButton)
        guard buttons.count == Self.kinds.count else { return }
        if spacing == nil { spacing = buttons.map { $0.frame.minX - buttons[0].frame.minX } }
        for (button, offset) in zip(buttons, spacing ?? []) {
            guard let titlebar = button.superview else { continue }
            let top = Self.buttonOrigin.y, height = button.frame.height
            let y = titlebar.isFlipped ? top : titlebar.bounds.height - top - height
            let origin = CGPoint(x: Self.buttonOrigin.x + offset, y: y)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
