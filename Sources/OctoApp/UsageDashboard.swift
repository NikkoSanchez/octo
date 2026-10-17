import AppKit
import Charts
import SwiftUI
import OctoCore
import OctoAgents

enum UsageDashboardWindow { static let id = "usage" }

enum UsageFormat {
    /// Three significant digits with K/M/B suffixes, matching compact dashboard totals.
    static func tokens(_ value: Int) -> String {
        let units: [(Double, String)] = [(1e9, "B"), (1e6, "M"), (1e3, "K")]
        guard let (size, suffix) = units.first(where: { Double(value) >= $0.0 }) else { return "\(value)" }
        let scaled = Double(value) / size
        let digits = scaled >= 100 ? 0 : scaled >= 10 ? 1 : 2
        var text = String(format: "%.\(digits)f", scaled)
        if text.contains(".") { while text.hasSuffix("0") { text.removeLast() }; if text.hasSuffix(".") { text.removeLast() } }
        return text + suffix
    }
    static func percent(_ share: Double) -> String { String(format: share >= 0.1 || share == 0 ? "%.1f%%" : "%.2f%%", share * 100) }
}

/// Last-known limit window shared by the chat popover and the dashboard.
struct UsageWindowRow: View {
    let window: AgentUsageWindow
    @Environment(\.octoTheme) private var theme
    var body: some View {
        // A passed reset means the reported percentage describes an earlier window.
        let expired = window.resetsAt.map { $0 <= Date() } ?? false
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.title)
                Spacer()
                if expired { Text("Reset") }
                else if window.isLimited { Text("Limit reached").foregroundStyle(theme.red) }
                else if let remaining = window.remainingPercent { Text("\(remaining, specifier: "%.0f")% remaining") }
                else { Text("Usage unavailable") }
            }
            if !expired, let remaining = window.remainingPercent { ProgressView(value: remaining, total: 100).tint(window.isLimited ? theme.red : nil) }
            if expired { Text("A new window has started. Usage updates after the next report.").foregroundStyle(theme.secondary) }
            else if let reset = window.resetsAt {
                Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(theme.secondary)
            } else { Text("Reset time unavailable").foregroundStyle(theme.secondary) }
        }
    }
}

struct UsageDashboardView: View {
    @ObservedObject var store: AppStore
    @Environment(\.octoTheme) private var theme
    @State private var page = Page.tokens
    @State private var range = TimeRange.month
    @State private var breakdown = Breakdown.model
    @State private var summary: UsageSummary?
    @State private var loading = false
    @State private var reload = 0
    @State private var selectedDate: Date?

    enum Page: String, CaseIterable { case tokens = "Tokens", limits = "Limits" }
    enum Breakdown: String, CaseIterable { case model = "Model", day = "Day" }
    enum TimeRange: String, CaseIterable {
        case day = "Past 24h", week = "7 days", month = "30 days", quarter = "90 days"
        func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
            let days: Int
            switch self {
            case .day: return DateInterval(start: now.addingTimeInterval(-86_400), end: now)
            case .week: days = 7
            case .month: days = 30
            case .quarter: days = 90
            }
            let start = calendar.date(byAdding: .day, value: 1 - days, to: calendar.startOfDay(for: now)) ?? now
            return DateInterval(start: start, end: now)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                Group {
                    if page == .limits { limits } else if let summary { tokens(summary) }
                    else { ProgressView("Reading local session logs…").padding(80) }
                }.frame(maxWidth: 1040, alignment: .leading).padding(.horizontal, 36).padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(theme.background)
        .task(id: "\(range.rawValue)-\(reload)") { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let interval = range.interval()
        let records = await store.usageLedger.records(since: interval.start)
        guard !Task.isCancelled else { return }
        summary = UsageSummary(records: records, interval: interval)
        selectedDate = nil
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("Usage").foregroundStyle(theme.secondary)
            Text("/").foregroundStyle(theme.secondary)
            Text("All providers")
            if let summary {
                Text("\(summary.interval.start.formatted(.dateTime.month(.abbreviated).day())) to \(summary.interval.end.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(.system(size: 13)).foregroundStyle(theme.secondary).padding(.leading, 12)
            }
            Spacer()
            ForEach(Page.allCases, id: \.self) { item in headerButton(item.rawValue, selected: page == item) { page = item } }
            Divider().frame(height: 16).padding(.horizontal, 6)
            ForEach(TimeRange.allCases, id: \.self) { item in headerButton(item.rawValue, selected: range == item) { range = item } }
                .disabled(page == .limits)
            Button { reload += 1 } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(HoverButtonStyle()).help("Re-read session logs").accessibilityLabel("Refresh usage").disabled(loading)
            ProgressView().controlSize(.small).opacity(loading ? 1 : 0)
        }.font(.system(size: 15)).padding(.horizontal, 20).padding(.vertical, 14)
    }
    private func headerButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).foregroundStyle(selected ? theme.foreground : theme.secondary) }
            .buttonStyle(HoverButtonStyle()).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func color(_ provider: HarnessID) -> Color {
        switch provider {
        case .codex: return theme.foreground.opacity(0.85)
        case .claude: return theme.palette.map { Color(nsColor: NSColor(themeHex: $0.peach)) } ?? .orange
        }
    }

    @ViewBuilder private func tokens(_ summary: UsageSummary) -> some View {
        if summary.total == 0 {
            ContentUnavailableView("No token usage in this range", systemImage: "chart.xyaxis.line",
                                   description: Text("Usage is read from local Codex and Claude Code session logs on this Mac."))
        } else {
            VStack(alignment: .leading, spacing: 40) {
                HStack(alignment: .top, spacing: 44) {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(UsageFormat.tokens(summary.total)).font(.system(size: 46, weight: .semibold))
                            Text("\(summary.sessions) sessions").foregroundStyle(theme.secondary)
                        }
                        ForEach(summary.providers) { provider in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Circle().fill(color(provider.id)).frame(width: 9, height: 9)
                                    Text(provider.id.title).font(.system(size: 16))
                                    Text("\(provider.sessions) sessions").font(.system(size: 13)).foregroundStyle(theme.secondary)
                                    Spacer()
                                    Text(UsageFormat.tokens(provider.tokens)).font(.system(size: 16))
                                }
                                Text("\(UsageFormat.percent(Double(provider.tokens) / Double(summary.total))) of tokens")
                                    .font(.system(size: 13)).foregroundStyle(theme.secondary).padding(.leading, 17)
                            }
                        }
                    }.frame(width: 320)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(summary.hourly ? "Hourly processed tokens" : "Daily processed tokens").font(.system(size: 16))
                        chart(summary).frame(height: 280)
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Totals").font(.system(size: 16))
                    HStack(alignment: .top) {
                        stat("Processed tokens", summary.total)
                        stat("Cached input", summary.cachedInput)
                        stat("Cache writes", summary.cacheWrite)
                        stat("Uncached input", summary.uncachedInput)
                        stat("Output", summary.output)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Breakdown").font(.system(size: 16))
                        Spacer()
                        ForEach(Breakdown.allCases, id: \.self) { item in headerButton(item.rawValue, selected: breakdown == item) { breakdown = item } }
                    }
                    breakdownTable(summary)
                }
                Text("Counted from local Codex and Claude Code session logs on this Mac, including sessions outside Octo. Costs are not estimated.")
                    .font(.system(size: 12)).foregroundStyle(theme.secondary)
            }
        }
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13)).foregroundStyle(theme.secondary)
            Text(UsageFormat.tokens(value)).font(.system(size: 20))
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }

    private func chart(_ summary: UsageSummary) -> some View {
        let providers = summary.providers.map(\.id)
        let selected = selectedDate.flatMap { date in summary.series.map(\.start).min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) } }
        return Chart {
            ForEach(summary.series) { point in
                AreaMark(x: .value("Time", point.start), y: .value("Tokens", point.tokens), stacking: .unstacked)
                    .foregroundStyle(by: .value("Provider", point.provider.title))
                    .interpolationMethod(.monotone).opacity(0.22)
                LineMark(x: .value("Time", point.start), y: .value("Tokens", point.tokens))
                    .foregroundStyle(by: .value("Provider", point.provider.title))
                    .interpolationMethod(.monotone).lineStyle(StrokeStyle(lineWidth: 2))
            }
            if let selected {
                RuleMark(x: .value("Selected", selected)).foregroundStyle(theme.border)
                    .annotation(position: .top, alignment: .center, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(summary.hourly ? selected.formatted(.dateTime.month(.abbreviated).day().hour()) : selected.formatted(.dateTime.month(.abbreviated).day()))
                                .font(.system(size: 12, weight: .medium))
                            ForEach(providers, id: \.self) { provider in
                                let tokens = summary.series.first { $0.start == selected && $0.provider == provider }?.tokens ?? 0
                                HStack(spacing: 6) {
                                    Circle().fill(color(provider)).frame(width: 7, height: 7)
                                    Text("\(provider.title) \(UsageFormat.tokens(tokens))")
                                }.font(.system(size: 12))
                            }
                        }.padding(8).background(theme.panel, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.border))
                    }
            }
        }
        .chartForegroundStyleScale(domain: providers.map(\.title), range: providers.map(color))
        .chartLegend(.hidden)
        .chartXSelection(value: $selectedDate)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(theme.border.opacity(0.6))
                AxisValueLabel { if let tokens = value.as(Int.self) { Text(UsageFormat.tokens(tokens)).foregroundStyle(theme.secondary) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(summary.hourly ? date.formatted(.dateTime.hour()) : date.formatted(.dateTime.month(.abbreviated).day()).uppercased())
                            .foregroundStyle(theme.secondary)
                    }
                }
            }
        }
        .accessibilityLabel(summary.hourly ? "Hourly processed tokens by provider" : "Daily processed tokens by provider")
    }

    private func breakdownTable(_ summary: UsageSummary) -> some View {
        let rows = breakdown == .model ? summary.models : summary.days
        return VStack(spacing: 0) {
            HStack {
                Text(breakdown == .model ? "Model" : "Day")
                Spacer()
                Text("Share").frame(width: 120, alignment: .trailing)
                Text("Tokens").frame(width: 140, alignment: .trailing)
            }.font(.system(size: 13)).foregroundStyle(theme.secondary).padding(.vertical, 9)
            Divider()
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    if let provider = row.provider { Circle().fill(color(provider)).frame(width: 8, height: 8).help(provider.title) }
                    Text(row.date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? row.title).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(UsageFormat.percent(row.share)).frame(width: 120, alignment: .trailing)
                    Text(UsageFormat.tokens(row.tokens)).frame(width: 140, alignment: .trailing)
                }.font(.system(size: 15)).padding(.vertical, 12)
                    .accessibilityElement(children: .combine)
                Divider()
            }
        }
    }

    /// Latest account limits per provider already reported to this app session.
    private var limits: some View {
        var latest: [String: AgentUsage] = [:]
        for (key, usage) in store.usageSnapshots {
            let provider = String(key.prefix { $0 != ":" })
            if latest[provider].map({ $0.fetchedAt < usage.fetchedAt }) ?? true { latest[provider] = usage }
        }
        return VStack(alignment: .leading, spacing: 30) {
            ForEach(store.harnessDescriptors) { descriptor in
                limitsSection(descriptor, usage: latest[descriptor.id.rawValue])
                Divider()
            }
        }
    }
    private func limitsSection(_ descriptor: HarnessDescriptor, usage: AgentUsage?) -> some View {
        let thread = limitsThread(descriptor.id)
        let key = thread.map { store.usageKey($0) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(color(descriptor.id)).frame(width: 9, height: 9)
                Text(descriptor.id.title).font(.system(size: 18))
                Spacer()
                if let usage {
                    Text("\(descriptor.supportsUsageRefresh ? "Updated" : "Reported") \(usage.fetchedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 13)).foregroundStyle(theme.secondary)
                }
                if descriptor.supportsUsageRefresh, let thread, let key {
                    Button { Task { await store.loadUsage(thread) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(HoverButtonStyle()).help("Refresh \(descriptor.id.title) limits")
                        .disabled(store.loadingUsage.contains(key))
                }
            }
            limitsBody(descriptor, usage: usage)
            if let key, let error = store.usageErrors[key] { Text(error).font(.system(size: 13)).foregroundStyle(theme.secondary) }
        }
    }
    @ViewBuilder private func limitsBody(_ descriptor: HarnessDescriptor, usage: AgentUsage?) -> some View {
        if !descriptor.supportsUsageLimits {
            Text("Account limits are not exposed by this adapter.").foregroundStyle(theme.secondary)
        } else if let usage {
            ForEach(usage.buckets) { bucket in
                Text(bucket.title).font(.system(size: 14, weight: .medium))
                ForEach(bucket.windows) { window in UsageWindowRow(window: window).font(.system(size: 13)).frame(maxWidth: 520) }
            }
        } else if descriptor.supportsUsageRefresh {
            Text("Limits have not been loaded yet. Use refresh to read them from the CLI.").foregroundStyle(theme.secondary)
        } else {
            Text("\(descriptor.id.title) reports limits alongside responses. They appear here after the next response in any \(descriptor.id.title) chat.")
                .foregroundStyle(theme.secondary)
        }
    }
    /// Read-only limit queries run in the selected thread's checkout when it uses this provider.
    private func limitsThread(_ provider: HarnessID) -> WorkspaceThread? {
        if let thread = store.thread, thread.harness == provider { return thread }
        return store.archive.projects.flatMap(\.threads).filter { $0.harness == provider }.max { $0.createdAt < $1.createdAt }
    }
}
