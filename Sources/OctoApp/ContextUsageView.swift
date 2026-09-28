import SwiftUI
import OctoCore

/// A native counterpart to T3 Code's quiet composer ring and usage popover.
struct ContextUsageView: View {
    let usage: ConversationUsage?
    let compaction: ContextCompaction?
    let provider: String
    let supportsUsage: Bool
    let supportsCompaction: Bool
    @Environment(\.octoTheme) private var theme
    @State private var showingDetails = false

    private var tint: Color {
        guard let fraction = usage?.usedFraction else { return theme.secondary }
        return fraction > 0.9 ? theme.red : fraction >= 0.8 ? theme.yellow : theme.secondary
    }
    private var label: String {
        if compaction?.state == .compacting { return "Compacting context" }
        if let percent = usage?.percentUsed { return "Context \(percent)% used" }
        if let usage { return "Context \(usage.latest.total.formatted()) tokens used; capacity unavailable" }
        return supportsUsage ? "Context and token usage: awaiting report" : "Context and token usage unavailable"
    }
    var body: some View {
        Button { showingDetails.toggle() } label: {
            HStack(spacing: 5) {
                ZStack {
                    Circle().stroke(theme.secondary.opacity(0.2), lineWidth: 2.5)
                    if let fraction = usage?.usedFraction {
                        Circle().trim(from: 0, to: fraction)
                            .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    } else {
                        Text("–").font(.system(size: 10)).foregroundStyle(theme.secondary)
                    }
                }.frame(width: 17, height: 17)
                if let percent = usage?.percentUsed {
                    Text("\(percent)%").font(.system(size: 11)).monospacedDigit().foregroundStyle(tint)
                }
            }.padding(3)
        }
        .buttonStyle(HoverButtonStyle()).fixedSize()
        .accessibilityLabel("Context and token usage").accessibilityValue(label)
        .help(label + ". Click for details.")
        .popover(isPresented: $showingDetails, arrowEdge: .top) { details }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Context window").font(.system(size: 14, weight: .semibold))
                Spacer()
                if let percent = usage?.percentUsed {
                    Text("\(percent)% used").font(.system(size: 12, weight: .medium)).foregroundStyle(tint)
                }
            }
            if let usage {
                VStack(alignment: .leading, spacing: 7) {
                    if let fraction = usage.usedFraction {
                        ProgressView(value: fraction).tint(tint).accessibilityLabel("Context window usage")
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(tokens(usage.latest.total)).font(.system(size: 23, weight: .medium, design: .rounded))
                        Text(usage.contextWindow.map { "of \(tokens($0)) tokens" } ?? "tokens · capacity unavailable")
                            .font(.system(size: 12)).foregroundStyle(theme.secondary)
                    }
                    if let remaining = usage.remainingTokens {
                        Text("\(tokens(remaining)) tokens remaining in the reported window")
                            .font(.system(size: 11)).foregroundStyle(theme.secondary)
                    }
                    Text("Based on the latest model response; unsent drafts are not included.")
                        .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Text("Token usage").font(.system(size: 13, weight: .semibold))
                Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 7) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        Text("Last response")
                        Text("Session total")
                    }.foregroundStyle(theme.secondary)
                    tokenRow("Total processed", usage.latest.total, usage.session.total, emphasized: true)
                    tokenRow("Input", usage.latest.input, usage.session.input)
                    tokenRow("Cached input", usage.latest.cachedInput, usage.session.cachedInput)
                    if usage.latest.cacheWriteInput != nil || usage.session.cacheWriteInput != nil {
                        tokenRow("Cache writes", usage.latest.cacheWriteInput, usage.session.cacheWriteInput)
                    }
                    tokenRow("Output", usage.latest.output, usage.session.output)
                    tokenRow("Reasoning", usage.latest.reasoning, usage.session.reasoning)
                }.font(.system(size: 11)).monospacedDigit()
                Text("Cache counts are included in input; reasoning is included in output. Session totals can exceed the context window.")
                    .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Last reported \(usage.updatedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.system(size: 10)).foregroundStyle(theme.secondary)
            } else {
                Text(supportsUsage ? "Waiting for \(provider) to report context and token usage. Values appear as the agent works."
                     : "Context and token usage are not available through the current \(provider) adapter.")
                    .font(.system(size: 12)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            if let compaction {
                Label(compactionTitle(compaction), systemImage: compaction.state == .completed ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                if let date = compaction.endedAt {
                    Text(date.formatted(date: .abbreviated, time: .standard)).font(.system(size: 11)).foregroundStyle(theme.secondary)
                }
            }
            Text(supportsCompaction
                 ? "Compaction is handled by \(provider). The exact automatic threshold is not reported."
                 : "Compaction status is not available through this adapter.")
                .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(18).frame(width: 370).foregroundStyle(theme.foreground).background(theme.panel)
    }
    private func tokens(_ value: Int?) -> String { value.map { $0.formatted() } ?? "—" }
    private func tokenRow(_ title: String, _ latest: Int?, _ session: Int?, emphasized: Bool = false) -> some View {
        GridRow {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            Text(tokens(latest))
            Text(tokens(session))
        }.fontWeight(emphasized ? .semibold : .regular)
    }
    private func compactionTitle(_ compaction: ContextCompaction) -> String {
        switch compaction.state {
        case .compacting: return "Compacting context…"
        case .completed: return "Context compacted"
        case .interrupted: return "Compaction ended without confirmed completion"
        }
    }
}
