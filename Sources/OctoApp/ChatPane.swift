import AppKit
import SwiftUI
import OctoCore
import OctoAgents

struct ChatPane: View {
    @ObservedObject var store: AppStore
    var isVisible = true
    var openFile: (URL) -> Void = { _ in }
    @Environment(\.scenePhase) private var phase
    @Environment(\.octoTheme) private var theme
    @StateObject private var transcriptScroll = TranscriptScrollController()
    @State private var matchIndex = 0
    @State private var expandedDetails = Set<UUID>()
    @State private var showingUsage = false
    @State private var fullAccessThread: UUID?
    @State private var windowIsKey = false
    private var readableThreadID: UUID? {
        isVisible && phase == .active && windowIsKey && transcriptScroll.isFollowing && !store.findingThread ? store.thread?.id : nil
    }
    var body: some View {
        VStack(spacing: 0) {
            if let thread = store.thread {
                HStack {
                    Image(systemName: "bubble.left.and.text.bubble.right"); Text(thread.harness.title).fontWeight(.medium)
                    Spacer()
                    Button { showingUsage.toggle() } label: { Image(systemName: "chart.bar.xaxis") }
                        .buttonStyle(HoverButtonStyle()).accessibilityLabel("Account usage limits").help("Account usage limits")
                        .popover(isPresented: $showingUsage, arrowEdge: .top) { usageView(thread).id(store.usageKey(thread)) }
                    if store.running.contains(thread.id) { ProgressView().controlSize(.small) }
                }.font(.system(size: 15)).padding(13)
                Divider()
                findBar.frame(height: store.findingThread ? 50 : 0).clipped()
                    .opacity(store.findingThread ? 1 : 0).allowsHitTesting(store.findingThread).accessibilityHidden(!store.findingThread)
                ScrollViewReader { proxy in
                    let turns = ChatTurn.turns(thread.messages)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if thread.messages.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(store.isProjectChat ? "What are we building?" : "What's on your mind?").font(.title2.weight(.semibold))
                                    Text(store.isProjectChat ? "Start a conversation about this project. Select code in the review pane to attach precise context." : "Ask a question, explore an idea, or work through something. Your conversations live here in Chats.").foregroundStyle(theme.secondary)
                                }.padding(.top, 30)
                            }
                            if turns.count > 1 {
                                VStack(alignment: .leading, spacing: 20) {
                                    ForEach(turns.dropLast()) { turn in
                                        turnView(turn, harness: thread.harness, active: false)
                                    }
                                }
                            }
                            // Eager history keeps measured Markdown heights and native scroll
                            // geometry stable while scrolling or resizing the chat column.
                            ForEach(turns.suffix(1)) { turn in
                                turnView(turn, harness: thread.harness, active: store.running.contains(thread.id))
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding(20)
                            .background(TranscriptScrollProbe(controller: transcriptScroll, threadID: thread.id,
                                                              suspended: !isVisible || store.showingTerminal, searching: store.findingThread,
                                                              scrollToEnd: { transcriptScroll.scrollToEnd() }))
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: TranscriptHeightKey.self, value: geometry.size.height)
                            })
                    }
                    .onChange(of: thread.messages.last?.text) { _, _ in transcriptScroll.contentChanged() }
                    .onPreferenceChange(TranscriptHeightKey.self) { _ in transcriptScroll.contentChanged() }
                    .overlay(alignment: .bottom) {
                        if !transcriptScroll.isFollowing && !store.findingThread {
                            Button { transcriptScroll.resumeFollowing() } label: {
                                Label("Scroll to end", systemImage: "arrow.down")
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(.regularMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain).help("Scroll to the latest message and follow new output")
                            .padding(.bottom, 10)
                        }
                    }
                    .onDisappear { transcriptScroll.disconnect() }
                    .onChange(of: store.threadQuery) { _, _ in matchIndex = 0; scrollToMatch(proxy) }
                    .onChange(of: store.findStep) { old, new in
                        guard !matchIDs.isEmpty else { return }
                        matchIndex = (matchIndex + (new > old ? 1 : -1) + matchIDs.count) % matchIDs.count
                        scrollToMatch(proxy)
                    }
                    .onChange(of: thread.id) { _, _ in
                        store.threadQuery = ""; matchIndex = 0
                    }
                }
                ForEach(store.approvals[thread.id] ?? []) { approval in
                    VStack(alignment: .leading, spacing: 9) {
                        Label(approval.title, systemImage: "hand.raised").font(.headline)
                        ScrollView { Text(approval.detail).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 130)
                        HStack { Button("Decline") { store.answer(approval, threadID: thread.id, allow: false) }.hoverFeedback(); Button("Allow Once") { store.answer(approval, threadID: thread.id, allow: true) }.buttonStyle(.borderedProminent).foregroundStyle(theme.onAccent).hoverFeedback() }
                    }.padding(12).background(theme.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8)).padding(12)
                }
                if !(store.interactions[thread.id] ?? []).isEmpty {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(store.interactions[thread.id] ?? []) { request in
                                InteractionCard(request: request) { response in
                                    store.respond(to: request, threadID: thread.id, response: response)
                                }.id(request.id)
                            }
                        }.padding(12)
                    }.frame(maxHeight: 340)
                }
                composer(thread)
                    .task(id: "\(thread.harness.rawValue):\(thread.workingDirectory):\(store.codexConfigurationID)") {
                        if thread.harness == .codex {
                            await store.refreshCodexVersion()
                            guard !Task.isCancelled else { return }
                            await store.loadModels(directory: thread.workingDirectory)
                        }
                    }
            } else { ContentUnavailableView {
                Label("Start a chat", systemImage: "bubble.left")
            } actions: { Button("New Chat") { store.newThread() }.buttonStyle(.borderedProminent) } }
        }.frame(maxWidth: 840, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ChatWindowActivity(isKey: $windowIsKey).frame(width: 0, height: 0))
            .onChange(of: readableThreadID, initial: true) { _, id in
                if let id { store.markThreadRead(id) }
            }
            .onChange(of: store.thread?.unreadCompletedAt) { _, _ in
                if let id = readableThreadID { store.markThreadRead(id) }
            }
            .alert("Enable full access?", isPresented: Binding(get: { fullAccessThread != nil }, set: { if !$0 { fullAccessThread = nil } })) {
                Button("Cancel", role: .cancel) { fullAccessThread = nil }
                Button("Enable full access", role: .destructive) {
                    if let id = fullAccessThread { store.selectPermissions(.fullAccess, threadID: id) }
                    fullAccessThread = nil
                }
            } message: { Text("This thread's next turns can access files outside the project and the network without approval prompts. This choice is also remembered for new threads until you change permissions. The CLI's managed policies still apply.") }
    }
    private func transcriptMessage(_ message: ChatMessage, harness: HarnessID) -> some View {
        messageView(message, harness: harness).id(message.id).padding(6)
            .background(matchIDs.contains(message.id) ? theme.searchHighlight(active: matchIDs.firstIndex(of: message.id) == matchIndex) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
    private var matchIDs: [UUID] {
        guard store.findingThread, !store.threadQuery.isEmpty else { return [] }
        return store.thread?.messages.filter { $0.text.localizedStandardContains(store.threadQuery) }.map(\.id) ?? []
    }
    private func scrollToMatch(_ proxy: ScrollViewProxy) {
        if matchIDs.indices.contains(matchIndex) { proxy.scrollTo(matchIDs[matchIndex], anchor: .center) }
    }
    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
            SearchInputField(placeholder: "Find in this thread", focusRequest: store.findFocus, autofocus: false, identifier: "OctoThreadFind", text: $store.threadQuery,
                             move: { store.findStep += $0 }, submit: { store.findStep += 1 },
                             cancel: { store.findingThread = false; store.focusComposer() }).frame(height: 26)
            Text(store.threadQuery.isEmpty ? "" : matchIDs.isEmpty ? "No matches" : "\(min(matchIndex + 1, matchIDs.count))/\(matchIDs.count) messages")
                .font(.system(size: 11)).foregroundStyle(theme.secondary)
            Button { store.findStep -= 1 } label: { Image(systemName: "chevron.up") }.help("Previous match (⇧⌘G)").disabled(matchIDs.isEmpty)
            Button { store.findStep += 1 } label: { Image(systemName: "chevron.down") }.help("Next match (⌘G)").disabled(matchIDs.isEmpty)
            Button { store.findingThread = false; store.focusComposer() } label: { Image(systemName: "xmark") }.help("Close search")
        }.padding(12).background(theme.panel)

    }
    private func turnView(_ turn: ChatTurn, harness: HarnessID, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if let user = turn.user { transcriptMessage(user, harness: harness) }
            if active || turn.user?.work != nil || !turn.details.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    if turn.details.isEmpty {
                        workLabel(turn, active: active)
                    } else {
                        DisclosureGroup(isExpanded: Binding(get: {
                            expandedDetails.contains(turn.id) || turn.details.contains { matchIDs.contains($0.id) }
                        }, set: { if $0 { expandedDetails.insert(turn.id) } else { expandedDetails.remove(turn.id) } })) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(turn.details) { transcriptMessage($0, harness: harness) }
                            }.padding(.top, 10)
                        } label: { workLabel(turn, active: active) }
                        .disclosureGroupStyle(WorkDisclosureStyle())
                    }
                    Divider().overlay(theme.border.opacity(0.25))
                }.font(.system(size: 13)).foregroundStyle(theme.secondary).padding(.horizontal, 6)
            }
            ForEach(turn.responses) { transcriptMessage($0, harness: harness) }
        }
    }
    @ViewBuilder private func workLabel(_ turn: ChatTurn, active: Bool) -> some View {
        if active {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 7) {
                    WorkingIndicator()
                    Text("Working for \(TurnWork.duration(context.date.timeIntervalSince(turn.user?.work?.startedAt ?? context.date)))")
                        .monospacedDigit()
                }
            }
        } else {
            Text(turn.user?.work?.label ?? "Reasoning & activity · \(turn.details.count)")
        }
    }
    private func timestamp(_ message: ChatMessage) -> some View {
        let date = message.completedAt ?? message.createdAt
        return Text(date, format: .dateTime.weekday(.wide).hour().minute())
            .font(.system(size: 11)).foregroundStyle(theme.secondary)
            .help(date.formatted(date: .complete, time: .standard))
    }
    private func messageView(_ message: ChatMessage, harness: HarnessID) -> some View {
        let latestResponse = message.role == .assistant && store.thread?.messages.last(where: { $0.role == .assistant })?.id == message.id
        return ResponseTimestampHover(hoverOnly: latestResponse) { showTimestamp in
            HStack(alignment: .top, spacing: 0) {
                if message.role == .user { Spacer(minLength: 48) }
                VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 8) {
                        if message.role == .error {
                            Text("Agent notice").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.red)
                        }
                        if message.role == .assistant {
                            MarkdownResponseView(source: message.text)
                                .environment(\.openURL, OpenURLAction { url in
                                    if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { return .systemAction }
                                    openFile(url)
                                    return .handled
                                })
                        } else {
                            Text(verbatim: message.text)
                                .font(message.role == .activity ? .system(size: 13, design: .monospaced) : message.role == .reasoning ? .system(size: 13) : .system(size: 15))
                                .foregroundStyle(message.role == .error ? theme.red : message.role == .activity || message.role == .reasoning ? theme.secondary : theme.foreground)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        imageStrip(message.images)
                        ForEach(message.attachments) { attachment in
                            Label(attachment.label, systemImage: "curlybraces").font(.system(size: 12)).padding(6)
                                .background(theme.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    .padding(message.role == .user ? 14 : 0)
                    .background(message.role == .user ? theme.surface : .clear, in: RoundedRectangle(cornerRadius: 16))
                    if message.role == .user || message.role == .assistant || message.role == .error {
                        HStack(spacing: 10) {
                            if message.role == .assistant {
                                Button { copyResponseText(message.text) } label: { Image(systemName: "doc.on.doc") }
                                    .buttonStyle(HoverButtonStyle()).help("Copy original response")
                                    .accessibilityLabel("Copy original response")
                            }
                            timestamp(message)
                                // Reserve its space: hovering must never reflow the response.
                                .opacity(showTimestamp ? 1 : 0)
                                .accessibilityHidden(false)
                        }.foregroundStyle(theme.secondary)
                    }
                }.frame(maxWidth: message.role == .user ? 620 : .infinity, alignment: message.role == .user ? .trailing : .leading)
            }
        }
    }
    private func permissionsMenu(_ thread: WorkspaceThread, compact: Bool = false) -> some View {
        let descriptor = store.harnessDescriptors.first { $0.id == thread.harness }
        let selected = thread.agentSettings.permissionMode ?? descriptor?.defaultPermissionMode
        return Menu {
            if descriptor?.permissionOptions.isEmpty != false {
                Text("Uses CLI defaults. Permission controls are unavailable in this adapter.")
            } else {
                Text("Permissions for the next turn")
                ForEach(descriptor?.permissionOptions ?? []) { option in
                    Button {
                        if option.mode == .fullAccess { fullAccessThread = thread.id }
                        else { store.selectPermissions(option.mode, threadID: thread.id) }
                    } label: {
                        VStack(alignment: .leading) {
                            if option.mode == selected { Label(option.mode.title, systemImage: "checkmark") }
                            else { Text(option.mode.title) }
                            Text(option.detail).font(.caption)
                        }
                    }.help(option.detail)
                }
            }
        } label: {
            Label(selected?.title ?? "CLI permissions", systemImage: selected == .fullAccess ? "exclamationmark.shield" : "hand.raised")
                .labelStyle(PermissionLabelStyle(compact: compact))
                .font(.system(size: 12)).foregroundStyle(selected == .fullAccess ? theme.yellow : theme.secondary)
        }.menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 4).padding(.vertical, 2).hoverFeedback()
            .help(selected?.title ?? "CLI permissions")
            .accessibilityLabel("Permissions: \(selected?.title ?? "CLI defaults")")
            .disabled(store.running.contains(thread.id))
    }
    private func usageView(_ thread: WorkspaceThread) -> some View {
        let key = store.usageKey(thread)
        let supported = store.harnessDescriptors.first { $0.id == thread.harness }?.supportsUsageLimits == true
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(thread.harness.title) account usage").font(.headline)
            Text("Shared across your account, including other chats and apps.").font(.caption).foregroundStyle(theme.secondary)
            if !supported {
                Text("Account limits and reset times are not exposed by this adapter.")
            } else {
                if let usage = store.usageSnapshots[key] {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(usage.buckets) { bucket in
                                Text(bucket.title).fontWeight(.medium)
                                if bucket.windows.isEmpty { Text("No usage windows reported.").foregroundStyle(theme.secondary) }
                                ForEach(bucket.windows) { window in
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            Text(window.title)
                                            Spacer()
                                            if let remaining = window.remainingPercent { Text("\(remaining, specifier: "%.0f")% remaining") }
                                            else { Text("Usage unavailable") }
                                        }
                                        if let remaining = window.remainingPercent { ProgressView(value: remaining, total: 100) }
                                        if let reset = window.resetsAt {
                                            Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                                                .foregroundStyle(theme.secondary)
                                        } else { Text("Reset time unavailable").foregroundStyle(theme.secondary) }
                                    }.font(.caption)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: min(280, CGFloat(usage.buckets.reduce(0) { $0 + max(1, $1.windows.count) }) * 100 + CGFloat(usage.buckets.count) * 25))
                    Text("Last updated \(usage.fetchedAt.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(theme.secondary)
                }
                if let error = store.usageErrors[key] { Text(error).font(.caption).foregroundStyle(theme.secondary) }
                HStack {
                    Button { Task { await store.loadUsage(thread) } } label: {
                        Image(systemName: "arrow.clockwise")
                    }.hoverFeedback().help("Refresh usage").accessibilityLabel("Refresh usage")
                        .disabled(store.loadingUsage.contains(key))
                    if store.loadingUsage.contains(key) { ProgressView().controlSize(.small) }
                }
            }
        }.padding(18).frame(width: 350).task { if supported { await store.loadUsage(thread) } }
    }
    private func agentMenu(_ thread: WorkspaceThread) -> some View {
        let models = store.modelCatalogs[thread.workingDirectory] ?? []
        let selected = models.first { $0.model == thread.agentSettings.model }
        let summary = [thread.harness.title, selected?.displayName ?? thread.agentSettings.model,
                       thread.agentSettings.reasoningEffort.map { $0 == "xhigh" ? "Extra high" : $0.capitalized }]
            .compactMap { $0 }.joined(separator: " · ")
        return Menu {
            Menu("Provider") {
                ForEach(store.harnessDescriptors) { descriptor in
                    Button { store.changeHarness(descriptor.id) } label: {
                        if descriptor.id == thread.harness { Label(descriptor.id.title, systemImage: "checkmark") }
                        else { Text(descriptor.id.title + (descriptor.executable == nil ? " · not installed" : "")) }
                    }
                }
            }
            if thread.harness == .codex {
                Menu("Model") {
                    if thread.agentSettings.model == nil { Text("Using session default") }
                    ForEach(models) { model in
                        Button { store.selectModel(model) } label: {
                            if thread.agentSettings.model == model.model { Label(model.displayName, systemImage: "checkmark") }
                            else { Text(model.displayName) }
                        }.help(model.description)
                    }
                    Divider()
                    Button(store.loadingModels.contains(thread.workingDirectory) ? "Loading models…" : "Refresh models") {
                        Task { await store.loadModels(directory: thread.workingDirectory, refresh: true) }
                    }.disabled(store.loadingModels.contains(thread.workingDirectory))
                }
                Menu("Reasoning") {
                    if selected == nil { Text("Choose a model first") }
                    ForEach(selected?.supportedReasoningEfforts ?? []) { option in
                        Button { store.selectReasoning(option.reasoningEffort) } label: {
                            if thread.agentSettings.reasoningEffort == option.reasoningEffort { Label(option.title, systemImage: "checkmark") }
                            else { Text(option.title) }
                        }.help(option.description)
                    }
                }.disabled(selected?.supportedReasoningEfforts.isEmpty != false)
            }
        } label: {
            Text(summary).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
        }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4).padding(.vertical, 2).hoverFeedback()
            .help("Provider, model, and reasoning").accessibilityLabel("Agent settings")
            .disabled(store.running.contains(thread.id))
    }
    @ViewBuilder private func imageStrip(_ images: [ImageAttachment], threadID: UUID? = nil) -> some View {
        if !images.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(images) { attachment in
                        VStack(alignment: .leading, spacing: 4) {
                            if let image = NSImage(data: attachment.pngData) {
                                Image(nsImage: image).resizable().scaledToFit().frame(width: 116, height: 76)
                                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 6))
                                    .accessibilityLabel(attachment.name)
                            }
                            HStack {
                                Text(attachment.name).font(.system(size: 11)).foregroundStyle(theme.secondary)
                                if let threadID {
                                    Button { store.draftImages[threadID]?.removeAll { $0.id == attachment.id } } label: { Image(systemName: "xmark.circle.fill") }
                                        .buttonStyle(HoverButtonStyle()).accessibilityLabel("Remove image")
                                }
                            }
                        }
                    }
                }
            }.frame(height: 100)
        }
    }
    private func composer(_ thread: WorkspaceThread) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(store.attachments[thread.id] ?? []) { attachment in
                HStack {
                    Label(attachment.label, systemImage: "curlybraces").lineLimit(1)
                    Spacer(); Button { store.attachments[thread.id]?.removeAll { $0.id == attachment.id } } label: { Image(systemName: "xmark") }.buttonStyle(HoverButtonStyle()).help("Remove attachment")
                }.font(.system(size: 15)).padding(7).background(theme.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            }
            imageStrip(store.draftImages[thread.id] ?? [], threadID: thread.id)
            if let compaction = thread.lastCompaction, compaction.state == .compacting {
                TimelineView(.periodic(from: .now, by: 1)) { clock in
                    HStack(spacing: 7) {
                        WorkingIndicator(symbol: "arrow.triangle.2.circlepath")
                        Text("Compacting context…")
                        Spacer()
                        Text(TurnWork.duration(clock.date.timeIntervalSince(compaction.startedAt))).monospacedDigit()
                    }.font(.system(size: 12)).foregroundStyle(theme.secondary)
                }
            }
            DraftEditor(drafts: store.draftStore, threadID: thread.id, focusRequest: store.composerFocus, theme: store.theme,
                        placeholder: store.isProjectChat ? "Ask about this project…" : "Ask anything…",
                        onChange: { store.drafts[thread.id] = $0 },
                        onPasteImage: { store.pasteScreenshot(from: $0, threadID: thread.id) }, onSend: { store.send() })
                .id(thread.id).frame(height: 110)
            HStack(spacing: 10) {
                Button { store.chooseImages(threadID: thread.id) } label: {
                    Image(systemName: "plus").frame(width: 16, height: 16)
                }
                .buttonStyle(HoverButtonStyle())
                .help(thread.harness == .codex ? "Add images" : "Image attachments require Codex")
                .accessibilityLabel("Add images")
                .disabled(thread.harness != .codex || store.importingImages.contains(thread.id) || (store.draftImages[thread.id]?.count ?? 0) >= 4)
                if store.importingImages.contains(thread.id) {
                    ProgressView().controlSize(.small).accessibilityLabel("Loading images")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { agentMenu(thread); permissionsMenu(thread) }
                        .fixedSize(horizontal: true, vertical: false)
                    HStack(spacing: 4) { agentMenu(thread); permissionsMenu(thread, compact: true) }
                }
                Spacer(minLength: 0)
                ContextUsageView(usage: thread.conversationUsage, compaction: thread.lastCompaction,
                                 provider: thread.harness.title,
                                 supportsUsage: store.harnessDescriptors.first { $0.id == thread.harness }?.supportsConversationUsage == true,
                                 supportsCompaction: store.harnessDescriptors.first { $0.id == thread.harness }?.supportsCompactionStatus == true)
                    .id(thread.id)
                if store.running.contains(thread.id) { Button("Stop") { store.stop(thread.id) }.controlSize(.small).hoverFeedback().shortcutHint("stop") }
                else { Button { store.send() } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderedProminent).foregroundStyle(theme.onAccent).hoverFeedback().disabled(!store.canSend(thread)).shortcutHint("send") }
            }
            if thread.harness == .codex {
                if let error = store.modelErrors[thread.workingDirectory] {
                    Text(error).font(.system(size: 12)).foregroundStyle(theme.secondary)
                } else if let modelID = thread.agentSettings.model, let catalog = store.modelCatalogs[thread.workingDirectory], !catalog.contains(where: { $0.model == modelID }) {
                    Text("The saved model is unavailable. Choose another in Agent settings.").font(.system(size: 12)).foregroundStyle(theme.secondary)
                }
            }
            if thread.harness == .claude { Text("Claude uses its CLI model and reasoning settings. Interactive approvals are unavailable.").font(.system(size: 12)).foregroundStyle(theme.secondary) }
        }.padding(12).background(theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary)).padding(14)
    }
}

private struct ResponseTimestampHover<Content: View>: View {
    let hoverOnly: Bool
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovering = false
    var body: some View {
        content(!hoverOnly || hovering).contentShape(Rectangle()).onHover { hovering = $0 }
    }
}

/// The label, chevron and trailing whitespace all share one native button.
private struct WorkDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).frame(width: 12).accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(HoverButtonStyle(padded: false))
                .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Show or hide reasoning and activity")
            if configuration.isExpanded { configuration.content }
        }
    }
}

/// The app can stay active while Settings or another window obscures this chat.
private struct ChatWindowActivity: NSViewRepresentable {
    @Binding var isKey: Bool
    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ view: ObserverView, context: Context) {
        view.changed = { isKey = $0 }
        view.publish()
    }
    final class ObserverView: NSView {
        var changed: ((Bool) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(publish), name: name, object: window)
                }
            }
            publish()
        }
        @objc func publish() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.changed?(self.window?.isKeyWindow == true && self.window?.attachedSheet == nil)
            }
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

/// Only this small subtree observes each keystroke; the transcript, sidebar and
/// terminal surfaces do not need to rebuild for ordinary draft edits.
private struct DraftEditor: View {
    @ObservedObject var drafts: DraftStore
    let threadID: UUID
    let focusRequest: Int
    let theme: AppTheme
    let placeholder: String
    let onChange: (String) -> Void
    let onPasteImage: (NSPasteboard) -> Bool
    let onSend: () -> Void
    var body: some View {
        ZStack(alignment: .topLeading) {
            if (drafts.values[threadID] ?? "").isEmpty {
                Text(placeholder).font(.system(size: 15)).foregroundStyle(theme.subtle)
                    .padding(.top, 5).padding(.leading, 5).allowsHitTesting(false)
            }
            ComposerTextView(focusRequest: focusRequest, theme: theme,
                             text: Binding(get: { drafts.values[threadID] ?? "" }, set: onChange),
                             onPasteImage: onPasteImage, onSend: onSend)
        }
    }
}

/// Native plain-text editing keeps standard selection, undo and paste behavior,
/// while screenshot paste attaches an image instead of inserting rich text.
struct ComposerTextView: NSViewRepresentable {
    var focusRequest: Int
    var theme: AppTheme
    @Binding var text: String
    var onPasteImage: (NSPasteboard) -> Bool
    var onSend: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false; scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none; scroll.horizontalScrollElasticity = .none
        let editor = ScreenshotTextView(frame: scroll.contentView.bounds)
        editor.identifier = NSUserInterfaceItemIdentifier("OctoComposer")
        editor.isRichText = false; editor.importsGraphics = false; editor.allowsUndo = true
        editor.drawsBackground = false; editor.font = .systemFont(ofSize: 15); editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 0, height: 5)
        editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel("Message. Return to send; Shift-Return for a new line. Paste text or a screenshot.")
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ScreenshotTextView else { return }
        if editor.string != text, !editor.hasMarkedText() {
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            editor.scrollRangeToVisible(editor.selectedRange())
        }
        editor.onPasteImage = onPasteImage; editor.onSend = onSend
        // Reapplying text attributes on every edit invalidates native layout and
        // can move the scroll position while the insertion point is being drawn.
        if context.coordinator.theme != theme {
            context.coordinator.theme = theme
            editor.textColor = theme.textColor; editor.insertionPointColor = theme.cursorColor
            editor.selectedTextAttributes = [.backgroundColor: theme.selectionColor, .foregroundColor: theme.textColor]
        }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { editor.window?.makeFirstResponder(editor) }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var focusRequest = 0
        var theme: AppTheme?
        var parent: ComposerTextView
        init(_ parent: ComposerTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { parent.text = editor.string }
        }
    }
}
final class ScreenshotTextView: NSTextView {
    var onPasteImage: ((NSPasteboard) -> Bool)?
    var onSend: (() -> Void)?
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.png, .tiff]
    }
    override func paste(_ sender: Any?) {
        if onPasteImage?(.general) == true { return }
        super.paste(sender)
    }
    override func pasteAsPlainText(_ sender: Any?) {
        if onPasteImage?(.general) == true { return }
        super.pasteAsPlainText(sender)
    }
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText() {
            if modifiers.isEmpty || modifiers == .command {
                if !event.isARepeat { onSend?() }
                return
            }
            if modifiers == .shift {
                insertNewlineIgnoringFieldEditor(nil)
                return
            }
        }
        super.keyDown(with: event)
    }
}

private struct PermissionLabelStyle: LabelStyle {
    var compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            if !compact { configuration.title }
        }
    }
}
