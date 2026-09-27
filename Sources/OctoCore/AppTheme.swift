import Foundation

/// Catppuccin palette 1.8.0 and semantic roles from its official style guide.
/// https://github.com/catppuccin/catppuccin/blob/main/docs/style-guide.md
/// https://github.com/catppuccin/palette/blob/main/palette.json
public enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system, latte, mocha
    public var id: String { rawValue }
    public var title: String {
        switch self { case .system: return "macOS System"; case .latte: return "Catppuccin Latte"; case .mocha: return "Catppuccin Mocha" }
    }
    public var palette: ThemePalette? {
        switch self {
        case .system: return nil
        case .latte: return ThemePalette(
            base: "eff1f5", mantle: "e6e9ef", crust: "dce0e8", surface: "ccd0da",
            overlay0: "9ca0b0", overlay1: "8c8fa1", overlay2: "7c7f93", text: "4c4f69",
            secondary: "6c6f85", accent: "8839ef", green: "40a02b", red: "d20f39",
            yellow: "df8e1d", blue: "1e66f5", teal: "179299", rosewater: "dc8a78",
            pink: "ea76cb", peach: "fe640b", sky: "04a5e5", lavender: "7287fd",
            cursorText: "eff1f5", terminalSelectionBackground: "d2d4dc", ansi: ["5c5f77", "d20f39", "40a02b", "df8e1d", "1e66f5", "ea76cb", "179299", "acb0be", "6c6f85", "de293e", "49af3d", "eea02d", "456eff", "fe85d8", "2d9fa8", "bcc0cc"])
        case .mocha: return ThemePalette(
            base: "1e1e2e", mantle: "181825", crust: "11111b", surface: "313244",
            overlay0: "6c7086", overlay1: "7f849c", overlay2: "9399b2", text: "cdd6f4",
            secondary: "a6adc8", accent: "cba6f7", green: "a6e3a1", red: "f38ba8",
            yellow: "f9e2af", blue: "89b4fa", teal: "94e2d5", rosewater: "f5e0dc",
            pink: "f5c2e7", peach: "fab387", sky: "89dceb", lavender: "b4befe",
            cursorText: "11111b", terminalSelectionBackground: "3b3d4f", ansi: ["45475a", "f38ba8", "a6e3a1", "f9e2af", "89b4fa", "f5c2e7", "94e2d5", "a6adc8", "585b70", "f37799", "89d88b", "ebd391", "74a8fc", "f2aede", "6bd7ca", "bac2de"])
        }
    }
}
public struct ThemePalette: Sendable {
    public let base, mantle, crust, surface, overlay0, overlay1, overlay2, text, secondary: String
    public let accent, green, red, yellow, blue, teal, rosewater, pink, peach, sky, lavender: String
    public let cursorText: String
    /// Overlay2 at 25% over Base, precomposited for Ghostty's opaque RGB selection setting.
    public let terminalSelectionBackground: String
    /// Official normal and bright ANSI colors, in index order (0...15).
    public let ansi: [String]
}
