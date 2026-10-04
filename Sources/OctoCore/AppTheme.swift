import Foundation

/// Official Catppuccin 1.8.0 and Dracula Classic palettes and semantic roles.
/// https://draculatheme.com/spec
/// https://github.com/dracula/draculatheme.com/blob/main/content/spec.mdx
/// https://github.com/catppuccin/catppuccin/blob/main/docs/style-guide.md
/// https://github.com/catppuccin/palette/blob/main/palette.json
public enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system, latte, mocha, dracula
    public var id: String { rawValue }
    public var title: String {
        switch self { case .system: return "macOS System"; case .latte: return "Catppuccin Latte"; case .mocha: return "Catppuccin Mocha"; case .dracula: return "Dracula Classic" }
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
            selectionBackground: "7c7f93", selectionOpacity: 0.25, cursorText: "eff1f5", terminalSelectionBackground: "d2d4dc", ansi: ["5c5f77", "d20f39", "40a02b", "df8e1d", "1e66f5", "ea76cb", "179299", "acb0be", "6c6f85", "de293e", "49af3d", "eea02d", "456eff", "fe85d8", "2d9fa8", "bcc0cc"])
        case .mocha: return ThemePalette(
            base: "1e1e2e", mantle: "181825", crust: "11111b", surface: "313244",
            overlay0: "6c7086", overlay1: "7f849c", overlay2: "9399b2", text: "cdd6f4",
            secondary: "a6adc8", accent: "cba6f7", green: "a6e3a1", red: "f38ba8",
            yellow: "f9e2af", blue: "89b4fa", teal: "94e2d5", rosewater: "f5e0dc",
            pink: "f5c2e7", peach: "fab387", sky: "89dceb", lavender: "b4befe",
            selectionBackground: "9399b2", selectionOpacity: 0.25, cursorText: "11111b", terminalSelectionBackground: "3b3d4f", ansi: ["45475a", "f38ba8", "a6e3a1", "f9e2af", "89b4fa", "f5c2e7", "94e2d5", "a6adc8", "585b70", "f37799", "89d88b", "ebd391", "74a8fc", "f2aede", "6bd7ca", "bac2de"])
        case .dracula: return ThemePalette(
            base: "282a36", mantle: "21222c", crust: "191a21", surface: "343746",
            overlay0: "6272a4", overlay1: "6272a4", overlay2: "6272a4", text: "f8f8f2",
            secondary: "f8f8f2", accent: "bd93f9", green: "50fa7b", red: "ff5555",
            yellow: "f1fa8c", blue: "8be9fd", teal: "8be9fd", rosewater: "f8f8f2",
            pink: "ff79c6", peach: "ffb86c", sky: "8be9fd", lavender: "bd93f9",
            selectionBackground: "44475a", selectionOpacity: 1, cursorText: "282a36",
            terminalSelectionBackground: "44475a", ansi: ["21222c", "ff5555", "50fa7b", "f1fa8c", "bd93f9", "ff79c6", "8be9fd", "f8f8f2", "6272a4", "ff6e6e", "69ff94", "ffffa5", "d6acff", "ff92df", "a4ffff", "ffffff"])
        }
    }
    public var syntax: ThemeSyntaxPalette? {
        guard let p = palette else { return nil }
        return ThemeSyntaxPalette(keyword: self == .dracula ? p.pink : p.accent,
            string: self == .dracula ? p.yellow : p.green,
            escape: self == .dracula ? p.yellow : p.pink,
            comment: p.overlay2, number: p.peach,
            function: self == .dracula ? p.green : p.blue, key: p.blue,
            punctuation: self == .dracula ? p.text : p.overlay2,
            operatorColor: self == .dracula ? p.pink : p.sky)
    }
}
public struct ThemeSyntaxPalette: Sendable {
    public let keyword, string, escape, comment, number, function, key, punctuation, operatorColor: String
}
public struct ThemePalette: Sendable {
    public let base, mantle, crust, surface, overlay0, overlay1, overlay2, text, secondary: String
    public let accent, green, red, yellow, blue, teal, rosewater, pink, peach, sky, lavender: String
    public let selectionBackground: String
    public let selectionOpacity: Double
    public let cursorText: String
    /// Selection precomposited for Ghostty’s opaque RGB setting (Dracula uses its exact token).
    public let terminalSelectionBackground: String
    /// Official normal and bright ANSI colors, in index order (0...15).
    public let ansi: [String]
}
