import Foundation

/// A deliberately small, lossless block parser. Raw source is never replaced by
/// presentation text, including while a fence or table is still arriving.
public struct MarkdownDocument: Equatable, Sendable {
    public struct Block: Identifiable, Equatable, Sendable {
        public let id: Int // Starting line, stable as a streaming response grows.
        public let source: String
        public let kind: Kind
    }
    public enum Alignment: Equatable, Sendable { case leading, center, trailing }
    public enum Kind: Equatable, Sendable {
        case paragraph(String)
        case heading(Int, String)
        case listItem(marker: String, depth: Int, text: String)
        case quote(String)
        case code(language: String, text: String)
        case table(headers: [String], alignments: [Alignment], rows: [[String]])
        case spacing
    }
    public let source: String
    public let blocks: [Block]

    public init(_ source: String) {
        self.source = source
        var lines = source.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let raw = lines.enumerated().map { index, line in
            line + (index < lines.count - 1 || source.hasSuffix("\n") ? "\n" : "")
        }
        lines = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        var result: [Block] = []
        var i = 0
        while i < lines.count {
            if Task.isCancelled {
                let tail = raw[i...].joined()
                result.append(Block(id: i, source: tail, kind: .paragraph(tail)))
                break
            }
            let start = i
            let kind: Kind
            if lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                kind = .spacing
            } else if let fence = Self.fence(lines[i]) {
                i += 1
                let contentStart = i
                while i < lines.count && !Self.closes(lines[i], fence: fence) { i += 1 }
                let code = raw[contentStart..<i].joined()
                if i < lines.count { i += 1 }
                kind = .code(language: fence.info, text: code)
            } else if let heading = Self.match(Self.heading, lines[i]) {
                kind = .heading(heading[1].count, heading[2]); i += 1
            } else if let item = Self.match(Self.list, lines[i]) {
                var text = item[3]; i += 1
                // Indented continuations belong to this item; nested markers get
                // their own row. Preserve unsupported constructs as visible text.
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                      lines[i].prefix(while: { $0 == " " }).count > item[1].count,
                      !Self.startsBlock(lines[i]) {
                    text += "\n" + lines[i].trimmingCharacters(in: .whitespaces); i += 1
                }
                kind = .listItem(marker: item[2], depth: item[1].count / 2, text: text)
            } else if Self.quoteText(lines[i]) != nil {
                var text: [String] = []
                while i < lines.count, let quoted = Self.quoteText(lines[i]) {
                    text.append(quoted); i += 1
                }
                kind = .quote(text.joined(separator: "\n"))
            } else if i + 1 < lines.count, let headers = Self.cells(lines[i]),
                      let alignment = Self.tableAlignment(lines[i + 1]), headers.count == alignment.count {
                i += 2
                var rows: [[String]] = []
                // A partial/malformed row stays a paragraph instead of losing cells.
                while i < lines.count, let row = Self.cells(lines[i]), row.count == headers.count,
                      !Self.startsBlock(lines[i]) {
                    rows.append(row); i += 1
                }
                kind = .table(headers: headers, alignments: alignment, rows: rows)
            } else {
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                      !Self.startsBlock(lines[i]) {
                    if i + 1 < lines.count, let cells = Self.cells(lines[i]),
                       let align = Self.tableAlignment(lines[i + 1]), cells.count == align.count { break }
                    i += 1
                }
                kind = .paragraph(lines[start..<i].joined(separator: "\n"))
            }
            result.append(Block(id: start, source: raw[start..<i].joined(), kind: kind))
        }
        blocks = result
    }

    private static let heading = try! NSRegularExpression(pattern: #"^ {0,3}(#{1,6})[\t ]+(.+)$"#)
    private static let list = try! NSRegularExpression(pattern: #"^( *)([-+*]|[0-9]{1,9}[.)])[\t ]+(.+)$"#)
    private static func match(_ regex: NSRegularExpression, _ line: String) -> [String]? {
        let ns = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<match.numberOfRanges).map { ns.substring(with: match.range(at: $0)) }
    }
    private struct Fence { let marker: Character; let count: Int; let info: String }
    private static func fence(_ line: String) -> Fence? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return nil }
        let body = line.dropFirst(indent)
        guard let marker = body.first, marker == "`" || marker == "~" else { return nil }
        let count = body.prefix(while: { $0 == marker }).count
        let info = body.dropFirst(count).trimmingCharacters(in: .whitespaces)
        guard count >= 3, marker != "`" || !info.contains("`") else { return nil }
        return Fence(marker: marker, count: count, info: info)
    }
    private static func closes(_ line: String, fence: Fence) -> Bool {
        guard let closing = Self.fence(line) else { return false }
        return closing.marker == fence.marker && closing.count >= fence.count && closing.info.isEmpty
    }
    private static func quoteText(_ line: String) -> String? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return nil }
        var body = line.dropFirst(indent)
        guard body.first == ">" else { return nil }
        body = body.dropFirst()
        if body.first == " " { body = body.dropFirst() }
        return String(body)
    }
    private static func startsBlock(_ line: String) -> Bool {
        fence(line) != nil || match(heading, line) != nil || match(list, line) != nil || quoteText(line) != nil
    }
    /// Split only unescaped pipes outside matched code spans.
    private static func cells(_ line: String) -> [String]? {
        let chars = Array(line.trimmingCharacters(in: .whitespaces))
        var cells = [String](), cell = "", i = 0, ticks = 0, pipes = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                cell.append(c); cell.append(chars[i + 1]); i += 2; continue
            }
            if c == "`" {
                var end = i
                while end < chars.count && chars[end] == "`" { end += 1 }
                let count = end - i
                if ticks == count { ticks = 0 }
                else if ticks == 0 { ticks = count }
                cell += String(repeating: "`", count: count); i = end; continue
            }
            if c == "|", ticks == 0 { cells.append(cell); cell = ""; pipes += 1 }
            else { cell.append(c) }
            i += 1
        }
        guard pipes > 0 else { return nil }
        cells.append(cell)
        if chars.first == "|" { cells.removeFirst() }
        if chars.last == "|", cells.last == "" { cells.removeLast() }
        return cells.isEmpty ? nil : cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }
    private static func tableAlignment(_ line: String) -> [Alignment]? {
        guard let cells = cells(line) else { return nil }
        var result: [Alignment] = []
        for cell in cells {
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard dashes.count >= 3, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            result.append(cell.hasSuffix(":") ? (cell.hasPrefix(":") ? .center : .trailing) : .leading)
        }
        return result
    }
}

public enum MarkdownInline {
    public static func parse(_ source: String) -> AttributedString {
        // Foundation can conceal unfinished link destinations. Keep incomplete
        // inline syntax literal until it closes. Images/HTML stay literal too.
        guard isComplete(source), !source.contains("!["), !source.contains("<") else { return AttributedString(source) }
        return (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
    }

    private static func isComplete(_ source: String) -> Bool {
        let chars = Array(source)
        var i = 0, brackets = 0, parentheses = 0, ticks = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" { i += 2; continue }
            if c == "`" {
                var end = i
                while end < chars.count && chars[end] == "`" { end += 1 }
                if ticks == end - i { ticks = 0 } else if ticks == 0 { ticks = end - i }
                i = end; continue
            }
            if ticks == 0 {
                if c == "[" { brackets += 1 }
                if c == "]" { brackets = max(0, brackets - 1) }
                if c == "(", parentheses > 0 || (i > 0 && chars[i - 1] == "]") { parentheses += 1 }
                if c == ")", parentheses > 0 { parentheses -= 1 }
            }
            i += 1
        }
        // Foundation already preserves unmatched emphasis delimiters, including
        // underscores inside identifiers; only guard constructs that hide tails.
        return ticks == 0 && brackets == 0 && parentheses == 0
    }
}

/// Local Markdown destinations are resolved against the owning thread's checkout.
/// This is navigation only; GitService still performs bounded, no-follow file reads.
public struct MarkdownFileLink: Equatable, Sendable {
    public var path: String
    public var line: Int?
    public init?(url: URL, checkout: String) {
        let scheme = url.scheme?.lowercased()
        // Foundation interprets `README.md:12` as a URL with scheme `README.md`.
        let bareFile = scheme?.contains(".") == true && url.absoluteString.range(of: #"^[^/:]+:[1-9][0-9]*(?::[1-9][0-9]*)?$"#, options: .regularExpression) != nil
        guard scheme == nil || scheme == "file" || bareFile, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil else { return nil }
        var path = bareFile ? (url.absoluteString.removingPercentEncoding ?? url.absoluteString) : url.path
        guard !path.isEmpty else { return nil }
        var line: Int?
        if let fragment = url.fragment {
            guard let match = fragment.range(of: #"^L?([1-9][0-9]*)(?:C[1-9][0-9]*)?(?:-L?[1-9][0-9]*)?$"#, options: .regularExpression) else { return nil }
            let digits = fragment[match].drop(while: { $0 == "L" }).prefix(while: \.isNumber)
            line = Int(digits)
            guard line != nil else { return nil }
        }
        if let suffix = path.range(of: #":[1-9][0-9]*(?::[1-9][0-9]*)?$"#, options: .regularExpression) {
            let digits = path[suffix].dropFirst().prefix(while: \.isNumber)
            if line == nil { line = Int(digits) }
            path.removeSubrange(suffix)
        }
        let root = URL(fileURLWithPath: checkout).standardizedFileURL.path
        let destination = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: root).appendingPathComponent(path)).standardizedFileURL.path
        let prefix = root == "/" ? "/" : root + "/"
        guard destination.hasPrefix(prefix), destination.count > prefix.count else { return nil }
        self.path = String(destination.dropFirst(prefix.count)); self.line = line
    }
}
