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
    @StateObject private var composerControls = ComposerControls()
    @State private var matchIndex = 0
    @State private var findResults = ThreadFindResults()
    @State private var expandedDetails = Set<UUID>()
    @State private var fullAccessThread: UUID?
    @State private var windowIsKey = false
    private var readableThreadID: UUID? {
        isVisible && phase == .active && windowIsKey && transcriptScroll.isFollowing && !store.findingThread ? store.thread?.id : nil
    }
    var body: some View {
        VStack(spacing: 0) {
            if let thread = store.thread {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            TranscriptTurns(messages: thread.messages, harness: thread.harness,
                                            active: store.running.contains(thread.id), isProjectChat: store.isProjectChat,
                                            find: store.findingThread ? findResults : ThreadFindResults(), matchIndex: matchIndex, expandedDetails: expandedDetails,
                                            setExpanded: { id, expanded in
                                                if expanded { expandedDetails.insert(id) } else { expandedDetails.remove(id) }
                                            }, openFile: openFile)
                                .equatable()
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding(20)
                            .background(TranscriptScrollProbe(controller: transcriptScroll, threadID: thread.id,
                                                              suspended: !isVisible || store.showingTerminal, searching: store.findingThread,
                                                              scrollToEnd: { transcriptScroll.scrollToEnd() }))
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: TranscriptHeightKey.self, value: geometry.size.height)
                            })
                    }
                    .floatingBar(.top) {
                        if store.findingThread {
                            ThreadFindBar(find: store.threadFind, focusRequest: store.findFocus,
                                          messages: thread.messages, results: $findResults, matchIndex: matchIndex,
                                          close: { store.findingThread = false; store.focusComposer() })
                        }
                    }
                    .onChange(of: thread.messages.last?.text) { _, _ in transcriptScroll.contentChanged() }
                    .onPreferenceChange(TranscriptHeightKey.self) { _ in transcriptScroll.contentChanged() }
                    .overlay(alignment: .bottom) {
                        if !transcriptScroll.isFollowing && !store.findingThread {
                            Button { transcriptScroll.resumeFollowing() } label: {
                                // Scrolled away from the live row, the pill still says work is happening.
                                Label {
                                    Text(store.running.contains(thread.id) ? "Working · Scroll to end" : "Scroll to end")
                                } icon: {
                                    if store.running.contains(thread.id) { WorkingIndicator() } else { Image(systemName: "arrow.down") }
                                }
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(.regularMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain).help("Scroll to the latest message and follow new output")
                            .padding(.bottom, 10)
                        }
                    }
                    .onDisappear { transcriptScroll.disconnect() }
                    .onChange(of: findResults) { old, new in
                        // A new query starts at its first match; streamed text keeps the current one.
                        if old.query != new.query { matchIndex = 0; scrollToMatch(proxy) }
                        else if matchIndex >= new.ids.count { matchIndex = max(0, new.ids.count - 1) }
                    }
                    .onReceive(store.threadFind.steps) { delta in
                        guard !matchIDs.isEmpty else { return }
                        matchIndex = (matchIndex + delta + matchIDs.count) % matchIDs.count
                        scrollToMatch(proxy)
                    }
                    .onChange(of: thread.id) { _, _ in
                        store.threadFind.query = ""; findResults = ThreadFindResults(); matchIndex = 0
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
                    }.frame(maxHeight: (store.queuedMessages[thread.id] ?? []).isEmpty ? 340 : 180)
                }
                composer(thread)
                    .task(id: "\(thread.harness.rawValue):\(thread.workingDirectory):\(store.codexConfigurationID)") {
                        if thread.harness == .codex {
                            await store.refreshCodexVersion()
                            guard !Task.isCancelled else { return }
                        }
                        guard !Task.isCancelled else { return }
                        await store.loadModels(directory: thread.workingDirectory, harness: thread.harness)
                        // The agent menu lists every installed provider's models. Discovery only
                        // initializes each CLI; it never starts a model turn.
                        for descriptor in store.harnessDescriptors where descriptor.id != thread.harness && descriptor.executable != nil {
                            guard !Task.isCancelled else { return }
                            await store.loadModels(directory: thread.workingDirectory, harness: descriptor.id)
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
    private var matchIDs: [UUID] { store.findingThread ? findResults.ids : [] }
    private func scrollToMatch(_ proxy: ScrollViewProxy) {
        if matchIDs.indices.contains(matchIndex) { proxy.scrollTo(matchIDs[matchIndex], anchor: .center) }
    }
    private func agentControls(_ thread: WorkspaceThread) -> some View {
        let descriptors = store.harnessDescriptors
        let descriptor = descriptors.first { $0.id == thread.harness }
        return AgentControls(threadID: thread.id, directory: thread.workingDirectory, harness: thread.harness,
                             settings: thread.agentSettings,
                             hasHistory: !thread.messages.isEmpty || thread.remoteSessionID != nil,
                             providers: descriptors.map { descriptor in
                                 let key = store.modelKey(descriptor.id, directory: thread.workingDirectory)
                                 return AgentControls.Provider(id: descriptor.id, installed: descriptor.executable != nil,
                                                               supportsModels: descriptor.supportsModels,
                                                               models: store.modelCatalogs[key] ?? [],
                                                               loadingModels: store.loadingModels.contains(key),
                                                               modelError: store.modelErrors[key])
                             },
                             permissionOptions: descriptor?.permissionOptions ?? [], defaultPermission: descriptor?.defaultPermissionMode,
                             running: store.running.contains(thread.id), store: store,
                             requestFullAccess: { fullAccessThread = $0 })
            .equatable()
            // Take the row's free space ahead of the Spacer so the controls can compact themselves.
            .layoutPriority(1)
    }
    private func canAddImages(_ thread: WorkspaceThread) -> Bool {
        store.supportsImages(thread.harness) && !store.importingImages.contains(thread.id) && (store.draftImages[thread.id]?.count ?? 0) < 4
    }
    private func composer(_ thread: WorkspaceThread) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            queuedMessages(thread)
            ForEach(store.attachments[thread.id] ?? []) { attachment in
                HStack {
                    Label(attachment.label, systemImage: "curlybraces").lineLimit(1)
                    Spacer(); Button { store.attachments[thread.id]?.removeAll { $0.id == attachment.id } } label: { Image(systemName: "xmark") }.buttonStyle(HoverButtonStyle()).help("Remove attachment")
                }.font(.system(size: 14)).padding(7).background(theme.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            }
            ForEach(store.browserAnnotations[thread.id] ?? []) { annotation in
                HStack {
                    // The tooltip shows exactly what will be sent with the message.
                    Label(annotation.label, systemImage: "cursorarrow.rays").lineLimit(1).truncationMode(.middle).help(annotation.promptContext)
                    Spacer(); Button { store.browserAnnotations[thread.id]?.removeAll { $0.id == annotation.id } } label: { Image(systemName: "xmark") }
                        .buttonStyle(HoverButtonStyle()).help("Remove annotation").accessibilityLabel("Remove annotation")
                }.font(.system(size: 14)).padding(7).background(theme.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            }
            ImageStrip(images: store.draftImages[thread.id] ?? []) { id in store.draftImages[thread.id]?.removeAll { $0.id == id } }
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
                        commands: store.commandCatalogs[store.modelKey(thread)] ?? [],
                        providerTitle: thread.harness.title,
                        commandsLoading: store.loadingCommands.contains(store.modelKey(thread)),
                        commandError: store.commandErrors[store.modelKey(thread)],
                        refreshCommands: { Task { await store.loadCommands(thread, refresh: true) } },
                        placeholder: store.running.contains(thread.id) ? "Add a follow-up…" : store.isProjectChat ? "Ask about this project…" : "Ask anything…",
                        onChange: { store.drafts[thread.id] = $0 },
                        onPasteImage: { store.pasteScreenshot(from: $0, threadID: thread.id) }, onSend: { store.send() })
                .id(thread.id)
                .task(id: "\(store.modelKey(thread)):\(store.claudeConfigurationID):\(store.codexConfigurationID)") { await store.loadCommands(thread) }
            HStack(spacing: 10) {
                Button { store.chooseImages(threadID: thread.id) } label: {
                    Image(systemName: "plus").frame(width: 16, height: 16)
                }
                .buttonStyle(HoverButtonStyle())
                .help(store.supportsImages(thread.harness) ? "Add images" : "Images are unavailable with this provider")
                .accessibilityLabel("Add images")
                .disabled(!canAddImages(thread))
                .composerStop(.attach, enabled: canAddImages(thread))
                if store.importingImages.contains(thread.id) {
                    ProgressView().controlSize(.small).accessibilityLabel("Loading images")
                }
                agentControls(thread)
                Spacer(minLength: 0)
                ContextUsageView(usage: thread.conversationUsage, compaction: thread.lastCompaction,
                                 provider: thread.harness.title,
                                 supportsUsage: store.harnessDescriptors.first { $0.id == thread.harness }?.supportsConversationUsage == true,
                                 supportsCompaction: store.harnessDescriptors.first { $0.id == thread.harness }?.supportsCompactionStatus == true)
                    .id(thread.id)
                if store.running.contains(thread.id) {
                    // Fixed size: the agent controls take the row's free space first and would
                    // otherwise compress a text button to nothing.
                    Button { store.stop(thread.id) } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(.bordered).fixedSize().hoverFeedback()
                        .help("Stop the agent (⌘.)").accessibilityLabel("Stop")
                        .composerStop(.stop)
                }
                Button { store.send() } label: {
                    Image(systemName: store.running.contains(thread.id) ? "text.badge.plus" : "arrow.up")
                }.buttonStyle(.borderedProminent).foregroundStyle(theme.onAccent).hoverFeedback()
                    .disabled(!store.canSend(thread))
                    .composerStop(.send, enabled: store.canSend(thread))
                    .help(store.running.contains(thread.id) ? "Queue message (Return)" : "Send message (Return)")
                    .accessibilityLabel(store.running.contains(thread.id) ? "Queue message" : "Send message")
            }
            if store.supportsModels(thread.harness) {
                if let error = store.modelErrors[store.modelKey(thread)] {
                    Text(error).font(.system(size: 12)).foregroundStyle(theme.secondary)
                } else if let modelID = thread.agentSettings.model, let catalog = store.modelCatalogs[store.modelKey(thread)], !catalog.contains(where: { $0.model == modelID }) {
                    Text("The saved model is unavailable. Choose another in Agent settings.").font(.system(size: 12)).foregroundStyle(theme.secondary)
                }
            }
            if thread.harness == .claude, store.claudeAuthStatus?.loggedIn == false {
                Text("Claude is signed out. Open Settings → Agents → Open CLI sign-in.")
                    .font(.system(size: 12)).foregroundStyle(theme.secondary)
            }

        }.padding(12).background(theme.panel, in: RoundedRectangle(cornerRadius: 10))
            // 8 pt from the window's bottom edge, level with the sidebar and review cards.
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary)).padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)
            .environment(\.composerControls, composerControls)
    }
    @ViewBuilder private func queuedMessages(_ thread: WorkspaceThread) -> some View {
        let messages = store.queuedMessages[thread.id] ?? []
        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Queued · \(messages.count)").font(.system(size: 12, weight: .medium))
                    Spacer()
                    if !store.running.contains(thread.id) {
                        Button("Send queued") { store.resumeQueue(thread.id) }
                            .disabled(store.steeringMessages[thread.id] != nil).controlSize(.small)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(messages) { queued in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(queued.message.text.isEmpty ? "Image message" : queued.message.text)
                                        .font(.system(size: 13)).lineLimit(2).help(queued.message.text)
                                    if !queued.message.images.isEmpty || !queued.message.attachments.isEmpty || !queued.message.browserAnnotations.isEmpty {
                                        Text("\(queued.message.images.count) images · \(queued.message.attachments.count) code selections"
                                             + (queued.message.browserAnnotations.isEmpty ? "" : " · \(queued.message.browserAnnotations.count) annotations"))
                                            .font(.system(size: 11)).foregroundStyle(theme.secondary)
                                    }
                                    if let error = store.queueErrors[queued.id] {
                                        Text(error).font(.system(size: 11)).foregroundStyle(theme.red)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if store.steeringMessages[thread.id] == queued.id {
                                    ProgressView().controlSize(.small).accessibilityLabel("Sending steering message")
                                } else {
                                    if store.running.contains(thread.id), thread.harness == .codex {
                                        Button("Steer now") { store.steerQueued(queued.id, threadID: thread.id) }
                                            .controlSize(.small).disabled(!store.canSteer(thread))
                                            .accessibilityIdentifier("steer-\(queued.id)")
                                    }
                                    Button { store.removeQueued(queued.id, threadID: thread.id) } label: { Image(systemName: "xmark") }
                                        .buttonStyle(HoverButtonStyle()).help("Remove queued message").accessibilityLabel("Remove queued message")
                                        .accessibilityIdentifier("remove-queued-\(queued.id)")
                                }
                            }.padding(8).background(theme.surface, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }.frame(height: min(CGFloat(messages.count) * 72, 144))
                Text(store.pausedQueues.contains(thread.id) ? "Queue paused. Messages are kept here until you send them." : "Sends in order after the current turn. Queued messages stay here until you quit.")
                    .font(.system(size: 11)).foregroundStyle(theme.secondary)
            }.fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MessageHover<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovering = false
    var body: some View {
        content(hovering).contentShape(Rectangle()).onHover { hovering = $0 }
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
struct DraftEditor: View {
    @ObservedObject var drafts: DraftStore
    let threadID: UUID
    let focusRequest: Int
    let theme: AppTheme
    let commands: [AgentCommand]
    let providerTitle: String
    let commandsLoading: Bool
    let commandError: String?
    let refreshCommands: () -> Void
    let placeholder: String
    let onChange: (String) -> Void
    let onPasteImage: (NSPasteboard) -> Bool
    let onSend: () -> Void
    @State private var selectedCommand = 0
    @State private var dismissedText: String?
    @State private var editorHeight = ComposerTextView.minHeight
    private var text: String { drafts.values[threadID] ?? "" }
    private var matching: [AgentCommand] { SlashCommandQuery.matches(commands, text: text) }
    private var showingCommands: Bool { SlashCommandQuery.prefix(in: text) != nil && dismissedText != text }
    private func choose(_ command: AgentCommand) {
        onChange(SlashCommandQuery.insertion(command)); selectedCommand = 0
    }
    private func commandKey(_ code: UInt16) -> Bool {
        guard showingCommands else { return false }
        if code == 53 { dismissedText = text; return true }
        guard !matching.isEmpty else { return false }
        if code == 125 || code == 126 {
            selectedCommand = (min(selectedCommand, matching.count - 1) + (code == 125 ? 1 : matching.count - 1)) % matching.count
            return true
        }
        if code == 36 || code == 76 || code == 48 {
            choose(matching[min(selectedCommand, matching.count - 1)]); return true
        }
        return false
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showingCommands {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Skills & commands").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button("Refresh", action: refreshCommands).font(.caption).disabled(commandsLoading)
                    }
                    if commandsLoading {
                        Text("Loading from \(providerTitle)…").font(.caption).foregroundStyle(theme.secondary)
                    } else if let commandError {
                        Text(commandError).font(.caption).foregroundStyle(theme.secondary)
                    } else if matching.isEmpty {
                        Text("No matching commands reported by this CLI. Check your provider’s skills and this chat’s working directory.")
                            .font(.caption).foregroundStyle(theme.secondary)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(spacing: 2) {
                                    ForEach(Array(matching.enumerated()), id: \.element.id) { index, command in
                                        Button { choose(command) } label: {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text("/\(command.name) \(command.argumentHint)").font(.system(size: 13, weight: .medium))
                                                if !command.description.isEmpty {
                                                    Text(command.description).font(.system(size: 12)).foregroundStyle(theme.secondary).lineLimit(2)
                                                }
                                            }.frame(maxWidth: .infinity, alignment: .leading).padding(7)
                                                .background(index == min(selectedCommand, matching.count - 1) ? theme.accent.opacity(0.12) : .clear,
                                                            in: RoundedRectangle(cornerRadius: 5))
                                        }.buttonStyle(.plain).id(index).accessibilityLabel("Insert /\(command.name)")
                                    }
                                }
                            }.frame(height: min(180, CGFloat(matching.count) * 62))
                                .onChange(of: selectedCommand) { _, index in proxy.scrollTo(index) }
                        }
                        Text("↑ ↓ to choose · Return or Tab to insert · Escape to dismiss").font(.system(size: 11)).foregroundStyle(theme.secondary)
                    }
                }.padding(8).background(theme.surface, in: RoundedRectangle(cornerRadius: 7))
            }
        ZStack(alignment: .topLeading) {
            if (drafts.values[threadID] ?? "").isEmpty {
                Text(placeholder).font(.system(size: 14)).foregroundStyle(theme.subtle)
                    .padding(.top, 5).padding(.leading, 5).allowsHitTesting(false)
            }
            ComposerTextView(focusRequest: focusRequest, theme: theme,
                             text: Binding(get: { drafts.values[threadID] ?? "" }, set: onChange),
                             onPasteImage: onPasteImage, onSend: onSend, onCommandKey: commandKey,
                             onHeightChange: { editorHeight = $0 })
        }.frame(height: min(max(editorHeight, ComposerTextView.minHeight), ComposerTextView.maxHeight))
        }.onChange(of: text) { _, _ in selectedCommand = 0; dismissedText = nil }
    }
}

/// Native plain-text editing keeps standard selection, undo and paste behavior,
/// while screenshot paste attaches an image instead of inserting rich text.
struct ComposerTextView: NSViewRepresentable {
    @Environment(\.composerControls) private var controls
    var focusRequest: Int
    var theme: AppTheme
    @Binding var text: String
    var onPasteImage: (NSPasteboard) -> Bool
    var onSend: () -> Void
    var onCommandKey: (UInt16) -> Bool = { _ in false }
    /// The text's height at the current width. The composer starts at two lines,
    /// grows with its content up to `maxHeight`, then scrolls.
    var onHeightChange: (CGFloat) -> Void = { _ in }
    static let minHeight: CGFloat = 44
    static let maxHeight: CGFloat = 220
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false; scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none; scroll.horizontalScrollElasticity = .none
        let editor = ScreenshotTextView(frame: scroll.contentView.bounds)
        editor.identifier = NSUserInterfaceItemIdentifier("OctoComposer")
        editor.isRichText = false; editor.importsGraphics = false; editor.allowsUndo = true
        editor.drawsBackground = false; editor.font = .systemFont(ofSize: 14); editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 0, height: 5)
        editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        // Fill the shortest composer so a click anywhere in it places the caret.
        editor.minSize = NSSize(width: 0, height: Self.minHeight)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.postsFrameChangedNotifications = true
        context.coordinator.observeHeight(of: editor)
        editor.setAccessibilityLabel("Message. Return to send; Shift-Return for a new line, continuing a list. Tab moves to the next control, or nests a list item. Paste text or a screenshot.")
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
            context.coordinator.reportHeight(of: editor)
        }
        editor.onPasteImage = onPasteImage
        editor.onCommandKey = onCommandKey
        editor.onTab = controls.map { controls in { controls.enter(from: $0, forward: $1) } }
        editor.onSend = { [weak editor, weak coordinator = context.coordinator] in
            if let editor { coordinator?.submit(editor) }
        }
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
        private var reportedHeight: CGFloat = 0
        private var frameObserver: NSObjectProtocol?
        init(_ parent: ComposerTextView) { self.parent = parent }
        deinit { if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) } }
        /// Width changes rewrap the text, so they are measured as well as edits.
        func observeHeight(of editor: NSTextView) {
            frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: editor, queue: .main) { [weak self, weak editor] _ in
                MainActor.assumeIsolated { if let self, let editor { self.reportHeight(of: editor) } }
            }
        }
        /// Measures the laid-out text rather than the view: inside a scroll view AppKit keeps the
        /// text view at least as tall as what is visible, so its frame never shrinks with the text.
        /// Reported after the current update, never during it.
        func reportHeight(of editor: NSTextView) {
            let used: CGFloat
            if let layout = editor.textLayoutManager {
                layout.ensureLayout(for: layout.documentRange)
                used = layout.usageBoundsForTextContainer.height
            } else if let layout = editor.layoutManager, let container = editor.textContainer {
                layout.ensureLayout(for: container)
                used = layout.usedRect(for: container).height
            } else { return }
            let height = ceil(used + editor.textContainerInset.height * 2)
            guard abs(height - reportedHeight) >= 0.5 else { return }
            reportedHeight = height
            DispatchQueue.main.async { [weak editor] in
                self.parent.onHeightChange(height)
                if let editor { editor.scrollRangeToVisible(editor.selectedRange()) }
            }
        }
        func submit(_ editor: NSTextView) {
            parent.onSend()
            // Clear accepted input before the next native key event, without
            // waiting for SwiftUI to update this representable.
            guard !editor.hasMarkedText(), editor.string != parent.text else { return }
            editor.string = parent.text
            editor.setSelectedRange(NSRange(location: (parent.text as NSString).length, length: 0))
            editor.scrollRangeToVisible(editor.selectedRange())
            reportHeight(of: editor)
        }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            reportHeight(of: editor)
        }
    }
}
final class ScreenshotTextView: NSTextView {
    /// Tab or Shift-Tab outside a list; true when the composer's controls took focus.
    var onTab: ((ScreenshotTextView, Bool) -> Bool)?
    var onPasteImage: ((NSPasteboard) -> Bool)?
    var onSend: (() -> Void)?
    var onCommandKey: ((UInt16) -> Bool)?
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
        if modifiers.isEmpty, !hasMarkedText(), onCommandKey?(event.keyCode) == true { return }
        if (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText() {
            if modifiers.isEmpty || modifiers == .command {
                if !event.isARepeat { onSend?() }
                return
            }
            if modifiers == .shift {
                if let edit = MarkdownListEditing.newline(in: string, selection: selectedRange()) { apply(edit) }
                else { insertNewlineIgnoringFieldEditor(nil) }
                return
            }
        }
        super.keyDown(with: event)
    }
    /// Tab moves to the next control, as in a form, except in a Markdown list where it nests the
    /// item. An item with nothing above it to nest under stays put rather than losing focus mid-list.
    /// Option-Tab still types a tab.
    override func insertTab(_ sender: Any?) {
        guard !hasMarkedText() else { return super.insertTab(sender) }
        if MarkdownListEditing.isInList(string, selection: selectedRange()) {
            if let edit = MarkdownListEditing.indent(in: string, selection: selectedRange()) { apply(edit) }
        } else if onTab?(self, true) != true { focusNextVisibleView(forward: true) }
    }
    override func insertBacktab(_ sender: Any?) {
        guard !hasMarkedText() else { return super.insertBacktab(sender) }
        if MarkdownListEditing.isInList(string, selection: selectedRange()) {
            if let edit = MarkdownListEditing.outdent(in: string, selection: selectedRange()) { apply(edit) }
        } else if onTab?(self, false) != true { focusNextVisibleView(forward: false) }
    }
    /// The window keeps hidden panels mounted (the review card slides offscreen, inactive tabs go
    /// transparent), and AppKit's key-view loop still visits them. Skip anything not on screen;
    /// with nothing visible to go to, focus stays here.
    func focusNextVisibleView(forward: Bool) {
        guard let window, let content = window.contentView else { return }
        // SwiftUI's hosting view runs the key-view loop, so step through it and judge each stop.
        for _ in 0..<32 {
            if forward { window.selectNextKeyView(window.firstResponder) } else { window.selectPreviousKeyView(window.firstResponder) }
            guard let responder = window.firstResponder, responder !== self else { return }
            let view = (responder as? NSTextView).flatMap { $0.isFieldEditor ? $0.delegate as? NSView : nil } ?? responder as? NSView
            if let view, Self.isOnScreen(view, in: content) { return }
        }
        window.makeFirstResponder(self)
    }
    static func isOnScreen(_ view: NSView, in content: NSView) -> Bool {
        guard !view.isHiddenOrHasHiddenAncestor else { return false }
        var ancestor: NSView? = view
        while let current = ancestor {
            if current.alphaValue < 0.01 || (current.layer.map { $0.opacity < 0.01 } ?? false) { return false }
            ancestor = current.superview
        }
        let frame = view.convert(view.bounds, to: content).intersection(content.bounds)
        return frame.width >= 4 && frame.height >= 4
    }
    /// Through the text system, so the edit is undoable and the draft binding hears about it.
    private func apply(_ edit: MarkdownListEditing.Edit) {
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
    }
}

/// The transcript compares its inputs, so publications that do not touch this
/// thread (sidebar changes, other threads streaming, model loading) skip rebuilding
/// and re-measuring every turn. Unchanged message arrays compare by identity.
/// Plain message text with the find query's occurrences highlighted.
private struct FindableText: View {
    let text: String
    @Environment(\.findHighlight) private var highlight
    @Environment(\.octoTheme) private var theme
    var body: some View {
        if highlight == nil { Text(verbatim: text) } else { Text(AttributedString(text).highlighting(highlight, theme: theme)) }
    }
}

private struct TranscriptTurns: View, Equatable {
    let messages: [ChatMessage]
    let harness: HarnessID
    let active: Bool
    let isProjectChat: Bool
    let find: ThreadFindResults
    let matchIndex: Int
    let expandedDetails: Set<UUID>
    let setExpanded: (UUID, Bool) -> Void
    let openFile: (URL) -> Void
    @Environment(\.octoTheme) private var theme
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.messages == rhs.messages && lhs.harness == rhs.harness && lhs.active == rhs.active
            && lhs.isProjectChat == rhs.isProjectChat && lhs.find == rhs.find
            && lhs.matchIndex == rhs.matchIndex && lhs.expandedDetails == rhs.expandedDetails
    }

    var body: some View {
        let turns = ChatTurn.turns(messages)
        let matches = Set(find.ids)
        let current = find.ids.indices.contains(matchIndex) ? find.ids[matchIndex] : nil
        VStack(alignment: .leading, spacing: 20) {
            if messages.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(isProjectChat ? "What are we building?" : "What's on your mind?").font(.title2.weight(.semibold))
                    Text(isProjectChat ? "Start a conversation about this project. Select code in the review pane to attach precise context." : "Ask a question, explore an idea, or work through something. Your conversations live here in Chats.").foregroundStyle(theme.secondary)
                }.padding(.top, 30)
            }
            if turns.count > 1 {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(turns.dropLast()) { turn in
                        turnView(turn, harness: harness, active: false, matches: matches, current: current)
                    }
                }
            }
            // Eager history keeps measured Markdown heights and native scroll
            // geometry stable while scrolling or resizing the chat column.
            ForEach(turns.suffix(1)) { turn in
                turnView(turn, harness: harness, active: active, matches: matches, current: current)
            }
        }
    }
    /// Matching messages get their occurrences highlighted; only those messages see a changed
    /// environment, so the rest of the transcript is not re-rendered while searching.
    private func transcriptMessage(_ message: ChatMessage, harness: HarnessID, matches: Set<UUID>, current: UUID?, footer: Bool = true) -> some View {
        messageView(message, harness: harness, footer: footer).id(message.id).padding(6)
            .environment(\.findHighlight, matches.contains(message.id) ? FindHighlight(query: find.query, current: message.id == current) : nil)
            .background(message.id == current ? theme.searchHighlight(active: true) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
    private func turnView(_ turn: ChatTurn, harness: HarnessID, active: Bool, matches: Set<UUID>, current: UUID?) -> some View {
        let finalReply = turn.messages.last { $0.role == .assistant }?.id
        return VStack(alignment: .leading, spacing: 18) {
            if let user = turn.user { transcriptMessage(user, harness: harness, matches: matches, current: current) }
            ForEach(turn.body) { group in
                if group.isDetails {
                    // Find searches only what is shown, so it never expands activity.
                    DisclosureGroup(isExpanded: Binding(get: { expandedDetails.contains(group.id) }, set: { setExpanded(group.id, $0) })) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(group.messages) { transcriptMessage($0, harness: harness, matches: matches, current: current) }
                        }.padding(.top, 10)
                    } label: { Text(group.summary) }
                    .disclosureGroupStyle(WorkDisclosureStyle())
                    .font(.system(size: 13)).foregroundStyle(theme.secondary).padding(.horizontal, 6)
                } else {
                    // Updates between work are narration, as in the provider apps: only the turn's
                    // final reply reserves room for copy and time, so the work rows sit close to them.
                    ForEach(group.messages) { message in
                        transcriptMessage(message, harness: harness, matches: matches, current: current,
                                          footer: message.role != .assistant || message.id == finalReply)
                    }
                }
            }
            // The running turn ends with its live status, so it stays in view while output streams in;
            // a finished turn keeps the same place for how long it took.
            if active || turn.user?.work != nil {
                VStack(alignment: .leading, spacing: 10) {
                    workLabel(turn, active: active)
                    Divider().overlay(theme.border.opacity(0.25))
                }.font(.system(size: 13)).foregroundStyle(theme.secondary).padding(.horizontal, 6)
            }
        }
    }
    @ViewBuilder private func workLabel(_ turn: ChatTurn, active: Bool) -> some View {
        if active {
            HStack(spacing: 8) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ShimmerText(text: "Working for \(TurnWork.duration(context.date.timeIntervalSince(turn.user?.work?.startedAt ?? context.date)))")
                }.fixedSize()
                if let status = turn.liveStatus {
                    Text("· \(status)").lineLimit(1).truncationMode(.tail)
                }
            }
        } else if let label = turn.user?.work?.label {
            Text(label)
        }
    }
    private func timestamp(_ message: ChatMessage) -> some View {
        let date = message.completedAt ?? message.createdAt
        return Text(date, format: .dateTime.weekday(.wide).hour().minute())
            .font(.system(size: 11)).foregroundStyle(theme.secondary)
            .help(date.formatted(date: .complete, time: .standard))
    }
    private func messageView(_ message: ChatMessage, harness: HarnessID, footer: Bool) -> some View {
        MessageHover { hovering in
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
                            FindableText(text: message.text)
                                .font(message.role == .activity ? .system(size: 13, design: .monospaced) : message.role == .reasoning ? .system(size: 13) : .system(size: 14))
                                .lineSpacing(message.role == .user ? 6 : 0)
                                .foregroundStyle(message.role == .error ? theme.red : message.role == .activity || message.role == .reasoning ? theme.secondary : theme.prose)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ImageStrip(images: message.images)
                        ForEach(message.attachments) { attachment in
                            Label(attachment.label, systemImage: "curlybraces").font(.system(size: 12)).padding(6)
                                .background(theme.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                        }
                        ForEach(message.browserAnnotations) { annotation in
                            Label(annotation.label, systemImage: "cursorarrow.rays").font(.system(size: 12)).lineLimit(1).padding(6)
                                .background(theme.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 4)).help(annotation.promptContext)
                        }
                    }
                    .padding(message.role == .user ? 14 : 0)
                    .background(message.role == .user ? theme.surface : .clear, in: RoundedRectangle(cornerRadius: 16))
                    if footer && (message.role == .user || message.role == .assistant || message.role == .error) {
                        HStack(spacing: 10) {
                            if message.isSteering == true { Text("Steering message").font(.system(size: 11)) }
                            Group {
                                if message.role == .assistant {
                                    Button { copyResponseText(message.text) } label: { Image(systemName: "doc.on.doc") }
                                        .buttonStyle(HoverButtonStyle()).help("Copy original response")
                                        .accessibilityLabel("Copy original response")
                                }
                                timestamp(message)
                            }
                            // Reserve their space: hovering must never reflow the response.
                            .opacity(hovering ? 1 : 0).allowsHitTesting(hovering)
                        }.foregroundStyle(theme.secondary)
                    }
                }.frame(maxWidth: message.role == .user ? 620 : .infinity, alignment: message.role == .user ? .trailing : .leading)
            }
        }
    }
}

struct ImageStrip: View {
    let images: [ImageAttachment]
    var remove: ((UUID) -> Void)? = nil
    @Environment(\.octoTheme) private var theme
    var body: some View {
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
                                if let remove {
                                    Button { remove(attachment.id) } label: { Image(systemName: "xmark.circle.fill") }
                                        .buttonStyle(HoverButtonStyle()).accessibilityLabel("Remove image")
                                }
                            }
                        }
                    }
                }
            }.frame(height: 100)
        }
    }
}

/// Building these menus converts every item to AppKit and measures it. Compare
/// plain inputs so unrelated store publications (including streamed text) skip it.
/// Actions capture only values that participate in equality.
private struct AgentControls: View, Equatable {
    struct Provider: Equatable {
        let id: HarnessID
        let installed: Bool
        let supportsModels: Bool
        let models: [AgentModel]
        let loadingModels: Bool
        let modelError: String?
    }
    let threadID: UUID
    let directory: String
    let harness: HarnessID
    let settings: AgentSettings
    /// Choosing another provider then starts a new thread.
    let hasHistory: Bool
    let providers: [Provider]
    let permissionOptions: [AgentPermissionOption]
    let defaultPermission: AgentPermissionMode?
    let running: Bool
    let store: AppStore
    let requestFullAccess: (UUID) -> Void
    @Environment(\.octoTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.threadID == rhs.threadID && lhs.directory == rhs.directory && lhs.harness == rhs.harness
            && lhs.settings == rhs.settings && lhs.hasHistory == rhs.hasHistory && lhs.providers == rhs.providers
            && lhs.permissionOptions == rhs.permissionOptions && lhs.defaultPermission == rhs.defaultPermission
            && lhs.running == rhs.running && lhs.store === rhs.store
    }

    /// Width offered to the controls, and the natural width of the uncompacted row.
    @State private var available: CGFloat = .infinity
    @State private var natural: CGFloat = 0

    // ViewThatFits re-measured both candidate rows of native popup buttons on every
    // layout pass (~45 ms per chat publication). Measure once per size or content
    // change instead, then lay out a single row.
    var body: some View {
        let compact = natural > available
        // Never fixed-size: the frame must report the offered width, not the row's own.
        HStack(spacing: 4) { agentMenu.composerStop(.agent); permissionsMenu(compact: compact).composerStop(.permissions) }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { proxy in Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in available = width } }
            }
            .background(alignment: .leading) {
                HStack(spacing: 4) { agentMenu; permissionsMenu(compact: false) }
                    .fixedSize()
                    .hidden().allowsHitTesting(false).accessibilityHidden(true)
                    .background {
                        GeometryReader { proxy in Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in natural = width } }
                    }
            }
    }
    private func permissionsMenu(compact: Bool) -> some View {
        let selected = settings.permissionMode ?? defaultPermission
        let title = permissionOptions.first { $0.mode == selected }?.title ?? selected?.title ?? "CLI permissions"
        return Menu {
            if permissionOptions.isEmpty {
                Text("Uses CLI defaults. Permission controls are unavailable in this adapter.")
            } else {
                Text("Permissions for the next turn")
                ForEach(permissionOptions) { option in
                    Button {
                        if option.mode == .fullAccess { requestFullAccess(threadID) }
                        else { store.selectPermissions(option.mode, threadID: threadID) }
                    } label: {
                        VStack(alignment: .leading) {
                            if option.mode == selected { Label(option.title, systemImage: "checkmark") }
                            else { Text(option.title) }
                            Text(option.detail).font(.caption)
                        }
                    }.help(option.detail)
                }
            }
        } label: {
            Label(title, systemImage: selected == .fullAccess ? "exclamationmark.shield" : "hand.raised")
                .labelStyle(PermissionLabelStyle(compact: compact))
                .font(.system(size: 12)).foregroundStyle(selected == .fullAccess ? theme.yellow : theme.secondary)
        }.hoverMenuStyle(chevron: true).fixedSize()
            .help(title)
            .accessibilityLabel("Permissions: \(title)")
            .disabled(running)
    }
    private var current: Provider? { providers.first { $0.id == harness } }
    private func icon(_ provider: HarnessID) -> Image { Image(nsImage: ProviderMark.menuImage(provider, dark: colorScheme == .dark)) }

    /// Providers first; each provider's submenu holds its models, and the current one also its reasoning.
    private var agentMenu: some View {
        let selected = current?.models.first { $0.model == settings.model }
        let summary = [harness.title, selected?.displayName ?? settings.model,
                       settings.reasoningEffort.map { $0 == "xhigh" ? "Extra high" : $0.capitalized }]
            .compactMap { $0 }.joined(separator: " · ")
        return Menu {
            ForEach(providers, id: \.id) { provider in
                Menu {
                    providerItems(provider, selected: selected)
                } label: {
                    Label { Text(provider.id.title + (provider.installed ? "" : " · not installed")) } icon: { icon(provider.id) }
                }
            }
        } label: {
            Label { Text(summary).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle) } icon: {
                icon(harness)
            }.labelStyle(.titleAndIcon)
        }.hoverMenuStyle(chevron: true).fixedSize(horizontal: false, vertical: true)
            .help("Provider, model, and reasoning").accessibilityLabel("Agent settings")
            .disabled(running)
    }

    @ViewBuilder private func providerItems(_ provider: Provider, selected: AgentModel?) -> some View {
        let isCurrent = provider.id == harness
        if !isCurrent && hasHistory { Text("Starts a new \(provider.id.title) thread") }
        if !provider.supportsModels {
            Button(isCurrent ? "Using \(provider.id.title) defaults" : "Use \(provider.id.title)") {
                store.selectAgent(provider.id, model: nil, directory: directory)
            }.disabled(isCurrent || !provider.installed)
        } else {
            if isCurrent && settings.model == nil { Text("Using session default") }
            if provider.models.isEmpty {
                Text(provider.loadingModels ? "Loading models…" : provider.installed ? (provider.modelError ?? "No models reported") : "Not installed")
            }
            ForEach(provider.models) { model in
                Button { store.selectAgent(provider.id, model: model, directory: directory) } label: {
                    if isCurrent && settings.model == model.model { Label(model.displayName, systemImage: "checkmark") }
                    else { Text(model.displayName) }
                }.help(model.description).disabled(!provider.installed)
            }
            if isCurrent {
                Divider()
                Menu("Reasoning") {
                    if selected == nil { Text("Choose a model first") }
                    ForEach(selected?.supportedReasoningEfforts ?? []) { option in
                        Button { store.selectReasoning(option.reasoningEffort) } label: {
                            if settings.reasoningEffort == option.reasoningEffort { Label(option.title, systemImage: "checkmark") }
                            else { Text(option.title) }
                        }.help(option.description)
                    }
                }.disabled(selected?.supportedReasoningEfforts.isEmpty != false)
            }
            if provider.installed {
                Divider()
                Button(provider.loadingModels ? "Loading models…" : "Refresh models") {
                    let store = store, directory = directory, id = provider.id
                    Task { await store.loadModels(directory: directory, harness: id, refresh: true) }
                }.disabled(provider.loadingModels)
            }
        }
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
