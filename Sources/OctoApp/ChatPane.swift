import AppKit
import SwiftUI
import OctoCore
import OctoAgents

struct ChatPane: View {
    @ObservedObject var store: AppStore
    @Environment(\.octoTheme) private var theme
    @State private var matchIndex = 0
    var body: some View {
        VStack(spacing: 0) {
            if let thread = store.thread {
                HStack {
                    Image(systemName: "bubble.left.and.text.bubble.right"); Text(thread.harness.title).fontWeight(.medium)
                    Spacer(); if store.running.contains(thread.id) { ProgressView().controlSize(.small) } else { Text("Local").foregroundStyle(theme.secondary) }
                }.font(.system(size: 15)).padding(13)
                Divider()
                findBar.frame(height: store.findingThread ? 50 : 0).clipped()
                    .opacity(store.findingThread ? 1 : 0).allowsHitTesting(store.findingThread).accessibilityHidden(!store.findingThread)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            if thread.messages.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("What are we building?").font(.title2.weight(.semibold))
                                    Text("Start a conversation about this project. Select code in the review pane to attach precise context.").foregroundStyle(theme.secondary)
                                }.padding(.top, 30)
                            }
                            ForEach(thread.messages) { message in
                                messageView(message, harness: thread.harness).id(message.id)
                                    .padding(6)
                                    .background(matchIDs.contains(message.id) ? theme.searchHighlight(active: matchIDs.firstIndex(of: message.id) == matchIndex) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding(20)
                    }
                    .onChange(of: thread.messages.last?.text) { _, _ in if !store.findingThread { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: store.threadQuery) { _, _ in matchIndex = 0; scrollToMatch(proxy) }
                    .onChange(of: store.findStep) { old, new in
                        guard !matchIDs.isEmpty else { return }
                        matchIndex = (matchIndex + (new > old ? 1 : -1) + matchIDs.count) % matchIDs.count
                        scrollToMatch(proxy)
                    }
                    .onChange(of: thread.id) { _, _ in store.threadQuery = ""; matchIndex = 0; proxy.scrollTo("bottom", anchor: .bottom) }
                }
                ForEach(store.approvals[thread.id] ?? []) { approval in
                    VStack(alignment: .leading, spacing: 9) {
                        Label(approval.title, systemImage: "hand.raised").font(.headline)
                        ScrollView { Text(approval.detail).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 130)
                        HStack { Button("Decline") { store.answer(approval, threadID: thread.id, allow: false) }.hoverFeedback(); Button("Allow Once") { store.answer(approval, threadID: thread.id, allow: true) }.buttonStyle(.borderedProminent).foregroundStyle(theme.onAccent).hoverFeedback() }
                    }.padding(12).background(theme.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8)).padding(12)
                }
                composer(thread)
                    .task(id: "\(thread.harness.rawValue):\(thread.workingDirectory):\(store.codexConfigurationID)") {
                        if thread.harness == .codex { await store.loadModels(directory: thread.workingDirectory) }
                    }
            } else { ContentUnavailableView("Start a thread", systemImage: "bubble.left", description: Text("Choose New Thread to work with an agent.")) }
        }.frame(maxWidth: 840, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    private func messageView(_ message: ChatMessage, harness: HarnessID) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if message.role != .activity {
                Text(message.role == .user ? "You" : message.role == .error ? "Connection issue" : harness.title)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.secondary)
            }
            Text(message.text).font(message.role == .activity ? .system(size: 13, design: .monospaced) : .system(size: 15))
                .foregroundStyle(message.role == .error ? theme.red : message.role == .activity ? theme.secondary : theme.foreground)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            imageStrip(message.images)
            ForEach(message.attachments) { attachment in
                Label(attachment.label, systemImage: "curlybraces").font(.system(size: 12)).padding(6).background(theme.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            }
        }
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
            .padding(.horizontal, 7).padding(.vertical, 5).hoverFeedback()
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
                                        .buttonStyle(HoverButtonStyle()).accessibilityLabel("Remove screenshot")
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
            ZStack(alignment: .topLeading) {
                if (store.drafts[thread.id] ?? "").isEmpty {
                    Text("Ask about this project…").font(.system(size: 15)).foregroundStyle(theme.subtle)
                        .padding(.top, 5).padding(.leading, 5).allowsHitTesting(false)
                }
                ComposerTextView(focusRequest: store.composerFocus, theme: store.theme, text: Binding(get: { store.drafts[thread.id] ?? "" }, set: { store.drafts[thread.id] = $0 }),
                                 onPasteImage: { store.pasteScreenshot(from: $0, threadID: thread.id) }, onSend: { store.send() })
                    .id(thread.id).frame(height: 76)
            }
            HStack(spacing: 10) {
                agentMenu(thread).frame(maxWidth: 380, alignment: .leading)
                Spacer(minLength: 0)
                if store.running.contains(thread.id) { Button("Stop") { store.stop(thread.id) }.controlSize(.small).hoverFeedback() }
                else { Button { store.send() } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderedProminent).foregroundStyle(theme.onAccent).hoverFeedback().disabled(!store.canSend(thread)) }
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
        let editor = ScreenshotTextView()
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
        editor.setAccessibilityLabel("Message. Paste text or a screenshot.")
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ScreenshotTextView else { return }
        if editor.string != text { editor.string = text }
        editor.onPasteImage = onPasteImage; editor.onSend = onSend
        editor.textColor = theme.textColor; editor.insertionPointColor = theme.cursorColor
        editor.selectedTextAttributes = [.backgroundColor: theme.selectionColor, .foregroundColor: theme.textColor]
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { editor.window?.makeFirstResponder(editor) }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var focusRequest = 0
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
        if event.keyCode == 36 && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            onSend?(); return
        }
        super.keyDown(with: event)
    }
}
