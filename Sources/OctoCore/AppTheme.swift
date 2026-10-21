import Foundation

/// The app's colour themes. Raw values are persisted; never rename an existing case's value.
/// Palettes and their upstream sources live in ThemeCatalog.swift.
public enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system
    case latte, frappe, macchiato, mocha
    case dracula
    case githubLight, githubDark
    case gruvboxLight, gruvboxDark
    case nord
    case oneLight, oneDark
    case rosePineDawn, rosePine
    case solarizedLight, solarizedDark
    case tokyoNightDay, tokyoNight

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: return "macOS System"
        case .latte: return "Catppuccin Latte"
        case .frappe: return "Catppuccin Frappé"
        case .macchiato: return "Catppuccin Macchiato"
        case .mocha: return "Catppuccin Mocha"
        case .dracula: return "Dracula Classic"
        case .githubLight: return "GitHub Light"
        case .githubDark: return "GitHub Dark"
        case .gruvboxLight: return "Gruvbox Light"
        case .gruvboxDark: return "Gruvbox Dark"
        case .nord: return "Nord"
        case .oneLight: return "One Light"
        case .oneDark: return "One Dark"
        case .rosePineDawn: return "Rosé Pine Dawn"
        case .rosePine: return "Rosé Pine"
        case .solarizedLight: return "Solarized Light"
        case .solarizedDark: return "Solarized Dark"
        case .tokyoNightDay: return "Tokyo Night Day"
        case .tokyoNight: return "Tokyo Night"
        }
    }
    /// nil for System, which follows the Mac's appearance.
    public var isDark: Bool? { palette?.isDark }
}

/// Lexical token classes the review highlighter recognizes.
public enum SyntaxRole: Sendable, Hashable {
    case keyword, string, escape, comment, number, function, key, punctuation, operatorSymbol, builtin
}

public struct ThemeSyntaxPalette: Sendable {
    public let keyword, string, escape, comment, number, function, key, punctuation, operatorColor: String
    /// `self`, `this`, `super`.
    public let builtin: String
    /// Diff header lines: `@@` hunks, `diff --git` and `---`/`+++` paths. Other headers use comment.
    public let hunk, diffFile, diffPath: String
    public let italic: Set<SyntaxRole>
    public init(keyword: String, string: String, escape: String, comment: String, number: String,
                function: String, key: String, punctuation: String, operatorColor: String, builtin: String,
                hunk: String? = nil, diffFile: String? = nil, diffPath: String? = nil, italic: Set<SyntaxRole> = []) {
        self.keyword = keyword; self.string = string; self.escape = escape; self.comment = comment
        self.number = number; self.function = function; self.key = key; self.punctuation = punctuation
        self.operatorColor = operatorColor; self.builtin = builtin
        self.hunk = hunk ?? number; self.diffFile = diffFile ?? function; self.diffPath = diffPath ?? keyword
        self.italic = italic
    }
    public func color(_ role: SyntaxRole) -> String {
        switch role {
        case .keyword: return keyword
        case .string: return string
        case .escape: return escape
        case .comment: return comment
        case .number: return number
        case .function: return function
        case .key: return key
        case .punctuation: return punctuation
        case .operatorSymbol: return operatorColor
        case .builtin: return builtin
        }
    }
}

/// Semantic UI roles, named after Catppuccin's ladder (Base → Mantle → Crust for panes,
/// Surface for controls, Overlay 0–2 for borders and subtle text).
public struct ThemePalette: Sendable {
    public let isDark: Bool
    public let base, mantle, crust, surface, overlay0, overlay1, overlay2, text, secondary: String
    public let accent, green, red, yellow, blue, teal, orange: String
    /// Focused borders.
    public let activeBorder: String
    /// Text and icons on an accent fill.
    public let onAccent: String
    /// Selected list rows (sidebar threads) and their text.
    public let listSelection, listSelectionText: String
    public let cursor, cursorText: String
    public let selectionBackground: String
    public let selectionOpacity: Double
    /// Ghostty takes opaque RGB, so translucent selections are precomposed over Base.
    public let terminalSelectionBackground: String
    /// Hovered source lines are drawn over the text, so this is always translucent.
    public let lineHighlight: String
    public let lineHighlightOpacity: Double
    /// Opacity of added/deleted line backgrounds in diffs.
    public let diffLineOpacity: Double
    /// Find highlights: the current match and other matches. nil keeps the default (Red/Teal tints, yellow occurrences).
    public let findCurrent, findOther: String?
    /// Terminal palette in index order: ANSI 0–15, then any extended slots the theme defines.
    public let ansi: [String]

    public init(isDark: Bool, base: String, mantle: String, crust: String? = nil, surface: String,
                overlay0: String, overlay1: String, overlay2: String, text: String, secondary: String,
                accent: String, green: String, red: String, yellow: String, blue: String, teal: String, orange: String,
                activeBorder: String? = nil, onAccent: String? = nil, listSelection: String? = nil, listSelectionText: String? = nil,
                cursor: String, cursorText: String? = nil,
                selectionBackground: String, selectionOpacity: Double = 1, terminalSelectionBackground: String? = nil,
                lineHighlight: String? = nil, lineHighlightOpacity: Double = 0.08, diffLineOpacity: Double = 0.20,
                findCurrent: String? = nil, findOther: String? = nil, ansi: [String]) {
        self.isDark = isDark
        self.base = base; self.mantle = mantle; self.crust = crust ?? mantle; self.surface = surface
        self.overlay0 = overlay0; self.overlay1 = overlay1; self.overlay2 = overlay2
        self.text = text; self.secondary = secondary
        self.accent = accent; self.green = green; self.red = red; self.yellow = yellow
        self.blue = blue; self.teal = teal; self.orange = orange
        self.activeBorder = activeBorder ?? accent
        self.onAccent = onAccent ?? base
        self.listSelection = listSelection ?? accent; self.listSelectionText = listSelectionText ?? onAccent ?? base
        self.cursor = cursor; self.cursorText = cursorText ?? base
        self.selectionBackground = selectionBackground; self.selectionOpacity = selectionOpacity
        self.terminalSelectionBackground = terminalSelectionBackground
            ?? Self.composite(selectionBackground, opacity: selectionOpacity, over: base)
        self.lineHighlight = lineHighlight ?? text; self.lineHighlightOpacity = lineHighlightOpacity
        self.diffLineOpacity = diffLineOpacity; self.findCurrent = findCurrent; self.findOther = findOther
        self.ansi = ansi
    }

    /// `top` at `opacity` over `bottom`, as six-digit hex.
    public static func composite(_ top: String, opacity: Double, over bottom: String) -> String {
        guard let t = UInt32(top, radix: 16), let b = UInt32(bottom, radix: 16) else { return top }
        return [16, 8, 0].map { shift -> String in
            let value = Double((t >> shift) & 255) * opacity + Double((b >> shift) & 255) * (1 - opacity)
            return String(format: "%02x", Int(value.rounded()))
        }.joined()
    }
}
