import Foundation

/// Find in the current thread (⌘F). It searches the messages shown in the transcript (the user's,
/// the agent's replies and errors), not the collapsed activity and reasoning, so every match can
/// be scrolled to and highlighted where it is read.
public enum ThreadFind {
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    public static func isSearchable(_ role: ChatMessage.Role) -> Bool { role == .user || role == .assistant || role == .error }

    /// The searchable messages containing `query`, in transcript order. Blank queries match nothing.
    public static func matches(_ query: String, in messages: [ChatMessage]) -> [UUID] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return messages.compactMap { message in
            guard isSearchable(message.role), !Task.isCancelled else { return nil }
            return message.text.range(of: query, options: options) != nil ? message.id : nil
        }
    }

    /// Every occurrence of `query` in `text`, for highlighting.
    public static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var result: [Range<String.Index>] = [], start = text.startIndex
        while start < text.endIndex, let range = text.range(of: query, options: options, range: start..<text.endIndex) {
            result.append(range)
            start = range.isEmpty ? text.index(after: range.lowerBound) : range.upperBound
        }
        return result
    }
}
