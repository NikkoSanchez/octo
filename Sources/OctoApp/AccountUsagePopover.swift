import SwiftUI
import OctoCore
import OctoAgents

/// Account limits for one provider at a time. Opened from the sidebar, so it follows the
/// selected thread's provider by default but can show any installed provider.
struct AccountUsagePopover: View {
    @ObservedObject var store: AppStore
    let dismiss: () -> Void
    @State private var provider: HarnessID
    @Environment(\.octoTheme) private var theme
    @Environment(\.openWindow) private var openWindow

    init(store: AppStore, dismiss: @escaping () -> Void) {
        self.store = store; self.dismiss = dismiss
        _provider = State(initialValue: store.thread?.harness ?? store.archive.lastHarness ?? .codex)
    }

    var body: some View {
        let descriptor = store.harnessDescriptors.first { $0.id == provider }
        let thread = store.usageThread(for: provider)
        let key = thread.map { store.usageKey($0) }
        let supported = descriptor?.supportsUsageLimits == true, refreshable = descriptor?.supportsUsageRefresh == true
        return VStack(alignment: .leading, spacing: 12) {
            Picker("Provider", selection: $provider) {
                ForEach(store.harnessDescriptors) { descriptor in
                    Label { Text(descriptor.id.title) } icon: { Image(nsImage: ProviderMark.image(descriptor.id)) }.tag(descriptor.id)
                }
            }.pickerStyle(.segmented).labelsHidden()
            HStack(spacing: 7) {
                ProviderIcon(harness: provider, size: 16)
                Text("\(provider.title) account usage").font(.headline)
            }
            Text("Shared across your account, including other chats and apps.").font(.caption).foregroundStyle(theme.secondary)
            if !supported {
                Text("Account limits and reset times are not exposed by this adapter.")
            } else {
                if let key, let usage = store.usageSnapshots[key] {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(usage.buckets) { bucket in
                                Text(bucket.title).fontWeight(.medium)
                                if bucket.windows.isEmpty { Text("No usage windows reported.").foregroundStyle(theme.secondary) }
                                ForEach(bucket.windows) { window in UsageWindowRow(window: window).font(.caption) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: min(280, CGFloat(usage.buckets.reduce(0) { $0 + max(1, $1.windows.count) }) * 100 + CGFloat(usage.buckets.count) * 25))
                    Text("\(refreshable ? "Last updated" : "Last reported") \(usage.fetchedAt.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(theme.secondary)
                } else if thread == nil {
                    Text("Start a \(provider.title) chat to see your session and weekly limits.")
                        .fixedSize(horizontal: false, vertical: true)
                } else if !refreshable {
                    Text("\(provider.title) reports limits alongside responses. Send a message in any \(provider.title) chat to see your session and weekly limits.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("API-key, Bedrock and Vertex sign-ins do not report subscription limits.").font(.caption).foregroundStyle(theme.secondary)
                }
                if let key, let error = store.usageErrors[key] { Text(error).font(.caption).foregroundStyle(theme.secondary) }
            }
            HStack {
                if supported && refreshable, let thread, let key {
                    Button { Task { await store.loadUsage(thread) } } label: {
                        Image(systemName: "arrow.clockwise")
                    }.hoverFeedback().help("Refresh usage").accessibilityLabel("Refresh usage")
                        .disabled(store.loadingUsage.contains(key))
                    if store.loadingUsage.contains(key) { ProgressView().controlSize(.small) }
                }
                Spacer()
                Button("Usage Dashboard") { dismiss(); openWindow(id: UsageDashboardWindow.id) }
                    .hoverFeedback().help("Token usage across Codex and Claude sessions")
            }
        }.padding(18).frame(width: 350)
            .task(id: "\(provider.rawValue):\(key ?? "")") {
                if supported && refreshable, let thread { await store.loadUsage(thread) }
            }
    }
}
