import Foundation

/// Chat search, as in the ⌘K palette: the query must appear as a phrase (ignoring case, accents
/// and runs of whitespace) in the title, the project name or one user/assistant message. Title
/// matches rank first, then the most recently active.
public enum ThreadSearch {
    public struct Result: Equatable, Identifiable, Sendable {
        public let threadID: UUID
        public let projectID: UUID
        /// The newest matching message around its match, or nil when the title or project name matched.
        public let snippet: String?
        public var id: UUID { threadID }
    }

    /// A query normalized once for repeated matching.
    public struct Phrase: @unchecked Sendable {
        let text: String
        /// The words separated by any run of whitespace, for text that wraps mid-phrase.
        let pattern: NSRegularExpression?
        /// The longest word: text without it cannot match the pattern either.
        let longestWord: String
        // NSString search is about ten times faster here than String.range(of:options:).
        private static let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        public init?(_ query: String) {
            let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let longest = words.max(by: { $0.count < $1.count }) else { return nil }
            text = words.joined(separator: " ")
            longestWord = longest
            pattern = words.count > 1 ? try? NSRegularExpression(
                pattern: words.map(NSRegularExpression.escapedPattern).joined(separator: #"\s+"#), options: .caseInsensitive) : nil
        }
        public func range(in candidate: String) -> Range<String.Index>? {
            let string = candidate as NSString
            var match = string.range(of: text, options: Self.options)
            if match.location == NSNotFound, let pattern, string.range(of: longestWord, options: Self.options).location != NSNotFound {
                match = pattern.firstMatch(in: candidate, range: NSRange(location: 0, length: string.length))?.range ?? match
            }
            return match.location == NSNotFound ? nil : Range(match, in: candidate)
        }
        public func matches(_ candidate: String) -> Bool { range(in: candidate) != nil }
    }

    public static func results(_ query: String, in threads: [RecentThread], limit: Int = 60) -> [Result] {
        guard let phrase = Phrase(query) else { return [] }
        var titled: [(Date, Result)] = [], other: [(Date, Result)] = []
        for entry in threads {
            let thread = entry.thread
            if phrase.matches(thread.title) {
                titled.append((thread.recentAt, Result(threadID: thread.id, projectID: entry.project.id, snippet: nil)))
                continue
            }
            let snippet = thread.messages.reversed().lazy
                .filter { ($0.role == .assistant || $0.role == .user) && !$0.text.isEmpty }
                .compactMap { message in phrase.range(in: message.text).map { snippetText(message.text, around: $0) } }.first
            guard snippet != nil || phrase.matches(entry.project.name) else { continue }
            other.append((thread.recentAt, Result(threadID: thread.id, projectID: entry.project.id, snippet: snippet)))
        }
        let ordered = titled.sorted { $0.0 > $1.0 } + other.sorted { $0.0 > $1.0 }
        return ordered.prefix(limit).map(\.1)
    }

    /// One line of the message around `match`, whitespace collapsed, with ellipses where cut.
    static func snippetText(_ text: String, around match: Range<String.Index>, before: Int = 30, after: Int = 90) -> String {
        let start = text.index(match.lowerBound, offsetBy: -before, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(match.upperBound, offsetBy: after, limitedBy: text.endIndex) ?? text.endIndex
        let body = text[start..<end].replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return (start > text.startIndex ? "…" : "") + body + (end < text.endIndex ? "…" : "")
    }
}
