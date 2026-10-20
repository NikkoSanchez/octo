import Foundation

/// Chat search, as in the ⌘K palette: every word must appear in the title, the project name or a
/// message. Title matches rank first, then the most recently active.
public enum ThreadSearch {
    public struct Result: Equatable, Identifiable, Sendable {
        public let threadID: UUID
        public let projectID: UUID
        /// The newest matching message around its first match, or nil when the title or project
        /// name matched every word on its own.
        public let snippet: String?
        public var id: UUID { threadID }
    }

    public static func words(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public static func results(_ query: String, in threads: [RecentThread], limit: Int = 60) -> [Result] {
        let words = words(query)
        guard !words.isEmpty else { return [] }
        var titled: [(Date, Result)] = [], other: [(Date, Result)] = []
        for entry in threads {
            let thread = entry.thread
            let header = thread.title + " " + entry.project.name
            let missing = words.filter { !header.localizedStandardContains($0) }
            let texts = thread.messages.lazy.filter { ($0.role == .assistant || $0.role == .user) && !$0.text.isEmpty }.map(\.text)
            guard missing.allSatisfy({ word in texts.contains { $0.localizedStandardContains(word) } }) else { continue }
            // Show the words the title doesn't, or else the first word, in context.
            let shown = missing.first ?? words[0]
            let snippet = missing.isEmpty ? nil : thread.messages.reversed().lazy
                .filter { ($0.role == .assistant || $0.role == .user) && !$0.text.isEmpty }
                .compactMap { snippetText($0.text, around: shown) }.first
            let result = Result(threadID: thread.id, projectID: entry.project.id, snippet: snippet)
            if thread.title.localizedStandardContains(words[0]) && missing.isEmpty { titled.append((thread.recentAt, result)) }
            else { other.append((thread.recentAt, result)) }
        }
        let ordered = titled.sorted { $0.0 > $1.0 } + other.sorted { $0.0 > $1.0 }
        return ordered.prefix(limit).map(\.1)
    }

    /// One line of the message around `word`, whitespace collapsed, with ellipses where cut.
    static func snippetText(_ text: String, around word: String, before: Int = 30, after: Int = 90) -> String? {
        guard let match = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = text.index(match.lowerBound, offsetBy: -before, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(match.upperBound, offsetBy: after, limitedBy: text.endIndex) ?? text.endIndex
        let body = text[start..<end].replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return (start > text.startIndex ? "…" : "") + body + (end < text.endIndex ? "…" : "")
    }
}
