import AppKit
import SwiftUI
import OctoCore

/// The messages matching the last searched query.
struct ThreadFindResults: Equatable {
    var query = ""
    var ids: [UUID] = []
}

/// ⌘F's bar: a glass capsule floating over the top of the transcript, which scrolls beneath it,
/// in the style of the sidebar's search field and the titlebar's button capsule. It is mounted only
/// while find is open, so it takes focus as it appears and a closed field is never a Tab stop.
/// It observes the query itself, so typing re-renders only this bar; the transcript changes when
/// debounced results arrive.
struct ThreadFindBar: View {
    @ObservedObject var find: ThreadFindModel
    let focusRequest: Int
    let messages: [ChatMessage]
    @Binding var results: ThreadFindResults
    let matchIndex: Int
    let close: () -> Void
    @Environment(\.octoTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.secondary)
                SearchInputField(placeholder: "Find in this thread", focusRequest: focusRequest, autofocus: true, identifier: "OctoThreadFind", plain: true,
                                 text: $find.query, move: { find.move($0) }, submit: { find.move(1) }, cancel: close)
                    .frame(height: 22).accessibilityLabel("Find in this thread")
                Text(status).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(theme.secondary).lineLimit(1).fixedSize()
            }.padding(.leading, 12).padding(.trailing, 6)
            Button { find.move(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(CapsuleToolbarButtonStyle()).disabled(results.ids.isEmpty)
                .help("Previous match (⇧⌘G)").accessibilityLabel("Previous match")
            Button { find.move(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(CapsuleToolbarButtonStyle()).disabled(results.ids.isEmpty)
                .help("Next match (⌘G)").accessibilityLabel("Next match")
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(CapsuleToolbarButtonStyle())
                .help("Close search (Escape)").accessibilityLabel("Close search")
        }
        .padding(2).frame(maxWidth: 560).glassControl()
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 4)
            // Searching waits for a pause in typing and runs off the main thread; streamed text re-searches.
            .task(id: SearchKey(query: find.query, count: messages.count, tail: messages.last?.text.count ?? 0)) {
                let query = find.query
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if results != ThreadFindResults(query: query) { results = ThreadFindResults(query: query) }
                    return
                }
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                let messages = messages
                let ids = await Task.detached(priority: .userInitiated) { ThreadFind.matches(query, in: messages) }.value
                guard !Task.isCancelled else { return }
                let next = ThreadFindResults(query: query, ids: ids)
                if results != next { results = next }
            }
    }

    private var status: String {
        guard !results.query.isEmpty else { return "" }
        guard !results.ids.isEmpty else { return "No matches" }
        return "\(min(matchIndex + 1, results.ids.count)) of \(results.ids.count) \(results.ids.count == 1 ? "message" : "messages")"
    }

    private struct SearchKey: Equatable { let query: String; let count: Int; let tail: Int }
}

/// The find query to highlight in a matching message; `current` is the message ⌘G is on.
struct FindHighlight: Equatable {
    let query: String
    let current: Bool
}

private struct FindHighlightKey: EnvironmentKey { static let defaultValue: FindHighlight? = nil }
extension EnvironmentValues {
    var findHighlight: FindHighlight? {
        get { self[FindHighlightKey.self] }
        set { self[FindHighlightKey.self] = newValue }
    }
}

extension AttributedString {
    /// Marks each occurrence as Safari's find does: the current message's in solid yellow with dark
    /// text so it reads in every theme, other matches tinted.
    func highlighting(_ highlight: FindHighlight?, theme: AppTheme) -> AttributedString {
        guard let highlight else { return self }
        let text = String(characters)
        let ranges = ThreadFind.ranges(of: highlight.query, in: text)
        guard !ranges.isEmpty else { return self }
        var value = self
        for range in ranges {
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            let length = text.distance(from: range.lowerBound, to: range.upperBound)
            let start = value.characters.index(value.startIndex, offsetBy: offset)
            let end = value.characters.index(start, offsetBy: length)
            if let palette = theme.palette, let current = palette.findCurrent, let other = palette.findOther {
                // Themes with their own find colors (Catppuccin: Red current, Sky others, at 30%).
                value[start..<end].backgroundColor = Color(nsColor: NSColor(themeHex: highlight.current ? current : other)).opacity(0.30)
            } else if highlight.current {
                value[start..<end].backgroundColor = Color(nsColor: NSColor(srgbRed: 1, green: 0.84, blue: 0.2, alpha: 1))
                value[start..<end].foregroundColor = .black
            } else {
                value[start..<end].backgroundColor = theme.yellow.opacity(0.35)
            }
        }
        return value
    }
}
