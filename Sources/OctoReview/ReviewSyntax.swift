import AppKit
import OctoCore

/// Small lexical highlighter, not a language grammar or semantic analysis engine.
/// It only changes attributes; all offsets remain in ReviewDocument's UTF-16 coordinates.
enum ReviewSyntax {
    struct State { var blockDepth = 0; var stringDelimiter: String? }
    private static let keywords = Set("import public private internal struct class enum func let var return if else guard case switch async await throw throws const function export def from for while in try catch do new static void override protocol extension mutating init self super as is nil true false null None True False fn pub use impl match mod type interface async await break continue default yield with lambda pass raise except finally package protected final val fun when object".split(separator: " ").map(String.init))
    private static let token = try! NSRegularExpression(pattern: #"//.*|/\*|\"\"\"|'''|`|\"(?:\\.|[^\"\\])*\"?|'(?:\\.|[^'\\])*'?|\b(?:0[xX][0-9a-fA-F_]+|\d[\d_]*(?:\.\d[\d_]*)?)\b|[\p{L}_][\p{L}\p{N}_]*|[+*/%=!<>?&|^~\-]+|[{}\[\](),;.:]|#.*"#)
    private static let pythonToken = try! NSRegularExpression(pattern: token.pattern.replacingOccurrences(of: #"//.*|/\*|"#, with: ""))
    private static let escapes = try! NSRegularExpression(pattern: #"\\."#)

    static func apply(to result: NSMutableAttributedString, document: ReviewDocument, theme: AppTheme) {
        let ext = (document.snapshot.path as NSString).pathExtension.lowercased()
        let python = ["py", "pyi"].contains(ext)
        let json = ["json", "jsonc"].contains(ext)
        guard python || json || ["swift", "js", "jsx", "ts", "tsx", "c", "h", "cc", "cpp", "hpp", "m", "mm", "rs", "go", "java", "kt", "kts", "cs"].contains(ext) else { return }
        var old = State(), new = State()
        for segment in document.segments {
            if segment.line.kind == .header {
                if segment.line.text.hasPrefix("@@") { old = State(); new = State() }
                continue
            }
            let spans: [(NSRange, String?)]
            switch segment.line.kind {
            case .deletion: spans = scan(segment.line.text, state: &old, python: python, json: json, theme: theme)
            case .addition: spans = scan(segment.line.text, state: &new, python: python, json: json, theme: theme)
            default:
                let oldSpans = scan(segment.line.text, state: &old, python: python, json: json, theme: theme)
                let newSpans = scan(segment.line.text, state: &new, python: python, json: json, theme: theme)
                spans = document.side == .before ? oldSpans : newSpans
            }
            for (range, hex) in spans {
                // System appearance also benefits from lexical isolation, using native colors.
                if let hex {
                    let target = NSRange(location: segment.contentRange.location + range.location, length: range.length)
                    result.addAttribute(.foregroundColor, value: NativeDiffView.color(hex, fallback: .labelColor), range: target)
                    if theme == .dracula && (hex == theme.syntax?.comment || hex == theme.palette?.accent) {
                        let font = NSFontManager.shared.convert(NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), toHaveTrait: .italicFontMask)
                        result.addAttribute(.font, value: font, range: target)
                    }
                }
            }
        }
    }

    private static func scan(_ text: String, state: inout State, python: Bool, json: Bool, theme: AppTheme) -> [(NSRange, String?)] {
        let source = text as NSString, p = theme.palette, colors = theme.syntax
        var offset = 0, spans: [(NSRange, String?)] = []
        func append(_ range: NSRange, _ color: String?) { spans.append((range, color)) }
        func nextCharacter() -> unichar? {
            var index = offset
            while index < source.length && (source.character(at: index) == 32 || source.character(at: index) == 9) { index += 1 }
            return index < source.length ? source.character(at: index) : nil
        }
        func string(_ range: NSRange) {
            append(range, colors?.string)
            for escape in escapes.matches(in: text, range: range) { append(escape.range, colors?.escape) }
        }
        while offset < source.length {
            let remaining = NSRange(location: offset, length: source.length - offset)
            if state.blockDepth > 0 {
                let close = source.range(of: "*/", range: remaining)
                let open = source.range(of: "/*", range: remaining)
                let nested = open.location != NSNotFound && (close.location == NSNotFound || open.location < close.location)
                let boundary = nested ? open : close
                let end = boundary.location == NSNotFound ? source.length : NSMaxRange(boundary)
                append(NSRange(location: offset, length: end - offset), colors?.comment)
                if boundary.location != NSNotFound { state.blockDepth += nested ? 1 : -1 }
                offset = end; continue
            }
            if let delimiter = state.stringDelimiter {
                var end = offset
                while end < source.length {
                    if source.character(at: end) == 92 { end = min(end + 2, source.length); continue }
                    if end + delimiter.utf16.count <= source.length && source.substring(with: NSRange(location: end, length: delimiter.utf16.count)) == delimiter {
                        end += delimiter.utf16.count; state.stringDelimiter = nil; break
                    }
                    end += 1
                }
                string(NSRange(location: offset, length: end - offset))
                offset = end; continue
            }
            guard let match = (python ? pythonToken : token).firstMatch(in: text, range: remaining) else { break }
            let value = source.substring(with: match.range)
            offset = NSMaxRange(match.range)
            let color: String?
            if !python && value == "/*" { state.blockDepth = 1; color = colors?.comment }
            else if (!python && value.hasPrefix("//")) || (python && value.hasPrefix("#")) { color = colors?.comment }
            else if value == "\"\"\"" || (python && value == "'''") || (!python && value == "`") { state.stringDelimiter = value; color = colors?.string }
            else if value.hasPrefix("\"") || value.hasPrefix("'") {
                if json && nextCharacter() == 58 { color = colors?.key }
                else { string(match.range); continue }
            }
            else if value.first?.isNumber == true { color = colors?.number }
            else if ["true", "false", "nil", "null", "None", "True", "False"].contains(value) { color = colors?.number }
            else if theme == .dracula && ["this", "self", "super"].contains(value) { color = p?.accent }
            else if keywords.contains(value) { color = colors?.keyword ?? "af52de" }
            else if value.first?.isLetter == true || value.hasPrefix("_") {
                color = nextCharacter() == 40 ? colors?.function : nil
            }
            else if value.rangeOfCharacter(from: CharacterSet(charactersIn: "{}[](),;.:")) != nil { color = colors?.punctuation }
            else { color = colors?.operatorColor }
            append(match.range, color)
        }
        return spans
    }
}
