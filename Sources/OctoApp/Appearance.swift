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
    var symbol = "circle.fill"
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: symbol == "circle.fill" ? 8 : 13))
            .foregroundStyle(theme.accent)
            .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            .accessibilityLabel("Working")
    }
}
