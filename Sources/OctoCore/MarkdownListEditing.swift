import Foundation

/// Markdown list editing for the plain-text composer: Shift-Return continues a list or quote, and
/// Tab / Shift-Tab nest list items. Ranges are UTF-16, as in `NSTextView`.
public enum MarkdownListEditing {
    public struct Edit: Equatable, Sendable {
        /// The characters to replace and their replacement.
        public var range: NSRange
        public var replacement: String
        public var selection: NSRange
    }

    /// One line's list or quote prefix: indentation, marker and the spaces after it.
    struct Line {
        enum Marker: Equatable { case bullet(Character), ordered(Int, Character), quote }
        var indent: Int
        var marker: Marker
        var spacing: Int
        /// A task item's `[ ]` or `[x]` and its following space, which belongs to the content.
        var checkbox: Bool
        /// Characters before the content.
        var prefixLength: Int { indent + markerText.count + spacing }
        var markerText: String {
            switch marker {
            case .bullet(let c): String(c)
            case .ordered(let n, let delimiter): "\(n)\(delimiter)"
            case .quote: ">"
            }
        }
        var isListItem: Bool { marker != .quote }

        init?(_ text: String) {
            let scalars = Array(text)
            var i = 0
            while i < scalars.count, scalars[i] == " " { i += 1 }
            indent = i
            guard i < scalars.count else { return nil }
            if "-*+".contains(scalars[i]) {
                marker = .bullet(scalars[i]); i += 1
            } else if scalars[i] == ">" {
                marker = .quote; i += 1
            } else {
                var digits = ""
                while i < scalars.count, scalars[i].isASCII, scalars[i].isNumber, digits.count < 9 { digits.append(scalars[i]); i += 1 }
                guard !digits.isEmpty, i < scalars.count, scalars[i] == "." || scalars[i] == ")", let number = Int(digits) else { return nil }
                marker = .ordered(number, scalars[i]); i += 1
            }
            // A marker needs a following space (a bare quote marker is allowed), else `-1` or `2.5` would count.
            var spaces = 0
            while i < scalars.count, scalars[i] == " " { spaces += 1; i += 1 }
            if spaces == 0 && !(marker == .quote && i == scalars.count) { return nil }
            spacing = spaces
            checkbox = marker != .quote && scalars.count >= i + 3
                && scalars[i] == "[" && " xX".contains(scalars[i + 1]) && scalars[i + 2] == "]"
                && (scalars.count == i + 3 || scalars[i + 3] == " ")
        }

        func with(indent: Int, number: Int? = nil) -> String {
            var marker = marker
            if case .ordered(_, let delimiter) = marker, let number { marker = .ordered(number, delimiter) }
            var line = self; line.indent = indent; line.marker = marker
            return String(repeating: " ", count: indent) + line.markerText + String(repeating: " ", count: spacing)
        }
    }

    /// Shift-Return at a caret after a list or quote marker. An empty item ends the list: nested
    /// items step out one level, top-level ones lose their marker. Nil inserts a plain newline.
    public static func newline(in text: String, selection: NSRange) -> Edit? {
        let string = text as NSString
        guard selection.length == 0 else { return nil }
        let lineRange = string.lineRange(for: NSRange(location: selection.location, length: 0))
        let content = lineContent(string, lineRange)
        guard let line = Line(content.text), selection.location - lineRange.location >= line.prefixLength else { return nil }
        let body = (content.text as NSString).substring(from: line.prefixLength)
        if (line.checkbox ? String(body.dropFirst(3)) : body).trimmingCharacters(in: .whitespaces).isEmpty {
            if line.isListItem, line.indent > 0, let outdented = outdent(in: text, selection: selection) { return outdented }
            let range = NSRange(location: lineRange.location, length: content.length)
            return Edit(range: range, replacement: "", selection: NSRange(location: lineRange.location, length: 0))
        }
        var next = String(repeating: " ", count: line.indent)
        switch line.marker {
        case .bullet, .quote: next += line.markerText
        case .ordered(let n, let delimiter): next += "\(n + 1)\(delimiter)"
        }
        next += String(repeating: " ", count: max(1, line.spacing)) + (line.checkbox ? "[ ] " : "")
        let inserted = "\n" + next
        return Edit(range: selection, replacement: inserted, selection: NSRange(location: selection.location + (inserted as NSString).length, length: 0))
    }

    /// Tab: nests each selected list item under the item above it at its level, aligning with that
    /// item's content as CommonMark requires; ordered items restart at 1. Nil when no line changes.
    public static func indent(in text: String, selection: NSRange) -> Edit? {
        reindent(text, selection) { lines, index, line in
            // The nearest earlier item at this level becomes the parent; stop at a blank or non-list line.
            var j = index - 1, parent: Line?, sibling: Line?
            while j >= 0, let candidate = Line(lines[j]), candidate.isListItem {
                if candidate.indent == line.indent { parent = candidate; break }
                if candidate.indent < line.indent { break }
                j -= 1
            }
            guard let parent else { return nil }
            let level = parent.prefixLength
            for k in stride(from: index - 1, to: j, by: -1) {
                if let candidate = Line(lines[k]), candidate.indent == level { sibling = candidate; break }
            }
            if case .ordered(let n, _)? = sibling?.marker { return line.with(indent: level, number: n + 1) }
            return line.with(indent: level, number: 1)
        }
    }

    /// Shift-Tab: moves each selected nested item out to its parent's level, numbered after it.
    public static func outdent(in text: String, selection: NSRange) -> Edit? {
        reindent(text, selection) { lines, index, line in
            guard line.indent > 0 else { return nil }
            var j = index - 1
            while j >= 0, let candidate = Line(lines[j]), candidate.isListItem {
                if candidate.indent < line.indent {
                    if case .ordered(let n, _) = candidate.marker { return line.with(indent: candidate.indent, number: n + 1) }
                    return line.with(indent: candidate.indent)
                }
                j -= 1
            }
            return line.with(indent: 0)
        }
    }

    /// Whether the caret's line, or any selected line, is a list item, so Tab belongs to the list.
    public static func isInList(_ text: String, selection: NSRange) -> Bool {
        let string = text as NSString
        let lines = string.lineRange(for: selection)
        var found = false
        string.enumerateSubstrings(in: lines, options: [.byLines, .substringNotRequired]) { _, range, _, stop in
            if Line(string.substring(with: range))?.isListItem == true { found = true; stop.pointee = true }
        }
        return found
    }

    private static func lineContent(_ string: NSString, _ lineRange: NSRange) -> (text: String, length: Int) {
        var length = lineRange.length
        while length > 0, [10, 13].contains(string.character(at: lineRange.location + length - 1)) { length -= 1 }
        return (string.substring(with: NSRange(location: lineRange.location, length: length)), length)
    }

    /// Rewrites the prefix of each selected list line. `prefix` sees the lines as already rewritten
    /// above it and returns the new prefix, or nil to leave the line alone.
    private static func reindent(_ text: String, _ selection: NSRange,
                                 prefix: (_ lines: [String], _ index: Int, _ line: Line) -> String?) -> Edit? {
        let string = text as NSString
        let span = string.lineRange(for: selection)
        // Every line up to the selection's end, so parents above the selection are visible.
        let head = NSRange(location: 0, length: NSMaxRange(span))
        var lines: [String] = [], starts: [Int] = []
        string.enumerateSubstrings(in: head, options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            lines.append(string.substring(with: range)); starts.append(range.location)
        }
        if NSMaxRange(span) == string.length, string.length == 0 || [10, 13].contains(string.character(at: string.length - 1)) {
            lines.append(""); starts.append(string.length)
        }
        guard let first = starts.lastIndex(where: { $0 <= span.location }) else { return nil }
        let last = starts.lastIndex(where: { $0 <= max(span.location, NSMaxRange(selection) - (selection.length > 0 ? 1 : 0)) }) ?? first
        let originals = lines
        var changed = false
        var caret = selection
        for index in first...last {
            guard let line = Line(lines[index]), line.isListItem, let newPrefix = prefix(lines, index, line) else { continue }
            let old = lines[index]
            let rest = (old as NSString).substring(from: line.prefixLength)
            lines[index] = newPrefix + rest
            let delta = (newPrefix as NSString).length - line.prefixLength
            if delta != 0 || newPrefix != (old as NSString).substring(to: line.prefixLength) { changed = true }
            if selection.length == 0 {
                let offset = selection.location - starts[index]
                caret = NSRange(location: starts[index] + max((newPrefix as NSString).length, offset + delta), length: 0)
            }
        }
        guard changed else { return nil }
        // Replace the lines' contents only; their line breaks stay where they are.
        let start = starts[first]
        let end = starts[last] + (originals[last] as NSString).length
        let replacement = lines[first...last].joined(separator: "\n")
        let newSelection = selection.length == 0 ? caret : NSRange(location: start, length: (replacement as NSString).length)
        return Edit(range: NSRange(location: start, length: end - start), replacement: replacement, selection: newSelection)
    }
}
