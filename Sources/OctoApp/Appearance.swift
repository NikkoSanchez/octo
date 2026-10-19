import AppKit
import SwiftUI
import OctoCore

extension NSColor {
    convenience init(themeHex: String) {
        let value = UInt32(themeHex, radix: 16) ?? 0
        self.init(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
    }
}
extension AppTheme {
    var colorScheme: ColorScheme? { self == .system ? nil : self == .latte ? .light : .dark }
    var background: Color { palette.map { Color(nsColor: NSColor(themeHex: $0.base)) } ?? Color(nsColor: .windowBackgroundColor) }
    var panel: Color { palette.map { Color(nsColor: NSColor(themeHex: $0.mantle)) } ?? Color(nsColor: .controlBackgroundColor) }
    var foreground: Color { Color(nsColor: textColor) }
    var textColor: NSColor { palette.map { NSColor(themeHex: $0.text) } ?? .labelColor }
    /// Long-form reading text. Full-strength light text blooms on a dark base, so
    /// paragraphs step down and bold or headings keep the full foreground for contrast.
    /// The system dark label colour is already translucent.
    var prose: Color { palette != nil && colorScheme == .dark ? foreground.opacity(0.82) : foreground }
    var secondary: Color { Color(nsColor: secondaryColor) }
    var secondaryColor: NSColor { palette.map { NSColor(themeHex: $0.secondary) } ?? .secondaryLabelColor }
    var accent: Color { palette.map { Color(nsColor: NSColor(themeHex: $0.accent)) } ?? .accentColor }
    var surface: Color { palette.map { Color(nsColor: NSColor(themeHex: $0.surface)) } ?? Color.primary.opacity(0.04) }
    var subtle: Color { palette.map { Color(nsColor: NSColor(themeHex: $0.overlay1)) } ?? Color(nsColor: .tertiaryLabelColor) }
    var blue: Color { palette.map { Color(nsColor: NSColor(themeHex: $0.blue)) } ?? .accentColor }
    var green: Color { palette.map { Color(nsColor: NSColor(themeHex: $0.green)) } ?? .green }
    var red: Color { palette.map { Color(nsColor: NSColor(themeHex: $0.red)) } ?? .red }
    var yellow: Color { palette.map { Color(nsColor: NSColor(themeHex: $0.yellow)) } ?? .orange }
    var selection: Color { Color(nsColor: selectionColor) }
    var selectionColor: NSColor { palette.map { NSColor(themeHex: $0.selectionBackground).withAlphaComponent($0.selectionOpacity) } ?? .selectedTextBackgroundColor }
    var cursorColor: NSColor { palette.map { NSColor(themeHex: $0.rosewater) } ?? .textColor }
    var onAccent: Color { palette.map { Color(nsColor: NSColor(themeHex: $0.base)) } ?? .white }
    var border: Color { palette.map { Color(nsColor: NSColor(themeHex: $0.overlay0)) } ?? Color.primary.opacity(0.12) }
    var activeBorder: Color { palette.map { Color(nsColor: NSColor(themeHex: $0.lavender)) } ?? .accentColor }
    func searchHighlight(active: Bool) -> Color {
        guard let palette else { return accent.opacity(active ? 0.20 : 0.07) }
        // Highlight whole messages softly; occurrence-level search is not yet supported.
        return Color(nsColor: NSColor(themeHex: active ? palette.red : palette.teal)).opacity(0.20)
    }
}
private struct OctoThemeKey: EnvironmentKey { static let defaultValue = AppTheme.system }
extension EnvironmentValues {
    var octoTheme: AppTheme { get { self[OctoThemeKey.self] } set { self[OctoThemeKey.self] = newValue } }
}
struct ThemedContent: ViewModifier {
    let theme: AppTheme
    func body(content: Content) -> some View {
        content.environment(\.octoTheme, theme).preferredColorScheme(theme.colorScheme)
            .tint(theme.accent).accentColor(theme.accent).foregroundStyle(theme.foreground)
            .background(theme.background)
    }
}

/// A shared, quiet activity status; Reduce Motion keeps it visible and still.
/// Without a symbol it is a live dot whose soft ring expands and fades.
struct WorkingIndicator: View {
    @Environment(\.octoTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    var symbol: String?
    var body: some View {
        let color = theme.palette.map { NSColor(themeHex: $0.accent) } ?? .controlAccentColor
        let animate = !reduceMotion && phase == .active
        Group {
            if let symbol {
                NativeActivityPulse(symbol: symbol, color: color, animate: animate).frame(width: 13, height: 13)
            } else {
                // The ring needs the room; the dot itself is 6 pt.
                NativeLiveDot(color: color, animate: animate).frame(width: 16, height: 16)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Working")
    }
}

/// Status text with a highlight sweeping across it, drawn and animated natively
/// for the same reason as the pulse. Reduce Motion shows the plain text.
struct ShimmerText: View {
    let text: String
    var size: CGFloat = 13
    @Environment(\.octoTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NativeShimmerText(text: text, font: .monospacedDigitSystemFont(ofSize: size, weight: .regular),
                          base: theme.secondaryColor, highlight: theme.textColor,
                          animate: !reduceMotion && phase == .active)
    }
}

/// Animate only the native layer. SwiftUI symbol effects can repeatedly invalidate
/// the whole window graph, including sidebar placement, even with no new output.
private struct NativeActivityPulse: NSViewRepresentable {
    let symbol: String
    let color: NSColor
    let animate: Bool
    func makeNSView(context: Context) -> ActivityPulseView { ActivityPulseView() }
    func updateNSView(_ view: ActivityPulseView, context: Context) {
        view.update(symbol: symbol, color: color, animate: animate)
    }
    static func dismantleNSView(_ view: ActivityPulseView, coordinator: ()) { view.stopAnimation() }
}

final class ActivityPulseView: NSImageView {
    private var symbol = ""
    private var animate = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageScaling = .scaleProportionallyDown
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func update(symbol: String, color: NSColor, animate: Bool) {
        if self.symbol != symbol {
            self.symbol = symbol
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Working")
        }
        if contentTintColor != color { contentTintColor = color }
        self.animate = animate
        updateAnimation()
    }
    private func updateAnimation() {
        guard animate, window != nil, !isHiddenOrHasHiddenAncestor else { stopAnimation(); return }
        guard layer?.animation(forKey: "activityPulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1; pulse.toValue = 0.35
        pulse.duration = 0.8; pulse.autoreverses = true; pulse.repeatCount = .infinity
        pulse.beginTime = CACurrentMediaTime()
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(pulse, forKey: "activityPulse")
    }
    func stopAnimation() { layer?.removeAnimation(forKey: "activityPulse") }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateAnimation() }
    override func viewDidHide() { super.viewDidHide(); updateAnimation() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateAnimation() }
}

private struct NativeLiveDot: NSViewRepresentable {
    let color: NSColor
    let animate: Bool
    func makeNSView(context: Context) -> LiveDotView { LiveDotView() }
    func updateNSView(_ view: LiveDotView, context: Context) { view.update(color: color, animate: animate) }
    static func dismantleNSView(_ view: LiveDotView, coordinator: ()) { view.stopAnimation() }
}

final class LiveDotView: NSView {
    private let dot = CAShapeLayer()
    let ring = CAShapeLayer()
    private var color = NSColor.controlAccentColor
    private var animate = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(ring); layer?.addSublayer(dot)
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
        // Whole-point origin keeps the dot's edge crisp.
        let side: CGFloat = 6
        let circle = CGPath(ellipseIn: CGRect(x: ((bounds.width - side) / 2).rounded(), y: ((bounds.height - side) / 2).rounded(),
                                              width: side, height: side), transform: nil)
        for shape in [dot, ring] { shape.frame = bounds; shape.path = circle }
        CATransaction.commit()
    }
    private func applyColor() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.fillColor = color.cgColor; ring.fillColor = color.cgColor
        }
        ring.opacity = 0
        CATransaction.commit()
    }
    private func updateAnimation() {
        guard animate, window != nil, !isHiddenOrHasHiddenAncestor else { stopAnimation(); return }
        guard ring.animation(forKey: "liveRing") == nil else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1; scale.toValue = 2.5
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.45; fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 1.6; group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.beginTime = CACurrentMediaTime()
        ring.add(group, forKey: "liveRing")
    }
    func stopAnimation() { ring.removeAnimation(forKey: "liveRing") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColor() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyColor(); updateAnimation() }
    override func viewDidHide() { super.viewDidHide(); updateAnimation() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateAnimation() }
}

private struct NativeShimmerText: NSViewRepresentable {
    let text: String
    let font: NSFont
    let base: NSColor
    let highlight: NSColor
    let animate: Bool
    func makeNSView(context: Context) -> ShimmerTextView { ShimmerTextView() }
    func updateNSView(_ view: ShimmerTextView, context: Context) {
        view.update(text: text, font: font, base: base, highlight: highlight, animate: animate)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShimmerTextView, context: Context) -> CGSize? {
        // The label's intrinsic width omits the cell's text inset, clipping the last glyph.
        let size = nsView.label.cell?.cellSize ?? nsView.label.intrinsicContentSize
        return CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
    }
    static func dismantleNSView(_ view: ShimmerTextView, coordinator: ()) { view.stopAnimation() }
}

/// A plain label with a brighter copy above it, revealed through a moving gradient mask.
/// The sweep animates gradient locations, which are relative to the layer, so text whose
/// width changes every second (an elapsed timer) keeps one continuous sweep.
final class ShimmerTextView: NSView {
    let label = NSTextField(labelWithString: "")
    private let shine = NSTextField(labelWithString: "")
    let shineContainer = NSView()
    let band = CAGradientLayer()
    private var animate = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shine.setAccessibilityElement(false)
        shineContainer.wantsLayer = true
        shineContainer.addSubview(shine)
        addSubview(label); addSubview(shineContainer)
        band.startPoint = CGPoint(x: 0, y: 0.5); band.endPoint = CGPoint(x: 1, y: 0.5)
        band.colors = [NSColor.clear.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        band.locations = [-0.5, -0.25, 0]
        shineContainer.layer?.mask = band
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func update(text: String, font: NSFont, base: NSColor, highlight: NSColor, animate: Bool) {
        if label.stringValue != text {
            label.stringValue = text; shine.stringValue = text
            needsLayout = true
        }
        if label.font != font { label.font = font; shine.font = font; needsLayout = true }
        if label.textColor != base { label.textColor = base }
        if shine.textColor != highlight { shine.textColor = highlight }
        self.animate = animate
        updateAnimation()
    }
    override func layout() {
        super.layout()
        for view in [label, shineContainer] { view.frame = bounds }
        shine.frame = shineContainer.bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        band.frame = shineContainer.bounds
        CATransaction.commit()
    }
    private func updateAnimation() {
        let running = animate && window != nil && !isHiddenOrHasHiddenAncestor
        shineContainer.isHidden = !running
        guard running else { stopAnimation(); return }
        guard band.animation(forKey: "shimmer") == nil else { return }
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-0.5, -0.25, 0]; sweep.toValue = [1, 1.25, 1.5]
        sweep.duration = 1.8; sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sweep.beginTime = CACurrentMediaTime()
        band.add(sweep, forKey: "shimmer")
    }
    func stopAnimation() { band.removeAnimation(forKey: "shimmer") }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateAnimation() }
    override func viewDidHide() { super.viewDidHide(); updateAnimation() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateAnimation() }
}
