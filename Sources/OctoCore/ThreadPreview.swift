import Foundation

/// The one-line summary under a sidebar thread title, after Messages' last-message preview.
public enum ThreadPreview {
    /// Only the head of a reply is read; previews show one line.
    static let readLimit = 600, length = 160

    /// The newest reply, or the user's own last message when nothing has answered it yet.
    public static func text(_ thread: WorkspaceThread) -> String? {
        guard let message = thread.messages.last(where: { ($0.role == .assistant || $0.role == .user) && !$0.text.isEmpty }) else { return nil }
        let text = plain(message.text)
        guard !text.isEmpty else { return nil }
        return message.role == .user ? "You: " + text : text
    }

    /// Markdown reduced to readable inline text: code blocks, headings, quotes and list markers
    /// removed, inline formatting resolved, whitespace collapsed.
    public static func plain(_ markdown: String) -> String {
        var lines: [Substring] = [], fenced = false
        for line in markdown.prefix(readLimit).split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle(); continue }
            if fenced { continue }
            lines.append(stripBlockMarker(trimmed))
        }
        // The transcript's own inline parser drops emphasis markers, code ticks and link targets.
        var text = String(MarkdownInline.parse(lines.joined(separator: " ")).characters)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return text.count > length ? String(text.prefix(length - 1)).trimmingCharacters(in: .whitespaces) + "…" : text
    }

    private static func stripBlockMarker(_ line: Substring) -> Substring {
        var line = line
        while let first = line.first, first == "#" || first == ">" { line = line.dropFirst().drop { $0 == " " } }
        if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " { return line.dropFirst(2) }
        if let dot = line.firstIndex(where: { !$0.isNumber }), dot != line.startIndex,
           line[dot] == "." || line[dot] == ")", line[line.index(after: dot)...].first == " " {
            return line[line.index(dot, offsetBy: 2)...]
        }
        return line
    }
}
