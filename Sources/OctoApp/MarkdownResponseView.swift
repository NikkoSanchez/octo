import AppKit
import SwiftUI
import OctoCore

/// Parsing and inline interpretation are cached per response, never per keystroke
/// in the composer. A canceled streaming parse cannot overwrite a newer result.
struct MarkdownResponseView: View {
    let source: String
    @Environment(\.octoTheme) private var theme
    @State private var rendered: RenderedMarkdown?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Publish complete parsed snapshots only. A literal tail in its own
            // Text creates a temporary extra paragraph on every streamed update,
            // then removes it after parsing, making layout and follow-scroll bounce.
            ForEach(visibleBlocks) { block in
                if let rendered {
                    blockView(block.kind, inline: rendered.inline)
                }
            }
        }
        .font(.system(size: 14)).foregroundStyle(theme.prose)
        .lineSpacing(6)
        .textSelection(.enabled).tint(theme.blue)
        .task(id: source) {
            let source = source
            let previous = rendered
            let work = Task.detached(priority: .userInitiated) { RenderedMarkdown(source, previous: previous) }
            let value = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard !Task.isCancelled else { return }
            rendered = value
        }
    }

    private var visibleBlocks: [MarkdownDocument.Block] {
        guard let rendered, source.hasPrefix(rendered.document.source) else { return [] }
        return rendered.document.blocks
    }

    @ViewBuilder private func blockView(_ block: MarkdownDocument.Kind, inline: [String: AttributedString]) -> some View {
        switch block {
        case .paragraph(let text):
            inlineText(text, inline: inline).frame(maxWidth: .infinity, alignment: .leading)
        case .heading(let level, let text):
            let size = [22.0, 19, 17, 15, 14, 14][level - 1]
            inlineText(text, inline: inline, size: size)
                .font(.system(size: size, weight: .semibold)).foregroundStyle(theme.foreground)
                .accessibilityAddTraits(.isHeader).padding(.top, 4)
        case .listItem(let marker, let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: marker.count == 1 ? "•" : marker).foregroundStyle(theme.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
                inlineText(text, inline: inline).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.leading, CGFloat(min(depth, 12)) * 16)
        case .quote(let text):
            inlineText(text, inline: inline).foregroundStyle(theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(theme.border).frame(width: 3) }
        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(verbatim: language.isEmpty ? "Code" : language).lineLimit(1)
                    Spacer()
                    Button { copyResponseText(text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .buttonStyle(HoverButtonStyle()).accessibilityLabel("Copy code")
                }.font(.system(size: 12)).lineSpacing(0).foregroundStyle(theme.secondary).padding(8)
                Divider()
                ScrollView(.horizontal) {
                    Text(verbatim: text).font(.system(size: 13, design: .monospaced))
                        .lineSpacing(3)
                        .fixedSize(horizontal: true, vertical: true).padding(10)
                }
            }.background(theme.panel, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.border.opacity(0.5)))
        case .table(let headers, let alignments, let rows):
            MarkdownTable(columns: headers.count) {
                tableCells(headers, alignments: alignments, inline: inline, header: true)
                ForEach(rows.indices, id: \.self) { index in
                    tableCells(rows[index], alignments: alignments, inline: inline, header: false)
                }
            }.padding(.vertical, 6)
        case .spacing:
            EmptyView()
        }
    }

    private func tableCells(_ cells: [String], alignments: [MarkdownDocument.Alignment], inline: [String: AttributedString], header: Bool) -> some View {
        ForEach(cells.indices, id: \.self) { index in
            inlineText(cells[index], inline: inline).fontWeight(header ? .semibold : .regular)
                .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignments[index] == .center ? .top : alignments[index] == .trailing ? .topTrailing : .topLeading)
                .padding(.horizontal, 10).padding(.vertical, 12)
                .overlay(alignment: .bottom) { Rectangle().fill(theme.border.opacity(header ? 0.45 : 0.18)).frame(height: 1) }
        }
    }

    private func inlineText(_ source: String, inline: [String: AttributedString], size: CGFloat = 14) -> Text {
        var value = inline[source] ?? AttributedString(source)
        for run in value.runs {
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                value[run.range].font = .system(size: 13, design: .monospaced)
                value[run.range].backgroundColor = theme.surface
            } else if intent.contains(.stronglyEmphasized) {
                // The intent renders SF Bold (700), which reads heavy at body sizes; use
                // semibold as web UIs do. Italic still applies through the remaining intent.
                value[run.range].inlinePresentationIntent = intent.subtracting(.stronglyEmphasized)
                value[run.range].font = .system(size: size, weight: .semibold)
            }
            if intent.contains(.stronglyEmphasized) { value[run.range].foregroundColor = theme.foreground }
            if run.link != nil { value[run.range].foregroundColor = theme.blue }
        }
        return Text(value)
    }
}

struct RenderedMarkdown: Sendable {
    let document: MarkdownDocument
    var inline: [String: AttributedString] = [:]
    init(_ source: String, previous: RenderedMarkdown? = nil) {
        document = MarkdownDocument(source)
        for block in document.blocks {
            if Task.isCancelled { break }
            let texts: [String]
            switch block.kind {
            case .paragraph(let text), .heading(_, let text), .listItem(_, _, let text), .quote(let text): texts = [text]
            case .table(let headers, _, let rows): texts = headers + rows.flatMap { $0 }
            case .code, .spacing: texts = []
            }
            // Completed blocks usually remain unchanged while the last one grows.
            // Reuse their inline interpretation without retaining obsolete tails.
            for text in texts {
                inline[text] = inline[text] ?? previous?.inline[text] ?? MarkdownInline.parse(text)
            }
        }
    }
}

func copyResponseText(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Tables fill the transcript width. Only genuinely wide tables scroll horizontally.
private struct MarkdownTable<Content: View>: View {
    let columns: Int
    @ViewBuilder var content: () -> Content
    @State private var availableWidth: CGFloat = 600
    var body: some View {
        ScrollView(.horizontal) {
            MarkdownTableLayout(columns: columns) { content() }
                .frame(width: max(availableWidth, CGFloat(columns) * 110))
        }.frame(maxWidth: .infinity)
            .background(GeometryReader { proxy in
                Color.clear.onAppear { availableWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in availableWidth = width }
            })
    }
}

/// Measure wrapped cells before placing each row; no fixed row heights or truncation.
struct MarkdownTableLayout: Layout {
    let columns: Int
    func measurements(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (widths: [CGFloat], heights: [CGFloat]) {
        guard columns > 0 else { return ([], []) }
        var desired = Array(repeating: CGFloat(110), count: columns)
        for i in subviews.indices {
            desired[i % columns] = max(desired[i % columns], min(440, subviews[i].sizeThatFits(.unspecified).width))
        }
        let width = max(CGFloat(columns) * 110, proposal.width ?? desired.reduce(0, +))
        let flexible = desired.map { max(1, $0 - 110) }, total = flexible.reduce(0, +)
        let widths = flexible.map { 110 + (width - CGFloat(columns) * 110) * $0 / total }
        var heights = Array(repeating: CGFloat.zero, count: (subviews.count + columns - 1) / columns)
        for i in subviews.indices {
            heights[i / columns] = max(heights[i / columns], subviews[i].sizeThatFits(.init(width: widths[i % columns], height: nil)).height)
        }
        return (widths, heights)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let m = measurements(proposal, subviews)
        return CGSize(width: m.widths.reduce(0, +), height: m.heights.reduce(0, +))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let m = measurements(.init(width: bounds.width, height: nil), subviews)
        var y = bounds.minY
        for row in m.heights.indices {
            var x = bounds.minX
            for column in m.widths.indices {
                let i = row * columns + column
                if i < subviews.count {
                    subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: .init(width: m.widths[column], height: m.heights[row]))
                }
                x += m.widths[column]
            }
            y += m.heights[row]
        }
    }
}
