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
    var secondary: Color { palette.map { Color(nsColor: NSColor(themeHex: $0.secondary)) } ?? .secondary }
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

/// A shared, quiet activity pulse; Reduce Motion keeps the status visible and still.
struct WorkingIndicator: View {
    @Environment(\.octoTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    var symbol = "circle.fill"
    var body: some View {
        NativeActivityPulse(symbol: symbol, color: theme.palette.map { NSColor(themeHex: $0.accent) } ?? .controlAccentColor,
                            animate: !reduceMotion && phase == .active)
            .frame(width: symbol == "circle.fill" ? 8 : 13, height: symbol == "circle.fill" ? 8 : 13)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Working")
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
