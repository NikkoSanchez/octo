import SwiftUI
import Combine
import OctoCore
import OctoGit
import OctoAgents
import OctoReview
import OctoTerminal

struct WorkspaceView: View {
    @ObservedObject var store: AppStore
    @StateObject private var review: ReviewModel
    @State private var editorWindowID = UUID()
    init(store: AppStore) {
        self.store = store
        _review = StateObject(wrappedValue: ReviewModel(editors: store.fileEditors))
    }
    @State private var sidebarOpen = true
    @State private var compactSidebarOpen = false
    @State private var sidebarWidth: CGFloat = 290
    @State private var sidebarDragStart: CGFloat?
    @State private var windowWidth: CGFloat = 1380
    @State private var palette: PaletteMode?
    @State private var paletteAction: (() -> Void)?
    @State private var fileAction: FileAction?
    @State private var reviewFocus = 0
    @State private var surfacePickerFocus = 0
    @State private var showingShortcutHints = false
    @State private var showingProjectActions = false
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.octoTheme) private var theme
    @Environment(\.scenePhase) private var phase
    var body: some View {
        GeometryReader { geometry in
            let layout = layout(at: geometry.size.width)
            ZStack(alignment: .leading) {
                VStack(spacing: 0) {
                    if titlebarSpansDetail { titlebar(showSidebarToggle: !layout.sidebarVisible) }
                    GeometryReader { contentGeometry in
                        ZStack {
                            threadWorkspace.opacity(store.showingTerminal ? 0 : 1).allowsHitTesting(!store.showingTerminal).accessibilityHidden(store.showingTerminal)
                                .overlay(alignment: .topTrailing) {
                                    // Below the chat column's titlebar, which now shares this area, so it never covers the toolbar capsule.
                                    if projectActionsAvailable && projectActionsFloat(layout) {
                                        projectActions(floating: true).padding(.horizontal, 16).padding(.top, (titlebarSpansDetail ? 0 : Self.titlebarHeight) + 16).transition(.opacity)
                                    }
                                }
                            TerminalPane(store: store, terminal: store.terminal, visible: store.showingTerminal && !layout.overlayVisible)
                                .background(theme.background)
                                .offset(y: store.showingTerminal ? 0 : contentGeometry.size.height)
                                .allowsHitTesting(store.showingTerminal).accessibilityHidden(!store.showingTerminal)
                        }
                        .clipped()
                    }
                }
                .frame(height: geometry.size.height).background(theme.background)
                .modifier(PanelFrame(width: layout.detailWidth, x: layout.detailOffset))
                .allowsHitTesting(!layout.overlayVisible).accessibilityHidden(layout.overlayVisible)

                Color.black.opacity(layout.overlayVisible ? 0.2 : 0)
                    .contentShape(Rectangle()).onTapGesture { closeCompactSidebar() }
                    .allowsHitTesting(layout.overlayVisible).accessibilityHidden(true)

                sidebar
                .glassPanel()
                .padding(.leading, 8).padding(.vertical, 8)
                .frame(width: layout.sidebarWidth, height: geometry.size.height)
                .offset(x: layout.sidebarVisible ? 0 : -layout.sidebarWidth - 7)
                .allowsHitTesting(layout.sidebarVisible).accessibilityHidden(!layout.sidebarVisible)

                // The card's own edge separates it; the divider shows only while hovered or dragged.
                ResizeHandle(enabled: layout.sidebarVisible && !layout.compact, color: .clear, activeColor: NSColor(theme.activeBorder), onDrag: { translation in
                    if sidebarDragStart == nil { sidebarDragStart = sidebarWidth }
                    sidebarWidth = min(320, max(240, (sidebarDragStart ?? sidebarWidth) + translation))
                }, onEnd: { sidebarDragStart = nil })
                    .frame(width: 7)
                    .opacity(layout.sidebarVisible && !layout.compact ? 1 : 0)
                    .offset(x: layout.sidebarVisible ? layout.sidebarWidth : -7)
                    .accessibilityHidden(!layout.sidebarVisible || layout.compact)
                    .accessibilityLabel("Resize sidebar")
                    .accessibilityValue("\(Int(sidebarWidth)) points")
                    .accessibilityAdjustableAction { direction in sidebarWidth = min(320, max(240, sidebarWidth + (direction == .increment ? 20 : -20))) }
            }
            .clipped()
            .onChange(of: geometry.size.width, initial: true) { _, width in windowWidth = width }
        }
        // Content runs beneath the transparent titlebar; the traffic lights float over the sidebar card.
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowChrome().frame(width: 0, height: 0))
        .onChange(of: layout.compact) { _, _ in compactSidebarOpen = false }
        .onChange(of: singleReview) { _, visible in
            if visible { NativeWorkspaceFocus.clear() }
        }
        .onChange(of: store.composerFocus) { _, _ in
            compactSidebarOpen = false
            if layout.detailWidth < 737 { store.showingReview = false }
        }
        // The picker's letter keys need focus; it otherwise stays in the composer when the panel opens.
        .onChange(of: surfacePickerVisible) { _, visible in if visible { focusSurfacePicker() } }
        .onChange(of: store.showingReview) { _, visible in
            if visible { compactSidebarOpen = false; if singleReview { NativeWorkspaceFocus.clear() } }
            else if !store.showingTerminal {
                if store.findingThread { NativeWorkspaceFocus.focus("OctoThreadFind") }
                else { store.focusComposer() }
            }
        }
        .environment(\.shortcutHints, showingShortcutHints ? Dictionary(uniqueKeysWithValues: commands.filter { $0.isAvailable(inTerminal: store.showingTerminal) && $0.key != nil }.map { ($0.id, $0.shortcut) }) : [:])
        .focusedSceneValue(\.workspaceCommands, WorkspaceCommandContext(commands: commands, terminalVisible: store.showingTerminal))
        .background(WorkspaceKeyRouter(commands: commands, terminalVisible: store.showingTerminal, hintsChanged: { showingShortcutHints = $0 }).frame(width: 0, height: 0))
        .sheet(item: $palette, onDismiss: finishPalette) { mode in
            CommandPalette(mode: mode, entries: paletteEntries(mode), dismiss: { palette = nil }, activateEntry: { entry in
                paletteAction = entry.action
                palette = nil
            })
                .modifier(ThemedContent(theme: store.theme))
        }
        .sheet(item: $fileAction, onDismiss: {
            if review.browsingFiles { reviewFocus += 1 }
        }) { action in
            FileActionSheet(action: action, store: store) { path in
                if action.kind == .delete { store.updatePanelTabs(action.projectID) { $0.close(.file(path)) } }
                else { store.updatePanelTabs(action.projectID) { $0.openFile(path, pinned: true) } }
                await review.fileDidChange(path, deleted: action.kind == .delete, projectID: action.projectID, root: action.root)
                if action.kind == .delete, store.project?.id == action.projectID { syncReview() }
            }.modifier(ThemedContent(theme: store.theme))
        }
        .onChange(of: store.showingTerminal) { _, visible in
            compactSidebarOpen = false
            if !visible {
                if store.findingThread { NativeWorkspaceFocus.focus("OctoThreadFind") }
                else if !singleReview { store.composerFocus += 1 }
            }
        }
        .alert("Octo", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .task(id: reviewKey) { await refresh() }
        .onChange(of: phase) { _, phase in if phase == .active { Task { await refresh() } } }
        .onChange(of: store.running) { old, new in if new.count < old.count { Task { await refresh() } } }
    }
    private var layout: WorkspaceLayout { layout(at: windowWidth) }
    private func layout(at width: CGFloat) -> WorkspaceLayout {
        WorkspaceLayout(width: width, sidebarWidth: sidebarWidth, sidebarOpen: sidebarOpen, compactSidebarOpen: compactSidebarOpen)
    }
    private var surfacePickerVisible: Bool {
        store.isProjectChat && store.showingReview && !store.showingTerminal && store.project?.panelTabs.selected == nil
    }
    /// Takes focus from the composer's native text view, then focuses the picker once it is mounted.
    private func focusSurfacePicker() {
        NativeWorkspaceFocus.clear()
        DispatchQueue.main.async { surfacePickerFocus += 1 }
    }
    /// The project actions stand in for the review panel while it is hidden, as in T3 Code and Codex.
    private var projectActionsAvailable: Bool { store.isProjectChat && !store.showingReview && !store.showingTerminal }
    /// Float beside the chat column only when the card fits in the margin; otherwise it opens from the titlebar.
    private func projectActionsFloat(_ layout: WorkspaceLayout) -> Bool { (layout.detailWidth - 840) / 2 >= 260 + 32 }
    @ViewBuilder private func projectActions(floating: Bool) -> some View {
        if let project = store.project {
            let root = store.thread?.workingDirectory ?? project.rootPath
            ProjectActionsPanel(projectID: project.id, checkout: root, branch: review.branch, branches: review.branches,
                                diffStat: review.diffStat, changeCount: review.files.count,
                                agentRunning: project.threads.contains { store.running.contains($0.id) && $0.workingDirectory == root },
                                floating: floating, store: store, review: review,
                                openChanges: { showingProjectActions = false; showPanel { $0.showChanges() } })
                .equatable()
        }
    }
    private var singleReview: Bool { store.isProjectChat && layout.detailWidth < 737 && store.showingReview && !store.showingTerminal }
    /// Beside the chat, the review card runs the window's full height and the titlebar heads the chat
    /// column, as in the design. The terminal, the empty state and a review card covering the chat
    /// keep it above the whole detail area.
    private var titlebarSpansDetail: Bool { store.project == nil || store.showingTerminal || singleReview }
    private func toggleSidebar() {
        NativeWorkspaceFocus.clear()
        if layout.compact { compactSidebarOpen.toggle() } else { sidebarOpen.toggle() }
        if !layout.sidebarVisible { restoreFocus() }
    }
    private func closeCompactSidebar() {
        compactSidebarOpen = false
        restoreFocus()
    }
    private func showSidebar() {
        NativeWorkspaceFocus.clear()
        if layout.compact { compactSidebarOpen = true } else { sidebarOpen = true }
    }
    private func attachToDraft(_ attachment: CodeAttachment) {
        store.attach(attachment)
        if singleReview { store.focusComposer() }
    }
    private var reviewKey: String { (store.project?.id.uuidString ?? "") + (store.thread?.workingDirectory ?? "") }
    private func refresh() async {
        guard let project = store.project, store.isProjectChat else { return }
        review.adopt(project.panelTabs)
        await review.refresh(projectID: project.id, root: store.thread?.workingDirectory ?? project.rootPath)
    }
    private func openMarkdownFile(_ url: URL) {
        guard let project = store.project else { return }
        guard store.isProjectChat else {
            store.error = "Code review is available in project chats."
            return
        }
        let root = store.thread?.workingDirectory ?? project.rootPath
        guard let link = MarkdownFileLink(url: url, checkout: root) else {
            store.error = "This link does not point to a file inside this thread's checkout."
            return
        }
        store.showingTerminal = false; store.showingReview = true
        store.updatePanelTabs(project.id) { $0.openFile(link.path, pinned: false) }
        Task { await review.reveal(link, projectID: project.id, root: root) }
    }
    private var sidebar: some View {
        ProjectSidebar(store: store, switchProject: { NativeWorkspaceFocus.clear(); palette = .projects },
                       searchChats: { NativeWorkspaceFocus.clear(); palette = .chats }, hideSidebar: toggleSidebar,
                       didNavigate: { compactSidebarOpen = false })
    }
    /// Searches every chat across Chats and projects; the sidebar's search field does the same while it is shown.
    private var searchAllButton: some View {
        CornerButton(systemImage: "magnifyingglass") { NativeWorkspaceFocus.clear(); palette = .chats }
            .shortcutHint("chats").help("Search all chats (⌘K)").accessibilityLabel("Search all chats")
    }
    private var titlebarSubtitle: String {
        if store.showingTerminal { return "Project terminal workspace" }
        if store.project?.isChatCollection == true { return "Chats" }
        return [store.project?.name ?? "Local development", store.thread?.harness.title, review.branch.isEmpty ? nil : review.branch]
            .compactMap { $0 }.joined(separator: " · ")
    }
    /// The titlebar row (32 pt) and its 8 pt margins.
    static let titlebarHeight: CGFloat = 48
    private var toolbarHasButtons: Bool { store.showingTerminal || store.project != nil && store.isProjectChat }
    /// A 32 pt row whose centre line is the traffic lights' (24 pt from the window top), shared by the
    /// card's hide-sidebar button, so the show-sidebar button doesn't drop when the sidebar closes.
    private func titlebar(showSidebarToggle: Bool) -> some View {
        HStack(spacing: 10) {
            if showSidebarToggle {
                HStack(spacing: 6) {
                    CornerButton(systemImage: "sidebar.left", action: toggleSidebar)
                        .shortcutHint("sidebar").help("Show sidebar (⌘B)").accessibilityLabel("Show sidebar")
                    searchAllButton
                }.padding(.trailing, 10)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(store.showingTerminal ? "\(store.project?.name ?? "Octo") · Terminal" : store.thread?.title ?? "Welcome to Octo")
                    .font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Text(titlebarSubtitle).font(.system(size: 11.5)).foregroundStyle(theme.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if toolbarHasButtons { toolbarCapsule }
        }
        .frame(height: 32)
        // With the sidebar hidden the traffic lights (ending about 74 pt in) float over this row's leading edge.
        .padding(.leading, showSidebarToggle ? 92 : 16).padding(.trailing, 10)
        .padding(.top, 8).padding(.bottom, 8)
    }
    /// The thread's surfaces in one glass capsule: terminal, project actions and the review panel.
    private var toolbarCapsule: some View {
        HStack(spacing: 0) {
            if store.showingTerminal {
                Button { store.focusComposer() } label: { Image(systemName: "bubble.left") }
                    .buttonStyle(CapsuleToolbarButtonStyle()).shortcutHint("terminal").help("Back to thread").accessibilityLabel("Back to thread")
            } else if let project = store.project, store.isProjectChat {
                Button { store.openTerminal(project) } label: { Image(systemName: "terminal") }
                    .buttonStyle(CapsuleToolbarButtonStyle()).shortcutHint("terminal").help("Terminal").accessibilityLabel("Terminal")
            }
            if projectActionsAvailable && !projectActionsFloat(layout) {
                Button { showingProjectActions.toggle() } label: { GitBranchIcon(size: 15) }
                    .buttonStyle(CapsuleToolbarButtonStyle(active: showingProjectActions))
                    .help("Open in, branches and changes").accessibilityLabel("Project actions")
                    .popover(isPresented: $showingProjectActions, arrowEdge: .bottom) { projectActions(floating: false) }
            }
            if store.isProjectChat && !store.showingTerminal {
                Button { store.showingReview.toggle() } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(CapsuleToolbarButtonStyle(active: store.showingReview)).shortcutHint("review")
                    .help(store.showingReview ? "Hide review panel" : "Show review panel")
                    .accessibilityLabel(store.showingReview ? "Hide review panel" : "Show review panel")
            }
        }
        .padding(2).glassControl()
    }
    @ViewBuilder private var threadWorkspace: some View {
        if let project = store.project {
            ResizableColumns(minLeading: 300, minTrailing: 430, initialFraction: 0.42, trailingVisible: store.isProjectChat && store.showingReview, singleColumnWhenNarrow: true, showsIdleDivider: false) {
                VStack(spacing: 0) {
                    if !titlebarSpansDetail { titlebar(showSidebarToggle: !layout.sidebarVisible) }
                    ChatPane(store: store, isVisible: !store.showingTerminal && !singleReview && !layout.overlayVisible && palette == nil && store.error == nil, openFile: openMarkdownFile)
                }
            } trailing: {
                if !project.isChatCollection {
                    // Level with the sidebar card beside the chat; under the titlebar when it covers the chat.
                    reviewPane(project).glassPanel()
                        .padding(.leading, singleReview ? 8 : 0).padding(.trailing, 8)
                        .padding(.top, singleReview ? 0 : 8).padding(.bottom, 8)
                }
            }
        } else {
            ContentUnavailableView {
                Label("A home for your projects", systemImage: "square.stack.3d.up")
            } description: { Text("Add a Git repository to start an agent thread, review changes, or open your terminal.") }
            actions: { Button("Add Project…") { store.chooseProject() }.buttonStyle(.borderedProminent).foregroundStyle(theme.onAccent) }
        }
    }
    private func reviewPane(_ project: WorkspaceProject) -> some View {
        let tabs = project.panelTabs
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        // A segmented capsule: the selected tab is raised on the track.
                        HStack(spacing: 2) {
                            ForEach(tabs.tabs, id: \.self) { tab in panelTabButton(tab, tabs: tabs, project: project).id(tab) }
                        }.padding(3)
                            .background(tabs.tabs.isEmpty ? Color.clear : theme.field, in: Capsule())
                            .padding(.vertical, 2)
                    }
                    .onChange(of: tabs.selected) { _, selected in if let selected { proxy.scrollTo(selected) } }
                }
                .fixedSize(horizontal: false, vertical: true)
                Menu {
                    Button("Browser") { openBrowserTab() }
                    Button("Private Browser") { openBrowserTab(isPrivate: true) }
                    Button("Files") { showPanel { $0.showFiles() } }
                    Button("Changes") { showPanel { $0.showChanges() } }
                } label: { Image(systemName: "plus").font(.system(size: 13, weight: .medium)).frame(width: 30, height: 30).contentShape(Circle()) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).glassControl().fixedSize()
                    .help("Open a browser, files or changes").accessibilityLabel("Open a surface")
            }.padding(.leading, 12).padding(.trailing, 10).padding(.top, 10).padding(.bottom, 6)
            // The design's second row: scope and layout segments for Changes, file actions for Files.
            if tabs.showsReview { reviewControls(tabs: tabs, project: project).padding(.horizontal, 12).padding(.bottom, 6) }
            // A web page has no edge of its own; Changes, Files and the picker sit straight on the card.
            if tabs.selectedBrowser != nil { Rectangle().fill(theme.hairline).frame(height: 0.5) }
            ZStack {
                reviewContent(project, tabs: tabs).opacity(tabs.showsReview ? 1 : 0).allowsHitTesting(tabs.showsReview).accessibilityHidden(!tabs.showsReview)
                // Every open browser tab stays mounted so its page, scroll position and dev-server session survive.
                ForEach(tabs.browsers, id: \.self) { id in
                    let visible = tabs.selectedBrowser == id
                    BrowserPane(session: store.browserSession(id, projectID: project.id), isVisible: visible && store.showingReview && !store.showingTerminal) { store.attachBrowserScreenshot($0, projectID: project.id) }
                        .opacity(visible ? 1 : 0).allowsHitTesting(visible).accessibilityHidden(!visible)
                }
                if tabs.selected == nil {
                    SurfacePicker(changeCount: review.files.count, focusRequest: surfacePickerFocus,
                                  openBrowser: { openBrowserTab(isPrivate: $0) },
                                  openFiles: { showPanel { $0.showFiles() } },
                                  openChanges: { showPanel { $0.showChanges() } })
                }
            }
        }
    }
    private func panelTabButton(_ tab: PanelTab, tabs: PanelTabs, project: WorkspaceProject) -> some View {
        let selected = tabs.selected == tab
        return PanelTabChip(selected: selected, help: tab.path ?? "",
                            select: { showPanel { $0.select(tab) } },
                            pin: tab.path.map { path in { store.updatePanelTabs(project.id) { $0.pin(path) } } },
                            close: { closePanelTab(tab) }) {
            switch tab {
            case .changes:
                Image(systemName: "plus.forwardslash.minus").font(.system(size: 11))
                Text("Changes")
                Text("\(review.files.count)").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(theme.secondary)
            case .files:
                Image(systemName: "doc.on.doc").font(.system(size: 11))
                Text("Files")
            case .file(let path):
                Image(systemName: "doc.text").font(.system(size: 11))
                Text((path as NSString).lastPathComponent).italic(tabs.preview == path)
            case .browser(let id):
                PanelBrowserTabTitle(session: store.browserSession(id, projectID: project.id))
            }
        }
        .contextMenu {
            if let path = tab.path, tabs.preview == path { Button("Keep Open") { store.updatePanelTabs(project.id) { $0.pin(path) } } }
            Button("Close Tab") { closePanelTab(tab) }
            Button("Close Other Tabs") { for other in tabs.tabs where other != tab { closePanelTab(other) } }
                .disabled(tabs.tabs.count < 2)
        }
    }
    private func reviewControls(tabs: PanelTabs, project: WorkspaceProject) -> some View {
        HStack(spacing: 8) {
            if tabs.isBrowsingFiles {
                Button { store.updatePanelTabs(project.id) { $0.showsFileTree.toggle() } } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(CapsuleToolbarButtonStyle(active: tabs.showsFileTree)).shortcutHint("browseFiles")
                    .help(tabs.showsFileTree ? "Hide file tree" : "Show file tree").accessibilityLabel(tabs.showsFileTree ? "Hide file tree" : "Show file tree")
            }
            if !review.browsingFiles {
                CapsulePicker(label: "Diff scope", selection: $review.scope, options: [(.working, "Working"), (.staged, "Staged")]).help("Diff scope")
                CapsulePicker(label: "Diff layout", selection: $review.diffLayout, options: [(.stacked, "Stacked"), (.sideBySide, "Side by Side")]).help("Diff layout")
            }
            Spacer(minLength: 0)
            ProgressView().controlSize(.small).opacity(review.loading || review.loadingSnapshot ? 1 : 0).accessibilityHidden(!review.loading && !review.loadingSnapshot)
            if review.browsingFiles {
                Button { requestFileAction(.create, path: "") } label: { Image(systemName: "doc.badge.plus") }
                    .buttonStyle(CapsuleToolbarButtonStyle()).help("New file").accessibilityLabel("New file")
            }
            Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(CapsuleToolbarButtonStyle()).shortcutHint("refresh").help("Refresh changes").accessibilityLabel("Refresh changes")
        }
        .onChange(of: review.scope) { _, _ in
            if !review.browsingFiles, let file = review.files.first(where: { $0.path == review.selectedPath }) { Task { await review.select(file, projectID: project.id, root: store.thread?.workingDirectory ?? project.rootPath) } }
        }
    }
    /// Changed files sit above the diff as conversation rows (38 pt plus 6 pt of row insets).
    private var changesListHeight: CGFloat { CGFloat(review.files.count) * 44 + 10 }
    private func reviewContent(_ project: WorkspaceProject, tabs: PanelTabs) -> some View {
        VStack(spacing: 0) {
            if let error = review.error { Text(error).font(.system(size: 13)).foregroundStyle(theme.red).padding() }
                // Files keeps its tree beside the editor; Changes stacks its file rows above the diff.
                ResizableColumns(minLeading: 150, maxLeading: 260, minTrailing: 270, initialFraction: 0.3, leadingVisible: !review.browsingFiles || tabs.showsFileTree,
                                 stackedLeadingHeight: review.browsingFiles ? nil : changesListHeight, opaqueTrailing: false) {
                    ReviewFileLists(review: review, projectID: project.id, action: requestFileAction,
                                    openFile: { path, pinned in showPanel(focus: true) { $0.openFile(path, pinned: pinned) } },
                                    selectChange: { file in
                                        Task { await review.select(file, projectID: project.id, root: store.thread?.workingDirectory ?? project.rootPath) }
                                    })
                        .equatable()
                } trailing: {
                    VStack(spacing: 0) {
                        if let snapshot = review.snapshot {
                            Rectangle().fill(theme.hairline).frame(height: 0.5)
                            HStack(spacing: 8) {
                                Text(snapshot.path).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.head).help(snapshot.path)
                                Spacer(minLength: 8)
                                Button { store.openInEditor(snapshot, selection: review.selection) } label: {
                                    Text("Open in LazyVim").font(.system(size: 11.5, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 4)
                                        .background(theme.field, in: Capsule()).contentShape(Capsule())
                                }.buttonStyle(.plain).shortcutHint("editor")
                            }.padding(.leading, 16).padding(.trailing, 12).padding(.top, 9).padding(.bottom, 6)
                            if review.browsingFiles, let editor = review.editor {
                                InlineFilePane(session: editor, windowID: editorWindowID, theme: store.theme, focusRequest: reviewFocus,
                                    revealLine: review.revealLine, revealRequest: review.revealRequest,
                                    onSelection: { selection in
                                        if review.browsingFiles && review.editor === editor && !review.loadingSnapshot { review.selection = selection }
                                    }, onAskAgent: { if review.browsingFiles && review.editor === editor && !review.loadingSnapshot { attachToDraft($0) } },
                                    onEdit: { store.updatePanelTabs(project.id) { $0.pin(editor.context.path) } })
                                    .id(editor.id)
                            } else if let notice = snapshot.notice { Text(notice).font(.system(size: 13)).foregroundStyle(theme.secondary).padding(); Spacer() }
                            else if !review.browsingFiles && review.diffLayout == .sideBySide {
                                SideBySideDiffView(snapshot: snapshot, theme: store.theme, focusRequest: reviewFocus,
                                    onSelection: { if !review.loadingSnapshot && review.diffLayout == .sideBySide { review.selection = $0 } },
                                    onAskAgent: { if !review.loadingSnapshot { attachToDraft($0) } })
                            }
                            else {
                                NativeDiffView(snapshot: snapshot, theme: store.theme, focusRequest: reviewFocus, revealLine: review.revealLine, revealRequest: review.revealRequest, onSelection: { if !review.loadingSnapshot && (review.browsingFiles || review.diffLayout == .stacked) { review.selection = $0 } }, onAskAgent: { if !review.loadingSnapshot { attachToDraft($0) } })
                            }
                            Rectangle().fill(theme.hairline).frame(height: 0.5)
                            HStack {
                                Text(review.selection.map { $0.label } ?? "Hover a line and click + to attach code").font(.system(size: 12)).foregroundStyle(theme.secondary).lineLimit(1)
                                Spacer()
                                Button("Ask Agent") { if let selection = review.selection { attachToDraft(selection) } }
                                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).foregroundStyle(theme.onAccent)
                                    .disabled(review.selection == nil).controlSize(.small).shortcutHint("attach")
                            }.padding(.leading, 14).padding(.trailing, 12).padding(.top, 10).padding(.bottom, 12)
                        } else if review.browsingFiles, let path = tabs.selectedFile, !review.loadingSnapshot, !review.loading {
                            ContentUnavailableView {
                                Label("File not found", systemImage: "questionmark.folder")
                            } description: { Text("\(path) is not in this checkout.") }
                            actions: { Button("Close Tab") { closePanelTab(.file(path)) } }
                        } else if !review.loadingSnapshot { ContentUnavailableView(!review.browsingFiles && review.files.isEmpty ? "No changes" : "Choose a file", systemImage: !review.browsingFiles && review.files.isEmpty ? "checkmark.circle" : "doc.text.magnifyingglass") }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(!review.loadingSnapshot)
                        .overlay { if review.loadingSnapshot { theme.background.opacity(0.12).accessibilityLabel("Loading file") } }
                }
        }
    }
}

private struct TerminalPane: View {
    @ObservedObject var store: AppStore
    @ObservedObject var terminal: TerminalWorkspace
    var visible: Bool
    @Environment(\.octoTheme) private var theme
    private var closing: TerminalTab? { terminal.tabs.first { $0.id == store.closingTerminal } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if let project = store.project {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                    ForEach(terminal.tabs.filter { $0.projectID == project.id }) { tab in
                        HStack(spacing: 6) {
                            Button { terminal.select(tab) } label: { TerminalTabTitle(tab: tab).lineLimit(1).padding(.horizontal, 8).frame(minHeight: 30).contentShape(Rectangle()) }.buttonStyle(HoverButtonStyle(padded: false))
                            Button { store.closingTerminal = tab.id } label: { Image(systemName: "xmark").font(.system(size: 12)).frame(width: 24, height: 30) }.buttonStyle(HoverButtonStyle(padded: false)).shortcutHint("closeTerminal", active: terminal.selectedTabs[project.id] == tab.id).help("Close tab")
                        }.font(.system(size: 13)).padding(8).background(terminal.selectedTabs[project.id] == tab.id ? theme.selection : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    }
                        }
                    }
                    Button { terminal.newTab(projectID: project.id, directory: project.rootPath) } label: { Image(systemName: "plus").frame(width: 28, height: 30) }.buttonStyle(HoverButtonStyle(padded: false)).shortcutHint("newTerminal").help("New terminal tab")
                }
                Spacer(); Text("Ghostty").font(.system(size: 12)).foregroundStyle(theme.secondary)
            }.padding(8)
            Divider()
            TerminalSurfaces(workspace: terminal, projectID: store.project?.id, visible: visible)
        }
        .alert("Close terminal tab?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { store.closingTerminal = nil } })) {
            Button("Close Tab", role: .destructive) { if let closing { terminal.close(closing) }; store.closingTerminal = nil }
            Button("Cancel", role: .cancel) { store.closingTerminal = nil }
        } message: { Text("The process in this terminal will be stopped. Save any editor changes first.") }
    }
}

private struct TerminalTabTitle: View {
    @ObservedObject var tab: TerminalTab
    var body: some View { Text(tab.label) }
}

struct ProjectSidebar: View {
    let store: AppStore
    let switchProject: () -> Void
    let searchChats: () -> Void
    let hideSidebar: (() -> Void)?
    let didNavigate: () -> Void
    @StateObject private var observation: SidebarObservation
    init(store: AppStore, switchProject: @escaping () -> Void, searchChats: @escaping () -> Void = {},
         hideSidebar: (() -> Void)? = nil, didNavigate: @escaping () -> Void) {
        self.store = store; self.switchProject = switchProject; self.searchChats = searchChats
        self.hideSidebar = hideSidebar; self.didNavigate = didNavigate
        _observation = StateObject(wrappedValue: SidebarObservation(store))
    }
    var body: some View {
        ProjectSidebarContent(store: store, switchProject: switchProject, searchChats: searchChats, hideSidebar: hideSidebar, didNavigate: didNavigate,
                              presentation: observation.presentation).equatable()
    }
}

@MainActor private final class SidebarObservation: ObservableObject {
    @Published private(set) var presentation: SidebarPresentation
    private weak var store: AppStore?
    private var subscription: AnyCancellable?
    private var updateScheduled = false
    private var previews = SidebarPreviewCache()
    init(_ store: AppStore) {
        // Phase-one initialization cannot pass a stored property inout.
        var cache = SidebarPreviewCache()
        self.store = store; presentation = SidebarPresentation(store, previews: &cache); previews = cache
        subscription = store.objectWillChange.sink { [weak self] in self?.scheduleUpdate() }
    }
    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        // objectWillChange arrives before mutation. Capture the settled values
        // once per UI cycle, and never publish from a native layout callback.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            guard let store = self.store else { return }
            let next = SidebarPresentation(store, previews: &self.previews)
            if self.presentation != next { self.presentation = next }
        }
    }
}

/// Previews keyed by message: a settled message is reduced once, not on every publication.
struct SidebarPreviewCache {
    private var entries: [UUID: (source: String, preview: String?)] = [:]
    /// Working threads show typing dots instead, so streamed text never reaches the sidebar.
    mutating func previews(_ threads: [WorkspaceThread], running: Set<UUID>) -> [UUID: String] {
        var next: [UUID: (source: String, preview: String?)] = [:], result: [UUID: String] = [:]
        for thread in threads where !running.contains(thread.id) {
            guard let message = thread.messages.last(where: { ($0.role == .assistant || $0.role == .user) && !$0.text.isEmpty }) else { continue }
            // Unchanged text shares its storage, so the comparison is immediate.
            let preview = entries[message.id].flatMap { $0.source == message.text ? $0.preview : nil } ?? ThreadPreview.text(thread)
            next[message.id] = (message.text, preview)
            result[thread.id] = preview
        }
        entries = next
        return result
    }
}

/// Capture values before the next archive publication. Comparing the live store
/// itself would compare the same reference and miss navigation/status changes.
private struct SidebarPresentation: Equatable {
    struct Thread: Equatable {
        let id: UUID
        let title: String
        let pinned: Bool
        let unread: Bool
        let hasMessages: Bool
        let activityDate: Date
        let recentAt: Date
    }
    struct Project: Equatable {
        let id: UUID
        let name: String
        let root: String
        let pinned: Bool
        let collapsed: Bool
        let chats: Bool
        let threads: [Thread]
    }
    let projects: [Project]
    let selectedProject: UUID?
    let selectedThread: UUID?
    let projectsCollapsed: Bool
    let recentCollapsed: Bool
    let terminalVisible: Bool
    let terminalTabs: [UUID: Int]
    let running: Set<UUID>
    let previews: [UUID: String]
    let edit: UUID?
    let threadLimits: [UUID: Int]

    @MainActor init(_ store: AppStore, previews cache: inout SidebarPreviewCache) {
        projects = store.archive.projects.map { project in
            Project(id: project.id, name: project.name, root: project.rootPath, pinned: project.isPinned,
                    collapsed: project.isCollapsed, chats: project.isChatCollection,
                    threads: project.threads.map { thread in
                        Thread(id: thread.id, title: thread.title, pinned: thread.isPinned,
                               unread: thread.hasUnreadCompletion, hasMessages: !thread.messages.isEmpty,
                               activityDate: ThreadHoverDetails.activityDate(thread), recentAt: thread.recentAt)
                    })
        }
        selectedProject = store.archive.selectedProjectID; selectedThread = store.archive.selectedThreadID
        projectsCollapsed = store.archive.projectsSectionCollapsed == true
        recentCollapsed = store.archive.recentSectionCollapsed == true
        terminalVisible = store.showingTerminal
        terminalTabs = store.terminal.tabs.reduce(into: [:]) { $0[$1.projectID, default: 0] += 1 }
        running = store.running; edit = store.sidebarEdit?.id; threadLimits = store.sidebarThreadLimits
        previews = cache.previews(store.archive.projects.flatMap(\.threads), running: store.running)
    }
}

/// Long thread lists start short and grow by a page at a time. The selected and running
/// threads always stay listed, so navigation and working status are never hidden.
enum SidebarThreadLimit {
    static let initial = 5, page = 10
    static func visible(_ threads: [WorkspaceThread], limit: Int, keeping keep: (UUID) -> Bool) -> (threads: [WorkspaceThread], hidden: Int) {
        guard threads.count > limit else { return (threads, 0) }
        let shown = threads.enumerated().filter { $0.offset < limit || keep($0.element.id) }.map(\.element)
        return (shown, threads.count - shown.count)
    }
}

/// One listed conversation and the project that owns it.
private struct SidebarEntry: Identifiable {
    let thread: WorkspaceThread
    let project: WorkspaceProject
    var id: UUID { thread.id }
}

private struct ProjectSidebarContent: View, Equatable {
    let store: AppStore
    let switchProject: () -> Void
    let searchChats: () -> Void
    let hideSidebar: (() -> Void)?
    let didNavigate: () -> Void
    let presentation: SidebarPresentation
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.store === rhs.store && lhs.presentation == rhs.presentation
    }
    @Environment(\.octoTheme) private var theme
    @State private var renaming: SidebarTarget?
    @State private var removing: SidebarTarget?
    @State private var name = ""
    @State private var showingUsage = false

    var body: some View {
        floatingList
            .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        .onChange(of: store.sidebarEdit?.id) { _, _ in
            guard let edit = store.sidebarEdit else { return }
            let target = SidebarTarget(projectID: edit.projectID, threadID: edit.threadID)
            if edit.kind == .rename {
                let project = store.archive.projects.first { $0.id == edit.projectID }
                name = edit.threadID.flatMap { id in project?.threads.first { $0.id == id }?.title } ?? project?.name ?? ""
                renaming = target
            } else { removing = target }
            store.sidebarEdit = nil
        }
        .alert("Rename \(renaming?.threadID == nil ? "project" : "thread")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $name)
            Button("Save") {
                if let target = renaming {
                    if let id = target.threadID { store.renameThread(id, title: name) }
                    else { store.renameProject(target.projectID, name: name) }
                }
                renaming = nil
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert(removing?.threadID == nil ? "Remove project from Octo?" : "Delete thread?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(removing?.threadID == nil ? "Remove Project" : "Delete Thread", role: .destructive) {
                if let target = removing {
                    if let id = target.threadID { store.deleteThread(id, projectID: target.projectID) }
                    else { store.removeProject(target.projectID) }
                }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text(removing?.threadID == nil ? "This removes the project and its saved conversations from Octo. Files on disk are kept. Stop agents and close this project's terminal tabs first." : "This permanently deletes the saved conversation and its draft from Octo. Files on disk and CLI history are kept.")
        }
    }
    /// As in Messages, the list scrolls beneath the search field and the footer controls.
    private var floatingList: some View {
        list.floatingBar(.top) { searchBar }.floatingBar(.bottom) { footer }
    }
    /// The traffic-light row and search field share one floating bar, so the top of the card
    /// has a single backdrop; the traffic lights sit in the row's leading space (see WindowChrome).
    private var searchBar: some View {
        VStack(spacing: 0) {
            if let hideSidebar {
                HStack {
                    Spacer()
                    // Trailing edge in line with the search field's (12 pt in), centred on the traffic lights.
                    CornerButton(systemImage: "sidebar.left", action: hideSidebar)
                        .shortcutHint("sidebar").help("Hide sidebar (⌘B)").accessibilityLabel("Hide sidebar")
                }.padding(.trailing, 12).padding(.top, 4).frame(height: 32, alignment: .top)
            }
            SidebarSearchField(action: searchChats).padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 6)
        }
    }
    /// The scrolling sections; the search field and footer float over its edges.
    @ViewBuilder private var list: some View {
    let recentThreads = store.archive.recentThreads
    let pinned = pinnedEntries
    ScrollView {
            // A handful of section blocks: laziness saved nothing here but made every
            // expand/collapse re-estimate the stack before laying it out.
            VStack(alignment: .leading, spacing: 10) {
                if !pinned.isEmpty { pinnedStrip(pinned) }
                if let chats = store.archive.chats {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 2) {
                            sectionHeader("Chats", collapsed: chats.isCollapsed,
                                          unread: chats.threads.filter(\.hasUnreadCompletion).count,
                                          toggle: { store.toggleProjectCollapse(chats.id) })
                            Button { didNavigate(); store.newChat() } label: {
                                Image(systemName: "plus").frame(width: 26, height: 28)
                            }.buttonStyle(HoverButtonStyle(padded: false))
                                .shortcutHint("newThread", active: store.project?.isChatCollection == true)
                                .help("New chat").accessibilityLabel("New chat")
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            let window = threadWindow(chats)
                            rows(window.threads.map { SidebarEntry(thread: $0, project: chats) })
                            threadLimitControls(chats, hidden: window.hidden)
                            if chats.threads.isEmpty {
                                Button { didNavigate(); store.newChat() } label: {
                                    Label("Start a chat", systemImage: "bubble.left")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(HoverButtonStyle()).font(.system(size: 13))
                            }
                        }.padding(.top, 2).modifier(SidebarDisclosure(expanded: !chats.isCollapsed))
                    }
                }
                HStack(spacing: 2) {
                    sectionHeader("Projects", collapsed: store.archive.projectsSectionCollapsed == true,
                                  unread: unreadCount, toggle: store.toggleProjectsSection)
                    Button(action: switchProject) { Image(systemName: "magnifyingglass").frame(width: 26, height: 28) }
                        .buttonStyle(HoverButtonStyle(padded: false)).shortcutHint("projects", placement: .leading).help("Switch Project (⇧⌘K)")
                        .accessibilityLabel("Switch Project")
                    Button { store.chooseProject() } label: { Image(systemName: "plus").frame(width: 26, height: 28) }
                        .buttonStyle(HoverButtonStyle(padded: false)).shortcutHint("addProject").help("Add Project")
                        .accessibilityLabel("Add Project")
                }
                if store.archive.projectsSectionCollapsed != true {
                    projectRows
                    if store.archive.orderedProjects.isEmpty {
                        Text("Add a project to work with your code.")
                            .font(.system(size: 12)).foregroundStyle(theme.secondary).padding(8)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    sectionHeader("Recent", collapsed: store.archive.recentSectionCollapsed == true,
                                  unread: recentThreads.filter { $0.thread.hasUnreadCompletion }.count, toggle: store.toggleRecentSection)
                    if store.archive.recentSectionCollapsed != true {
                        if recentThreads.isEmpty {
                            Text("Your conversations will appear here.")
                                .font(.system(size: 12)).foregroundStyle(theme.secondary).padding(8)
                        }
                        rows(recentThreads.map { SidebarEntry(thread: $0.thread, project: $0.project) }, showsProjectName: true)
                    }
                }
            }.padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 10)
        }
    }
    /// Settings and Account Usage float on glass over the bottom of the list.
    private var footer: some View {
        HStack(spacing: 8) {
            SettingsLink {
                Label("Settings", systemImage: "gearshape").padding(.horizontal, 12).frame(minHeight: 30).contentShape(Capsule())
            }.buttonStyle(.plain).glassControl()
                .shortcutHint("settings", placement: .inline).help("Settings (⌘,)")
            Spacer(minLength: 0)
            Button { showingUsage.toggle() } label: {
                Image(systemName: "chart.bar.xaxis").frame(width: 30, height: 30).contentShape(Circle())
            }.buttonStyle(.plain).glassControl()
                .help("Account usage limits").accessibilityLabel("Account usage limits")
                .popover(isPresented: $showingUsage, arrowEdge: .top) {
                    AccountUsagePopover(store: store) { showingUsage = false }
                }
        }
        .font(.system(size: 13)).foregroundStyle(theme.secondary).padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 12)
    }
    private var selectedThreadID: UUID? { store.showingTerminal ? nil : store.archive.selectedThreadID }
    private func threadWindow(_ project: WorkspaceProject) -> (threads: [WorkspaceThread], hidden: Int) {
        store.sidebarThreads(project, keeping: store.showingTerminal ? nil : store.archive.selectedThreadID)
    }
    /// Pinned threads also stay in their project; the strip is a shortcut, as pinned conversations are in Messages.
    private var pinnedEntries: [SidebarEntry] {
        ([store.archive.chats].compactMap { $0 } + store.archive.orderedProjects).flatMap { project in
            project.orderedThreads.filter(\.isPinned).map { SidebarEntry(thread: $0, project: project) }
        }
    }
    /// Rows separated by inset hairlines, hidden beside the selected row as in Messages.
    @ViewBuilder private func rows(_ entries: [SidebarEntry], showsProjectName: Bool = false) -> some View {
        let selected = selectedThreadID
        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            SidebarThreadRow(thread: entry.thread, projectID: entry.project.id, projectName: entry.project.isChatCollection ? "Chats" : entry.project.name,
                             showsProjectName: showsProjectName, preview: presentation.previews[entry.id],
                             running: store.running.contains(entry.id), selected: selected == entry.id,
                             select: { didNavigate(); store.selectThread(entry.thread, project: entry.project) },
                             togglePin: { store.toggleThreadPin(entry.id) }).equatable()
                .contextMenu { threadMenu(entry.thread, project: entry.project) }
            if index < entries.count - 1 {
                SidebarSeparator(hidden: selected == entry.id || selected == entries[index + 1].id)
            }
        }
    }
    private func pinnedStrip(_ entries: [SidebarEntry]) -> some View {
        let columns = 3
        return VStack(spacing: 6) {
            ForEach(0..<((entries.count + columns - 1) / columns), id: \.self) { row in
                let slice = entries[(row * columns)..<min(entries.count, (row + 1) * columns)]
                HStack(alignment: .top, spacing: 4) {
                    ForEach(slice) { pinnedItem($0) }
                    ForEach(0..<(columns - slice.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
            }
        }.padding(.horizontal, 4).padding(.top, 4)
    }
    private func pinnedItem(_ entry: SidebarEntry) -> some View {
        let thread = entry.thread, selected = selectedThreadID == entry.id, running = store.running.contains(entry.id)
        return Button { didNavigate(); store.selectThread(thread, project: entry.project) } label: {
            VStack(spacing: 6) {
                ThreadAvatar(harness: thread.harness, size: 48, running: running)
                    .overlay(Circle().strokeBorder(theme.rowSelection, lineWidth: 2.5).padding(-4).opacity(selected ? 1 : 0))
                    .overlay(alignment: .topLeading) {
                        if thread.hasUnreadCompletion { Circle().fill(theme.blue).frame(width: 10, height: 10).offset(x: -3, y: -1) }
                    }
                Text(thread.title).font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .lineLimit(2).multilineTextAlignment(.center)
                    .foregroundStyle(selected ? theme.onRowSelection : theme.secondary)
                    .padding(.horizontal, selected ? 6 : 0).padding(.vertical, 1)
                    .background(selected ? theme.rowSelection : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                // Pins mix projects, so each names its own.
                Text(entry.project.isChatCollection ? "Chats" : entry.project.name).font(.system(size: 10.5))
                    .foregroundStyle(theme.subtle).lineLimit(1).truncationMode(.middle).padding(.top, -3)
            }.frame(maxWidth: .infinity).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(HoverButtonStyle(padded: false))
            .contextMenu { threadMenu(thread, project: entry.project) }
            .help(thread.title)
            .accessibilityLabel("Pinned, \(thread.title), \(entry.project.isChatCollection ? "Chats" : entry.project.name)")
            .accessibilityValue(running ? "Working" : thread.hasUnreadCompletion ? "Finished, unread" : "Read")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    @ViewBuilder private func threadLimitControls(_ project: WorkspaceProject, hidden: Int) -> some View {
        let limit = store.sidebarThreadLimits[project.id] ?? SidebarThreadLimit.initial
        if hidden > 0 || limit > SidebarThreadLimit.initial {
            HStack(spacing: 2) {
                if hidden > 0 {
                    Button { store.sidebarThreadLimits[project.id] = limit + SidebarThreadLimit.page } label: {
                        Text("Show more").padding(.horizontal, 10).frame(minHeight: 28).contentShape(Rectangle())
                    }.buttonStyle(HoverButtonStyle(padded: false))
                        .help("Show \(min(hidden, SidebarThreadLimit.page)) more of \(hidden) hidden")
                        .accessibilityLabel("Show more threads in \(project.name)")
                }
                if limit > SidebarThreadLimit.initial {
                    Button { store.sidebarThreadLimits[project.id] = nil } label: {
                        Text("Show less").padding(.horizontal, 10).frame(minHeight: 28).contentShape(Rectangle())
                    }.buttonStyle(HoverButtonStyle(padded: false))
                        .accessibilityLabel("Show fewer threads in \(project.name)")
                }
                Spacer(minLength: 0)
            }.font(.system(size: 12)).foregroundStyle(theme.secondary).padding(.leading, 56)
        }
    }
    private var unreadCount: Int { store.archive.orderedProjects.reduce(0) { $0 + $1.threads.filter(\.hasUnreadCompletion).count } }

    private func sectionHeader(_ title: String, collapsed: Bool, unread: Int, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 10).accessibilityHidden(true)
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if collapsed && unread > 0 {
                    Text("\(unread)").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.accent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(theme.accent.opacity(0.12), in: Capsule())
                }
            }.foregroundStyle(theme.secondary).padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 28).contentShape(Rectangle())
        }.buttonStyle(HoverButtonStyle(padded: false))
            .accessibilityLabel("\(collapsed ? "Expand" : "Collapse") \(title) section")
            .accessibilityValue((collapsed ? "Collapsed" : "Expanded") + (unread > 0 ? ", \(unread) finished unread" : ""))
    }

    private var projectRows: some View {
        ForEach(store.archive.orderedProjects) { project in
            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    Button { store.toggleProjectCollapse(project.id) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: project.isCollapsed ? "chevron.right" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.subtle).frame(width: 10)
                                .accessibilityHidden(true)
                            ProjectFolderIcon(isOpen: !project.isCollapsed)
                                .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                                .foregroundStyle(theme.secondary).frame(width: 18, height: 18)
                                .accessibilityHidden(true)
                            Text(project.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            let unread = project.threads.filter(\.hasUnreadCompletion).count
                            if unread > 0 {
                                Text("\(unread)").font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(theme.accent).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(theme.accent.opacity(0.12), in: Capsule())
                                    .help("\(unread) completed, unread \(unread == 1 ? "thread" : "threads")")
                            }
                            if project.isPinned { Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(theme.secondary) }
                        }.font(.system(size: 13.5, weight: .semibold)).padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(HoverButtonStyle(padded: false, selected: store.project?.id == project.id && project.isCollapsed)).help(project.rootPath)
                        .accessibilityLabel("\(project.isCollapsed ? "Expand" : "Collapse") \(project.name)")
                        .accessibilityValue(project.isCollapsed ? "Collapsed" : "Expanded")
                    Button { didNavigate(); store.newThread(projectID: project.id) } label: {
                        Image(systemName: "plus").frame(width: 26, height: 32)
                    }.buttonStyle(HoverButtonStyle(padded: false)).shortcutHint("newThread", active: store.project?.id == project.id).help("New thread in \(project.name)")
                        .accessibilityLabel("New thread in \(project.name)")
                }.contextMenu { projectMenu(project) }
                VStack(spacing: 0) {
                    let window = threadWindow(project)
                    rows(window.threads.map { SidebarEntry(thread: $0, project: project) })
                    threadLimitControls(project, hidden: window.hidden)
                    let terminalSelected = store.project?.id == project.id && store.showingTerminal
                    if !window.threads.isEmpty {
                        SidebarSeparator(hidden: terminalSelected || window.threads.last?.id == selectedThreadID)
                    }
                    terminalRow(project, selected: terminalSelected)
                }.padding(.top, 2).modifier(SidebarDisclosure(expanded: !project.isCollapsed))
            }
        }
    }
    private func terminalRow(_ project: WorkspaceProject, selected: Bool) -> some View {
        let tabs = presentation.terminalTabs[project.id] ?? 0
        let secondary = selected ? theme.onRowSelection.opacity(0.8) : theme.secondary
        return Button { didNavigate(); store.openTerminal(project) } label: {
            HStack(spacing: 8) {
                Color.clear.frame(width: 10, height: 8)
                Image(systemName: "terminal").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(secondary).frame(width: 36, height: 36)
                    .background(selected ? theme.onRowSelection.opacity(0.18) : theme.field, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Terminal").font(.system(size: 14, weight: .medium)).foregroundStyle(selected ? theme.onRowSelection : theme.foreground)
                    Text(tabs == 0 ? "Shell at the project root" : "\(tabs) open \(tabs == 1 ? "tab" : "tabs")")
                        .font(.system(size: 13)).foregroundStyle(secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }.padding(.leading, 2).padding(.trailing, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(HoverButtonStyle(padded: false))
            .background(selected ? theme.rowSelection : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityLabel("Terminal").accessibilityValue(tabs == 0 ? "No open tabs" : "\(tabs) open")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }


    @ViewBuilder private func projectMenu(_ project: WorkspaceProject) -> some View {
        Button("New Thread") { store.newThread(projectID: project.id) }
        Button("Open Terminal") { store.openTerminal(project) }
        Divider()
        Button(project.isPinned ? "Unpin Project" : "Pin Project") { store.toggleProjectPin(project.id) }
        Button(project.isCollapsed ? "Expand Project" : "Collapse Project") { store.toggleProjectCollapse(project.id) }
        Button("Rename…") { name = project.name; renaming = SidebarTarget(projectID: project.id) }
        Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.rootPath) }
        Divider()
        Button("Add Project…") { store.chooseProject() }
        Button("Remove Project…", role: .destructive) { removing = SidebarTarget(projectID: project.id) }
            .disabled(project.threads.contains { store.running.contains($0.id) } || store.terminal.tabs.contains { $0.projectID == project.id })
    }
    @ViewBuilder private func threadMenu(_ thread: WorkspaceThread, project: WorkspaceProject) -> some View {
        Button(thread.isPinned ? "Unpin Thread" : "Pin Thread") { store.toggleThreadPin(thread.id) }
        Button("Rename…") { name = thread.title; renaming = SidebarTarget(projectID: project.id, threadID: thread.id) }
        Button(project.isChatCollection ? "New Chat" : "New Thread in Project") { store.newThread(projectID: project.id) }
        Divider()
        Button("Delete Thread…", role: .destructive) { removing = SidebarTarget(projectID: project.id, threadID: thread.id) }
            .disabled(store.running.contains(thread.id))
    }
}

/// Animation stays in Core Animation; it never drives SwiftUI layout on every frame.
private struct HoverScrollingTitle: NSViewRepresentable {
    let title: String
    let hovering: Bool
    let weight: Font.Weight
    /// Text drawn on a selection fill; the theme's text colour otherwise.
    var color: NSColor?
    @Environment(\.octoTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    func makeNSView(context: Context) -> MarqueeTitleView { MarqueeTitleView() }
    func updateNSView(_ view: MarqueeTitleView, context: Context) {
        view.update(title: title, emphasized: weight == .semibold, color: color ?? theme.textColor,
                    animate: hovering && !reduceMotion && phase == .active)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarqueeTitleView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.textWidth, height: 18)
    }
    static func dismantleNSView(_ view: MarqueeTitleView, coordinator: ()) { view.stopAnimation() }
}

final class MarqueeTitleView: NSView {
    // Own the text layer directly: translating an NSTextField's backing layer can
    // slide its AppKit-clipped backing contents out of view instead of revealing text.
    private let textLayer = CATextLayer()
    private var title = "", emphasized = false, animate = false
    private var renderedSize: CGSize?
    private(set) var textWidth: CGFloat = 0
    var isAnimating: Bool { textLayer.animation(forKey: "marquee") != nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.masksToBounds = true
        textLayer.isWrapped = false
        layer?.addSublayer(textLayer)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func update(title: String, emphasized: Bool, color: NSColor, animate: Bool) {
        let displayed = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let changed = self.title != displayed || self.emphasized != emphasized || self.animate != animate
        let font = NSFont.systemFont(ofSize: 14, weight: emphasized ? .semibold : .regular)
        let text = NSAttributedString(string: displayed, attributes: [.font: font, .foregroundColor: color])
        if !(textLayer.string as? NSAttributedString == text) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            textLayer.font = font
            textLayer.fontSize = font.pointSize
            textLayer.foregroundColor = color.cgColor
            textLayer.string = text
            CATransaction.commit()
        }
        guard changed else { return }
        self.title = displayed; self.emphasized = emphasized; self.animate = animate
        textWidth = ceil(text.size().width) + 2
        renderedSize = nil; needsLayout = true
    }
    override func layout() {
        super.layout()
        guard renderedSize != bounds.size else { return }
        renderedSize = bounds.size
        textLayer.removeAnimation(forKey: "marquee")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.transform = CATransform3DIdentity
        let overflow = max(0, textWidth - bounds.width)
        let moving = animate && overflow > 1 && window != nil
        textLayer.contentsScale = window?.backingScaleFactor ?? 2
        textLayer.truncationMode = moving ? .none : .end
        textLayer.frame = NSRect(x: 0, y: max(0, (bounds.height - 18) / 2), width: moving ? textWidth : bounds.width, height: 18)
        textLayer.transform = CATransform3DMakeTranslation(moving ? -overflow : 0, 0, 0)
        CATransaction.commit()
        guard moving else { return }
        let travel = Double(overflow) / 30, duration = 1 + travel
        // Keep the final position in the model layer after the one-shot animation ends.
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, 0, -overflow]
        animation.keyTimes = [0, NSNumber(value: 1 / duration), 1]
        animation.duration = duration
        textLayer.add(animation, forKey: "marquee")
    }
    func stopAnimation() {
        textLayer.removeAnimation(forKey: "marquee")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.transform = CATransform3DIdentity
        CATransaction.commit()
        animate = false; renderedSize = nil; needsLayout = true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopAnimation() }
        else { renderedSize = nil; needsLayout = true }
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        textLayer.contentsScale = window?.backingScaleFactor ?? 2
    }
}

/// Compares only what it displays, so expanding a project or changing selection
/// does not re-render every other row. Actions resolve the thread by ID.
private struct SidebarThreadRow: View, Equatable {
    let thread: WorkspaceThread
    let projectID: UUID
    let projectName: String
    var showsProjectName = false
    let preview: String?
    let running: Bool
    let selected: Bool
    let select: () -> Void
    let togglePin: () -> Void
    @Environment(\.octoTheme) private var theme
    /// Driven by the row's native tracking area, the row's only hover source.
    @State private var hovering = false
    private var showsPin: Bool { hovering }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.thread.id == rhs.thread.id && lhs.thread.title == rhs.thread.title && lhs.thread.isPinned == rhs.thread.isPinned
            && lhs.thread.harness == rhs.thread.harness
            && lhs.thread.hasUnreadCompletion == rhs.thread.hasUnreadCompletion
            && ThreadHoverDetails.activityDate(lhs.thread) == ThreadHoverDetails.activityDate(rhs.thread)
            && lhs.projectID == rhs.projectID && lhs.projectName == rhs.projectName && lhs.showsProjectName == rhs.showsProjectName
            && lhs.preview == rhs.preview && lhs.running == rhs.running && lhs.selected == rhs.selected
    }

    var body: some View {
        let secondary = selected ? theme.onRowSelectionColor.withAlphaComponent(0.8) : theme.secondaryColor
        ZStack(alignment: .topTrailing) {
            Button(action: select) {
                HStack(spacing: 8) {
                    Circle().fill(thread.hasUnreadCompletion ? (selected ? theme.onRowSelection : theme.blue) : .clear)
                        .frame(width: 8, height: 8).frame(width: 10)
                    ThreadAvatar(harness: thread.harness, size: 36, running: running, outline: selected ? theme.rowSelection : nil)
                        .help(thread.harness.title)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            HoverScrollingTitle(title: thread.title, hovering: hovering, weight: .semibold,
                                                color: selected ? theme.onRowSelectionColor : nil)
                            Text(ThreadHoverDetails.timestamp(ThreadHoverDetails.activityDate(thread), now: Date()))
                                .font(.system(size: 12).monospacedDigit()).foregroundStyle(Color(nsColor: secondary))
                                .lineLimit(1).fixedSize().opacity(showsPin ? 0 : 1)
                        }
                        subtitle(secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.leading, 2).padding(.trailing, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(SidebarRowButtonStyle(hovering: hovering && !selected))
                .accessibilityLabel(thread.title + ", " + projectName)
                .accessibilityHint("Last activity " + ThreadHoverDetails.activityDate(thread).formatted())
                .accessibilityValue(running ? "Working" : thread.hasUnreadCompletion ? "Finished, unread" : "Read")
                .accessibilityAddTraits(selected ? .isSelected : [])
            Button(action: togglePin) { SidebarPinLabel(pinned: thread.isPinned, visible: showsPin, onSelection: selected) }
                .buttonStyle(HoverButtonStyle(padded: false))
                .allowsHitTesting(showsPin)
                .help(thread.isPinned ? "Unpin thread" : "Pin thread")
                .accessibilityLabel("\(thread.isPinned ? "Unpin" : "Pin") \(thread.title)")
                .padding(.trailing, 4).padding(.top, 3)
        }.background(selected ? theme.rowSelection : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .background(ThreadHoverAnchor(thread: thread, projectName: projectName, theme: theme, onHover: { hovering = $0 }))
    }
    /// Messages' last-message line; a working thread shows typing dots instead of streamed text.
    /// Where rows from several projects mix, the line leads with the project, even while working.
    @ViewBuilder private func subtitle(_ color: NSColor) -> some View {
        Group {
            if running {
                HStack(spacing: 6) {
                    TypingIndicator(color: color)
                    if showsProjectName { Text("\(Text(projectName).fontWeight(.medium)) · Working") } else { Text("Working") }
                }
            } else if showsProjectName {
                Text("\(Text(projectName).fontWeight(.medium)) · \(preview ?? "No messages yet")")
            } else {
                Text(preview ?? "No messages yet")
            }
        }.font(.system(size: 13)).foregroundStyle(Color(nsColor: color)).lineLimit(1).truncationMode(.tail)
    }
}

/// An inset hairline aligned with the row text, after Messages.
private struct SidebarSeparator: View {
    let hidden: Bool
    @Environment(\.octoTheme) private var theme
    var body: some View {
        Rectangle().fill(theme.hairline).frame(height: 0.5)
            .padding(.leading, 56).padding(.trailing, 12)
            .opacity(hidden ? 0 : 1).accessibilityHidden(true)
    }
}

/// Collapsed rows stay mounted: building a project's rows (context menus, hover
/// tracking, native titles) dominated expand/collapse. Toggling only changes geometry.
private struct SidebarDisclosure: ViewModifier {
    let expanded: Bool
    func body(content: Content) -> some View {
        content
            .frame(height: expanded ? nil : 0, alignment: .top).clipped()
            .opacity(expanded ? 1 : 0)
            .allowsHitTesting(expanded).accessibilityHidden(!expanded)
            // Keeps hidden controls out of keyboard focus.
            .disabled(!expanded)
    }
}

/// The row highlight follows the native hover anchor instead of adding another tracking region.
private struct SidebarRowButtonStyle: ButtonStyle {
    let hovering: Bool
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return configuration.label
            .contentShape(shape)
            .background(Color.primary.opacity(hovering || configuration.isPressed ? 0.06 : 0), in: shape)
    }
}

/// Reads the button's own focus, so keyboard users still see the pin without a
/// per-row FocusState binding.
private struct SidebarPinLabel: View {
    let pinned: Bool
    let visible: Bool
    var onSelection = false
    @Environment(\.isFocused) private var focused
    @Environment(\.octoTheme) private var theme
    var body: some View {
        Image(systemName: pinned ? "pin.fill" : "pin")
            .font(.system(size: 12))
            .foregroundStyle(onSelection ? theme.onRowSelection : pinned ? theme.accent : theme.secondary)
            .frame(width: 28, height: 30)
            .opacity(visible || focused ? 1 : 0)
    }
}

enum ThreadHoverDetails {
    static func activityDate(_ thread: WorkspaceThread) -> Date {
        max(thread.createdAt, thread.lastActivityAt ?? .distantPast,
            thread.messages.last.map { $0.completedAt ?? $0.createdAt } ?? .distantPast)
    }
    /// Messages' list timestamp: the time today, "Yesterday", the weekday within a week, else the date.
    static func timestamp(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let day = calendar.startOfDay(for: date), today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        switch days {
        case 0: style = style.hour().minute()
        case 1: return "Yesterday"
        case 2..<7: style = style.weekday(.wide)
        default: style = style.year(.twoDigits).month(.defaultDigits).day(.defaultDigits)
        }
        return date.formatted(style)
    }
    static func age(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        if seconds < 31_536_000 { return "\(Int(seconds / 86_400))d" }
        return "\(Int(seconds / 31_536_000))y"
    }
}

struct ThreadHoverContent: Equatable {
    let title: String
    let projectName: String
    let activityDate: Date
    let theme: AppTheme
}

/// Native labels avoid a second SwiftUI graph feeding layout/hover invalidations
/// back into the sidebar. Only display metadata crosses this boundary.
final class ThreadHoverCardView: NSView {
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let ageLabel = NSTextField(labelWithString: "")
    private let projectLabel = NSTextField(labelWithString: "")
    private let folder = NSImageView()
    init(content: ThreadHoverContent, now: Date = Date()) {
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 12; layer?.borderWidth = 1
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        ageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        projectLabel.font = .systemFont(ofSize: 13); projectLabel.lineBreakMode = .byTruncatingTail
        folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Project")
        [titleLabel, ageLabel, projectLabel, folder].forEach(addSubview)
        update(content, now: now)
    }
    required init?(coder: NSCoder) { nil }
    func update(_ content: ThreadHoverContent, now: Date = Date()) {
        titleLabel.stringValue = content.title
        ageLabel.stringValue = ThreadHoverDetails.age(since: content.activityDate, now: now)
        projectLabel.stringValue = content.projectName
        let theme = content.theme
        titleLabel.textColor = theme.textColor
        let secondary = theme.palette.map { NSColor(themeHex: $0.secondary) } ?? .secondaryLabelColor
        ageLabel.textColor = secondary; projectLabel.textColor = secondary; folder.contentTintColor = secondary
        layer?.backgroundColor = (theme.palette.map { NSColor(themeHex: $0.base) } ?? .windowBackgroundColor).cgColor
        layer?.borderColor = (theme.palette.map { NSColor(themeHex: $0.overlay0).withAlphaComponent(0.5) } ?? .separatorColor).cgColor
        let ageWidth = ceil(ageLabel.fittingSize.width), titleWidth = 320 - 24 - 14 - ageWidth
        let titleHeight = max(18, ceil(titleLabel.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: titleWidth, height: 10_000)).height))
        frame.size = NSSize(width: 320, height: titleHeight + 50)
        titleLabel.frame = NSRect(x: 12, y: 38, width: titleWidth, height: titleHeight)
        ageLabel.frame = NSRect(x: 308 - ageWidth, y: frame.height - 29, width: ageWidth, height: 17)
        folder.frame = NSRect(x: 12, y: 12, width: 16, height: 17)
        projectLabel.frame = NSRect(x: 36, y: 12, width: 272, height: 17)
    }
}

private struct ThreadHoverAnchor: NSViewRepresentable {
    let thread: WorkspaceThread
    let projectName: String
    let theme: AppTheme
    let onHover: (Bool) -> Void
    func makeNSView(context: Context) -> ThreadHoverAnchorView { ThreadHoverAnchorView() }
    func updateNSView(_ view: ThreadHoverAnchorView, context: Context) {
        view.onHover = onHover
        view.update(content: .init(title: thread.title, projectName: projectName,
                                   activityDate: ThreadHoverDetails.activityDate(thread), theme: theme))
    }
    static func dismantleNSView(_ view: ThreadHoverAnchorView, coordinator: ()) { view.dismiss() }
}

/// Rows scroll beneath a still pointer, which delivers enter/exit for every row
/// passed. Hover is ignored until scrolling settles; the next mouse move restores it.
@MainActor enum SidebarScrollActivity {
    static let quietPeriod: TimeInterval = 0.2
    private static var lastScroll: TimeInterval = 0
    private static var monitor: Any?
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in recordScroll(); return event }
    }
    static func recordScroll() { lastScroll = ProcessInfo.processInfo.systemUptime }
    static var isScrolling: Bool { ProcessInfo.processInfo.systemUptime - lastScroll < quietPeriod }
}

final class ThreadHoverAnchorView: NSView {
    /// Like a tooltip: passing over rows must not create a window for each one.
    static let cardDelay: TimeInterval = 0.45
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var hoverRevision = 0
    private(set) var panel: NSPanel?
    private var content: ThreadHoverContent?
    private var eventMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { dismiss() } else { SidebarScrollActivity.install() }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // inVisibleRect follows geometry automatically. Replacing this area on every
        // layout synthesizes exit/enter events and can feed back into SwiftUI layout.
        guard tracking == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { if !SidebarScrollActivity.isScrolling { setHovered(true) } }
    override func mouseMoved(with event: NSEvent) { if !SidebarScrollActivity.isScrolling { setHovered(true) } }
    override func mouseExited(with event: NSEvent) { dismiss() }
    func update(content: ThreadHoverContent) {
        guard self.content != content else { return }
        self.content = content
        if let card = panel?.contentView as? ThreadHoverCardView {
            card.update(content); panel?.setContentSize(card.frame.size)
        }
    }
    func setHovered(_ hovering: Bool) {
        guard hovering != hovered else { return }
        dismiss()
        guard hovering else { return }
        hovered = true; publishHover()
        observeDismissal()
    }
    private func publishHover() {
        hoverRevision += 1
        let revision = hoverRevision
        // Tracking callbacks can run during native layout. Never mutate SwiftUI state
        // synchronously from them, and drop queued transitions superseded by an exit.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.hoverRevision == revision else { return }
            self.onHover?(self.hovered)
            guard self.hovered else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.cardDelay) { [weak self] in
                guard let self, self.hoverRevision == revision else { return }
                self.present()
            }
        }
    }
    private func present() {
        guard panel == nil, hovered, let content, let window, window.isKeyWindow, !visibleRect.isEmpty,
              let screen = window.screen else { return }
        let card = ThreadHoverCardView(content: content)
        let size = card.frame.size
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let x = min(max(visible.minX, anchor.maxX + 8), visible.maxX - size.width)
        let y = min(max(visible.minY, anchor.midY - size.height / 2), visible.maxY - size.height)
        let panel = NSPanel(contentRect: NSRect(origin: NSPoint(x: x, y: y), size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = true
        panel.contentView = card; self.panel = panel
        window.addChildWindow(panel, ordered: .above); panel.orderFront(nil)
    }
    private func observeDismissal() {
        guard let window else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            self?.dismiss(); return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            self?.dismiss()
        }
    }
    func dismiss() {
        if hovered { hovered = false; publishHover() }
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
        // Clear ownership before closing, since AppKit can deliver callbacks while closing.
        if let old = panel { panel = nil; old.parent?.removeChildWindow(old); old.orderOut(nil); old.close() }
    }
}

/// Native outline artwork with an angled front flap when the project is expanded.
private struct ProjectFolderIcon: Shape {
    var isOpen: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 3, y: 19))
        path.addLine(to: CGPoint(x: 3, y: 6))
        path.addQuadCurve(to: CGPoint(x: 5, y: 4), control: CGPoint(x: 3, y: 4))
        path.addLine(to: CGPoint(x: 9, y: 4))
        path.addLine(to: CGPoint(x: 12, y: 7))
        path.addLine(to: CGPoint(x: 19, y: 7))
        path.addQuadCurve(to: CGPoint(x: 21, y: 9), control: CGPoint(x: 21, y: 7))
        path.addLine(to: CGPoint(x: 21, y: isOpen ? 11 : 18))
        if isOpen {
            path.move(to: CGPoint(x: 3, y: 19))
            path.addLine(to: CGPoint(x: 7, y: 11))
            path.addLine(to: CGPoint(x: 23, y: 11))
            path.addLine(to: CGPoint(x: 19, y: 20))
        } else {
            path.addQuadCurve(to: CGPoint(x: 19, y: 20), control: CGPoint(x: 21, y: 20))
        }
        path.addLine(to: CGPoint(x: 5, y: 20))
        path.addQuadCurve(to: CGPoint(x: 3, y: 19), control: CGPoint(x: 3, y: 20))
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

private struct SidebarTarget {
    var projectID: UUID
    var threadID: UUID?
}

struct HoverButtonStyle: ButtonStyle {
    var padded = true
    var selected = false
    /// Menus drawn with this style lose the native indicator; this draws it after the label.
    var chevron = false
    func makeBody(configuration: Configuration) -> some View {
        HoverButton(configuration: configuration, padded: padded, selected: selected, chevron: chevron)
    }
    private struct HoverButton: View {
        @Environment(\.octoTheme) private var theme
        let configuration: ButtonStyle.Configuration
        let padded: Bool
        let selected: Bool
        let chevron: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            HStack(spacing: 4) {
                configuration.label
                if chevron { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(theme.secondary) }
            }
                .padding(.horizontal, padded ? 8 : 0).padding(.vertical, padded ? 6 : 0)
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .background(selected ? theme.selection.opacity(enabled && (hovering || configuration.isPressed) ? 1.2 : 1) : Color.primary.opacity(enabled && (hovering || configuration.isPressed) ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(enabled && hovering ? 0.08 : 0)))
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovering = $0 }
        }
    }
}

/// Adds a visible hover state without replacing native menu, picker or list behavior.
private struct HoverFeedback: ViewModifier {
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View {
        content
            .padding(4)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(enabled && hovering ? 0.08 : 0))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(enabled && hovering ? 0.14 : 0)))
                    .allowsHitTesting(false)
            }
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverFeedback() -> some View { modifier(HoverFeedback()) }
    /// Draws a menu as a hover button so its whole highlighted box opens it. A borderless-button
    /// menu takes clicks only on its label; padding or hover feedback around it is not clickable.
    func hoverMenuStyle(padded: Bool = true, chevron: Bool = false) -> some View {
        menuStyle(.button).buttonStyle(HoverButtonStyle(padded: padded, chevron: chevron)).menuIndicator(.hidden)
    }
}

/// Geometry is independent of child ideal sizes so a hidden pane never sets the window minimum.
struct WorkspaceLayout {
    let width: CGFloat
    let sidebarWidth: CGFloat
    let sidebarOpen: Bool
    let compactSidebarOpen: Bool
    var compact: Bool { width < 800 }
    var sidebarVisible: Bool { compact ? compactSidebarOpen : sidebarOpen }
    var overlayVisible: Bool { compact && compactSidebarOpen }
    var detailOffset: CGFloat { !compact && sidebarOpen ? sidebarWidth + 7 : 0 }
    var detailWidth: CGFloat { max(0, width - detailOffset) }
}

/// SwiftUI's nested NSSplitViews can retain oversized children during window resizing.
/// Clamp both columns to the available width on every layout pass, including while dragging.
struct ResizableColumns<Leading: View, Trailing: View>: View {
    @Environment(\.octoTheme) private var theme
    var minLeading: CGFloat
    var maxLeading: CGFloat = .greatestFiniteMagnitude
    var minTrailing: CGFloat
    var initialFraction: CGFloat
    var trailingVisible = true
    var singleColumnWhenNarrow = false
    /// When false, the trailing column fills the width and the leading column stays mounted offscreen.
    var leadingVisible = true
    /// Beside a floating card the divider is drawn only while hovered or dragged.
    var showsIdleDivider = true
    /// Stacks the leading pane above the trailing one at this height, capped at 45% of the total so
    /// the trailing pane keeps the larger share. Both stay mounted while switching between modes.
    var stackedLeadingHeight: CGFloat?
    /// Paints the trailing pane so it covers the leading one when a narrow layout overlaps them.
    var opaqueTrailing = true
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing
    @State private var fraction: CGFloat?
    @State private var dragStart: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let available = max(0, geometry.size.width - 7)
            let upper = min(maxLeading, max(0, available - minTrailing))
            let lower = min(minLeading, upper)
            let width = min(upper, max(lower, available * (fraction ?? initialFraction)))
            let single = singleColumnWhenNarrow && available < minLeading + minTrailing
            let stackHeight = trailingVisible ? stackedLeadingHeight.map { max(0, min($0, geometry.size.height * 0.45)) } : nil
            let stacked = stackHeight != nil
            let split = trailingVisible && leadingVisible && !single && !stacked
            let showsLeading = stacked || leadingVisible && (!trailingVisible || !single)
            ZStack(alignment: .topLeading) {
                leading().frame(height: stackHeight ?? geometry.size.height)
                    .modifier(PanelFrame(width: split ? width : geometry.size.width))
                    .opacity(showsLeading ? 1 : 0).allowsHitTesting(showsLeading).accessibilityHidden(!showsLeading)
                ResizeHandle(enabled: split, color: showsIdleDivider ? NSColor(theme.border) : .clear, activeColor: NSColor(theme.activeBorder), onDrag: { translation in
                    if dragStart == nil { dragStart = width }
                    let next = min(upper, max(lower, (dragStart ?? width) + translation))
                    fraction = next / max(1, available)
                }, onEnd: { dragStart = nil })
                    .frame(width: 7).offset(x: width)
                    .opacity(split ? 1 : 0).accessibilityHidden(!split)
                    .accessibilityLabel("Resize panels")
                    .accessibilityValue("\(Int(width)) points")
                    .accessibilityAdjustableAction { direction in
                        let next = min(upper, max(lower, width + (direction == .increment ? 20 : -20)))
                        fraction = next / max(1, available)
                    }
                trailing().frame(height: geometry.size.height - (stackHeight ?? 0)).background(opaqueTrailing ? theme.background : .clear)
                    .modifier(PanelFrame(width: single || stacked || !leadingVisible ? geometry.size.width : max(0, available - width),
                                         x: trailingVisible ? (split ? width + 7 : 0) : geometry.size.width, y: stackHeight ?? 0))
                    .allowsHitTesting(trailingVisible).accessibilityHidden(!trailingVisible)
            }
            // Offsets don't contribute to ZStack's measured width. The clip
            // must cover both columns, not just the wider individual child.
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            .clipped()
        }
    }
}

/// Apply the destination geometry immediately while keeping native descendants mounted.
struct PanelFrame: ViewModifier {
    var width: CGFloat
    var x: CGFloat = 0
    var y: CGFloat = 0
    func body(content: Content) -> some View {
        content.frame(width: width).clipped().offset(x: x, y: y)
    }
}

extension WorkspaceView {
    private func requestFileAction(_ kind: FileAction.Kind, path: String) {
        guard let project = store.project, store.isProjectChat else { return }
        let root = store.thread?.workingDirectory ?? project.rootPath
        guard path.isEmpty || review.represents(projectID: project.id, root: root) else { return }
        NativeWorkspaceFocus.clear()
        fileAction = FileAction(kind: kind, projectID: project.id, root: root, path: path)
    }
    private func finishPalette() {
        let action = paletteAction
        paletteAction = nil
        // Let the native sheet finish restoring its responder before navigating.
        DispatchQueue.main.async {
            if let action { action() } else { restoreFocus() }
        }
    }
    private func restoreFocus() {
        if store.showingTerminal, let project = store.project { store.terminal.focusSelected(projectID: project.id) }
        else if singleReview { reviewFocus += 1 }
        else { store.composerFocus += 1 }
    }
    /// Changes the project's panel tabs, reveals the panel and shows the selected tab's review content.
    private func showPanel(focus: Bool = false, _ change: (inout PanelTabs) -> Void) {
        guard store.isProjectChat, let project = store.project else { return }
        store.showingTerminal = false; store.showingReview = true
        store.updatePanelTabs(project.id, change)
        syncReview(focus: focus)
    }
    private func syncReview(focus: Bool = false) {
        guard let project = store.project, store.isProjectChat else { return }
        let tabs = project.panelTabs, root = store.thread?.workingDirectory ?? project.rootPath
        Task {
            await review.show(tabs, projectID: project.id, root: root)
            if focus, let path = tabs.selectedFile, review.selectedPath == path, review.represents(projectID: project.id, root: root) { reviewFocus += 1 }
        }
    }
    private func openBrowserTab(isPrivate: Bool = false) {
        guard store.isProjectChat, let project = store.project else { return }
        store.showingTerminal = false; store.showingReview = true
        store.openBrowserTab(projectID: project.id, isPrivate: isPrivate)
    }
    private func showBrowser() {
        guard let project = store.project else { return }
        if let id = project.panelTabs.recentBrowser { showPanel { $0.select(.browser(id)) } } else { openBrowserTab() }
    }
    private func closePanelTab(_ tab: PanelTab) {
        guard let project = store.project else { return }
        store.closePanelTab(tab, projectID: project.id)
        if store.project?.panelTabs.selected == nil { focusSurfacePicker() } else { syncReview() }
    }
    private func editSidebar(_ kind: SidebarEdit.Kind, thread: Bool) {
        guard let project = store.project else { return }
        showSidebar()
        store.sidebarEdit = SidebarEdit(projectID: project.id, threadID: thread ? store.thread?.id : nil, kind: kind)
    }
    private var commands: [AppCommand] {
        let project = store.project, thread = store.thread
        let hasProject = store.isProjectChat, hasThread = thread != nil
        let idle = thread.map { !store.running.contains($0.id) } ?? false
        var result: [AppCommand] = [
            .init(id: "newThread", title: "New Thread", group: "Create", key: "n") { store.newThread() },
            .init(id: "newChat", title: "New Chat Without a Project", group: "Create") { store.newChat() },
            .init(id: "openChats", title: "Go to Chats", group: "Navigate") { store.openChats() },
            .init(id: "addProject", title: "Add Project…", group: "Create", key: "o", modifiers: [.command, .shift]) { store.chooseProject() },
            .init(id: "chats", title: "Search Chats…", group: "Navigate", key: "k") { NativeWorkspaceFocus.clear(); palette = .chats },
            .init(id: "projects", title: "Switch Project…", group: "Navigate", key: "k", modifiers: [.command, .shift]) { NativeWorkspaceFocus.clear(); palette = .projects },
            .init(id: "commands", title: "Command Palette…", group: "Navigate", key: "p", modifiers: [.command, .shift]) { NativeWorkspaceFocus.clear(); palette = .commands },
            .init(id: "files", title: "Find File…", group: "Navigate", key: "p", enabled: hasProject) { NativeWorkspaceFocus.clear(); palette = .files },
            .init(id: "previousThread", title: "Previous Thread", group: "Navigate", key: "[", modifiers: [.command, .option], enabled: hasThread) { store.cycleThread(-1) },
            .init(id: "nextThread", title: "Next Thread", group: "Navigate", key: "]", modifiers: [.command, .option], enabled: hasThread) { store.cycleThread(1) },
            .init(id: "sidebar", title: "Toggle Left Sidebar", group: "Panels", key: "b", action: toggleSidebar),
            .init(id: "review", title: "Toggle Review Panel", group: "Panels", key: "b", modifiers: [.command, .option], enabled: hasProject) { store.showingTerminal = false; store.showingReview.toggle() },
            .init(id: "composer", title: "Focus Thread / Composer", group: "Panels", key: "1", enabled: hasThread) { store.focusComposer() },
            .init(id: "changes", title: "Show Changes", group: "Panels", key: "2", enabled: hasProject) { showPanel { $0.showChanges() } },
            .init(id: "browseFiles", title: "Show Files", group: "Panels", key: "3", enabled: hasProject) { showPanel { $0.showFiles() } },
            .init(id: "browser", title: "Show Browser", group: "Panels", key: "5", enabled: hasProject) { showBrowser() },
            .init(id: "newBrowserTab", title: "New Browser Tab", group: "Panels", enabled: hasProject) { openBrowserTab() },
            .init(id: "newPrivateBrowserTab", title: "New Private Browser Tab", group: "Panels", enabled: hasProject) { openBrowserTab(isPrivate: true) },
            .init(id: "previousPanelTab", title: "Previous Panel Tab", group: "Panels", key: "[", modifiers: [.command, .shift], enabled: hasProject && store.showingReview, terminalAllowed: false) { showPanel { $0.selectAdjacent(-1) } },
            .init(id: "nextPanelTab", title: "Next Panel Tab", group: "Panels", key: "]", modifiers: [.command, .shift], enabled: hasProject && store.showingReview, terminalAllowed: false) { showPanel { $0.selectAdjacent(1) } },
            .init(id: "usageDashboard", title: "Usage Dashboard", group: "Panels") { openWindow(id: UsageDashboardWindow.id) },
            .init(id: "terminal", title: "Toggle Project Terminal", group: "Panels", key: "j", enabled: hasProject) {
                if store.showingTerminal { store.focusComposer() } else if let project { store.openTerminal(project) }
            },
            .init(id: "find", title: "Find in Current Thread", group: "Conversation", key: "f", enabled: hasThread) {
                compactSidebarOpen = false
                if layout.detailWidth < 737 { store.showingReview = false }
                store.showingTerminal = false; store.findingThread = true; store.findFocus += 1; NativeWorkspaceFocus.focus("OctoThreadFind")
            },
            .init(id: "findNext", title: "Next Matching Message", group: "Conversation", key: "g", enabled: store.findingThread, terminalAllowed: false) { store.findStep += 1 },
            .init(id: "findPrevious", title: "Previous Matching Message", group: "Conversation", key: "g", modifiers: [.command, .shift], enabled: store.findingThread, terminalAllowed: false) { store.findStep -= 1 },
            .init(id: "send", title: idle ? "Send Message" : "Queue Message", group: "Conversation", key: "\r", enabled: thread.map { store.canSend($0) } ?? false, terminalAllowed: false) { store.send() },
            .init(id: "stop", title: "Stop Agent", group: "Conversation", key: ".", enabled: !idle && hasThread, terminalAllowed: false) { if let thread { store.stop(thread.id) } },
            .init(id: "refresh", title: "Refresh Changes and Files", group: "Review", key: "r", modifiers: [.command, .shift], enabled: hasProject) { Task { await refresh() } },
            .init(id: "newFile", title: "New File…", group: "Review", enabled: hasProject) { requestFileAction(.create, path: "") },
            .init(id: "saveFile", title: "Save File", group: "Review", key: "s", enabled: hasProject && review.browsingFiles && review.editor != nil && store.showingReview && !review.loadingSnapshot, terminalAllowed: false) {
                if let editor = review.editor { Task { await editor.save() } }
            },
            .init(id: "deleteFile", title: "Delete File…", group: "Review", enabled: hasProject && review.browsingFiles && review.selectedPath != nil && !review.loadingSnapshot) {
                if let path = review.selectedPath { requestFileAction(.delete, path: path) }
            },
            .init(id: "focusReview", title: "Focus Code Preview", group: "Review", key: "4", enabled: hasProject && review.snapshot != nil && !review.loadingSnapshot) {
                compactSidebarOpen = false
                store.showingTerminal = false; store.showingReview = true
                DispatchQueue.main.async { reviewFocus += 1 }
            },
            .init(id: "attach", title: "Attach Selected Code to Draft", group: "Review", key: "a", modifiers: [.command, .shift], enabled: hasProject && review.selection != nil && !review.loadingSnapshot && store.showingReview, terminalAllowed: false) {
                if let selection = review.selection { store.attach(selection); store.focusComposer() }
            },
            .init(id: "editor", title: "Open Selected File in LazyVim", group: "Review", key: "e", modifiers: [.command, .shift], enabled: hasProject && review.snapshot?.notice == nil && review.snapshot != nil && !review.loadingSnapshot) {
                if let snapshot = review.snapshot { store.openInEditor(snapshot, selection: review.selection) }
            },
            .init(id: "scope", title: "Toggle Working / Staged Changes", group: "Review", enabled: hasProject && !review.browsingFiles) { review.scope = review.scope == .working ? .staged : .working },
            .init(id: "newTerminal", title: "New Terminal Tab", group: "Terminal", key: "t", enabled: hasProject) {
                if let project { store.terminal.newTab(projectID: project.id, directory: project.rootPath); store.showingTerminal = true }
            },
            .init(id: "closeTerminal", title: "Close Terminal Tab…", group: "Terminal", key: "w", enabled: store.showingTerminal && project.flatMap { store.terminal.selectedTabs[$0.id] } != nil, terminalRequired: true) {
                if let project { store.closingTerminal = store.terminal.selectedTabs[project.id] }
            },
            .init(id: "previousTab", title: "Previous Terminal Tab", group: "Terminal", key: "[", modifiers: [.command, .shift], enabled: store.showingTerminal, terminalRequired: true) { if let project { store.terminal.cycle(projectID: project.id, offset: -1) } },
            .init(id: "nextTab", title: "Next Terminal Tab", group: "Terminal", key: "]", modifiers: [.command, .shift], enabled: store.showingTerminal, terminalRequired: true) { if let project { store.terminal.cycle(projectID: project.id, offset: 1) } },
            .init(id: "settings", title: "Settings…", group: "App", key: ",") { openSettings() },
            .init(id: "pinThread", title: thread?.isPinned == true ? "Unpin Thread" : "Pin Thread", group: "Thread", enabled: hasThread) { if let thread { store.toggleThreadPin(thread.id) } },
            .init(id: "renameThread", title: "Rename Thread…", group: "Thread", enabled: hasThread) { editSidebar(.rename, thread: true) },
            .init(id: "deleteThread", title: "Delete Thread…", group: "Thread", enabled: hasThread && idle) { editSidebar(.remove, thread: true) },
            .init(id: "pinProject", title: project?.isPinned == true ? "Unpin Project" : "Pin Project", group: "Project", enabled: hasProject) { if let project { store.toggleProjectPin(project.id) } },
            .init(id: "collapseProject", title: project?.isCollapsed == true ? "Expand Project" : "Collapse Project", group: "Project", enabled: hasProject) { if let project { showSidebar(); store.toggleProjectCollapse(project.id) } },
            .init(id: "renameProject", title: "Rename Project…", group: "Project", enabled: hasProject) { editSidebar(.rename, thread: false) },
            .init(id: "revealProject", title: "Reveal Project in Finder", group: "Project", enabled: hasProject) { if let project { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.rootPath) } },
            .init(id: "removeProject", title: "Remove Project…", group: "Project", enabled: hasProject && (project.map { p in !p.threads.contains { store.running.contains($0.id) } && !store.terminal.tabs.contains { $0.projectID == p.id } } ?? false)) { editSidebar(.remove, thread: false) }
        ]
        // Only listed while a closable tab is showing, so ⌘W otherwise keeps its window behavior.
        if hasProject, store.showingReview, let project, let tab = project.panelTabs.selected {
            result.append(.init(id: "closePanelTab", title: "Close Panel Tab", group: "Panels", key: "w", terminalAllowed: false) { closePanelTab(tab) })
        }
        if hasProject, let project, let id = project.panelTabs.selectedBrowser, store.showingReview {
            let session = store.browserSession(id, projectID: project.id)
            result.append(.init(id: "hardReload", title: "Hard Reload Browser Page", group: "Panels", enabled: session.currentURL != nil) { session.hardReload() })
            result.append(.init(id: "webInspector", title: "Open Web Inspector", group: "Panels", enabled: session.currentURL != nil && session.canOpenDevTools) { session.openDevTools() })
        }
        for project in store.archive.orderedProjects {
            result.append(.init(id: "project-\(project.id)", title: "Switch to Project: \(project.name)", group: "Project") { store.selectProject(project) })
        }
        if let thread {
            for descriptor in store.harnessDescriptors {
                result.append(.init(id: "provider-\(descriptor.id)", title: "Provider: \(descriptor.id.title)", group: "Agent", enabled: idle) { store.changeHarness(descriptor.id) })
            }
            if store.supportsModels(thread.harness) {
                for model in store.modelCatalogs[store.modelKey(thread)] ?? [] {
                    result.append(.init(id: "model-\(model.id)", title: "Model: \(model.displayName)", group: "Agent", enabled: idle) { store.selectModel(model) })
                    if model.model == thread.agentSettings.model {
                        for effort in model.supportedReasoningEfforts {
                            result.append(.init(id: "effort-\(effort.id)", title: "Reasoning: \(effort.title)", group: "Agent", enabled: idle) { store.selectReasoning(effort.reasoningEffort) })
                        }
                    }
                }
                result.append(.init(id: "refreshModels", title: "Refresh Models", group: "Agent", enabled: !store.loadingModels.contains(store.modelKey(thread))) { Task { await store.loadModels(directory: thread.workingDirectory, harness: thread.harness, refresh: true) } })
            }
            for approval in store.approvals[thread.id] ?? [] {
                result.append(.init(id: "approval-\(approval.id)", title: "Review Approval: \(approval.title)", group: "Agent") {
                    store.showingTerminal = false
                    let alert = NSAlert()
                    alert.messageText = approval.title; alert.informativeText = approval.detail
                    alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Decline"); alert.addButton(withTitle: "Allow Once")
                    let response = alert.runModal()
                    guard store.approvals[thread.id]?.contains(where: { $0.id == approval.id }) == true else { return }
                    if response == .alertSecondButtonReturn { store.answer(approval, threadID: thread.id, allow: false) }
                    else if response == .alertThirdButtonReturn { store.answer(approval, threadID: thread.id, allow: true) }
                })
            }
            for attachment in store.attachments[thread.id] ?? [] {
                result.append(.init(id: "removeCode-\(attachment.id)", title: "Remove Code Attachment: \(attachment.label)", group: "Draft") { store.attachments[thread.id]?.removeAll { $0.id == attachment.id } })
            }
            for annotation in store.browserAnnotations[thread.id] ?? [] {
                result.append(.init(id: "removeAnnotation-\(annotation.id)", title: "Remove Browser Annotation: \(annotation.label)", group: "Draft") { store.browserAnnotations[thread.id]?.removeAll { $0.id == annotation.id } })
            }
            for image in store.draftImages[thread.id] ?? [] {
                result.append(.init(id: "removeImage-\(image.id)", title: "Remove Screenshot: \(image.name)", group: "Draft") { store.draftImages[thread.id]?.removeAll { $0.id == image.id } })
            }
        }
        return result
    }
    private func paletteEntries(_ mode: PaletteMode) -> [PaletteEntry] {
        switch mode {
        case .projects:
            return store.archive.orderedProjects.map { project in
                PaletteEntry(id: project.id.uuidString, title: project.name, detail: project.rootPath,
                             shortcut: project.id == store.project?.id ? "Current" : "") { store.selectProject(project) }
            }
        case .commands: return commands.map { item in
            PaletteEntry(id: item.id, title: item.title, detail: item.group, shortcut: item.shortcut, enabled: item.enabled, action: item.action)
        }
        case .chats:
            return store.archive.searchableThreads.map { entry in
                let project = entry.project, thread = entry.thread
                return PaletteEntry(id: thread.id.uuidString, title: thread.title, detail: project.name,
                             searchText: thread.messages.map(\.text).joined(separator: "\n")) { store.selectThread(thread, project: project) }
            }
        case .files:
            guard let project = store.project, store.isProjectChat else { return [] }
            func leaves(_ nodes: [FileNode]) -> [String] { nodes.flatMap { $0.children.map(leaves) ?? [$0.id] } }
            return leaves(review.tree).map { path in
                PaletteEntry(id: path, title: path, detail: project.name) {
                    showPanel(focus: true) { $0.openFile(path, pinned: true) }
                }
            }
        }
    }
}

/// Shown when every panel tab is closed. Its letter keys work while it has focus.
private struct SurfacePicker: View {
    var changeCount: Int
    var focusRequest: Int
    var openBrowser: (_ isPrivate: Bool) -> Void
    var openFiles: () -> Void
    var openChanges: () -> Void
    @Environment(\.octoTheme) private var theme
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 18) {
            Text("Open a surface").font(.system(size: 15, weight: .medium))
            VStack(spacing: 2) {
                row("Browser", icon: "globe", key: "B") { openBrowser(false) } accessory: {
                    Menu {
                        Button("Browser") { openBrowser(false) }
                        Button("Private Browser") { openBrowser(true) }
                    } label: { Image(systemName: "chevron.down").font(.system(size: 11)) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("Browser or private browser").accessibilityLabel("Browser options")
                }
                row("Files", icon: "doc.on.doc", key: "F", action: openFiles) { EmptyView() }
                row("Changes", icon: "plus.forwardslash.minus", key: "C", action: openChanges) {
                    Text("\(changeCount)").font(.system(size: 12).monospacedDigit()).foregroundStyle(theme.secondary)
                }
            }.frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
            switch press.characters.lowercased() {
            case "b": openBrowser(press.modifiers.contains(.shift)); return .handled
            case "f": openFiles(); return .handled
            case "c": openChanges(); return .handled
            default: return .ignored
            }
        }
        .onChange(of: focusRequest) { _, _ in focused = true }
    }
    private func row<Accessory: View>(_ title: String, icon: String, key: String, action: @escaping () -> Void, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 10) {
            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: icon).frame(width: 20)
                    Text(title)
                    Spacer(minLength: 8)
                }.font(.system(size: 14)).frame(minHeight: 34).padding(.leading, 10).contentShape(Rectangle())
            }.buttonStyle(HoverButtonStyle(padded: false))
            accessory()
            Text(key).font(.system(size: 12, weight: .medium).monospaced()).foregroundStyle(theme.secondary)
                .frame(width: 24, height: 22).background(theme.surface, in: RoundedRectangle(cornerRadius: 5))
                .help("Press \(key) while this panel is focused").accessibilityHidden(true)
        }.padding(.trailing, 6)
    }
}

private struct PanelBrowserTabTitle: View {
    @ObservedObject var session: BrowserSession
    var body: some View {
        Image(systemName: session.isPrivate ? "eye.slash" : "globe").font(.system(size: 11))
        Text(!session.title.isEmpty ? session.title : session.currentURL?.host ?? (session.isPrivate ? "Private" : "New Tab"))
            .help(session.currentURL?.absoluteString ?? session.address)
    }
}

/// One tab on the review panel's segmented capsule; the close button appears for the selected or hovered tab.
private struct PanelTabChip<Label: View>: View {
    let selected: Bool
    let help: String
    let select: () -> Void
    /// Double-clicking a preview file tab keeps it open.
    let pin: (() -> Void)?
    let close: () -> Void
    @ViewBuilder let label: Label
    @Environment(\.octoTheme) private var theme
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 6) { label }
                    .font(.system(size: 12.5)).lineLimit(1).frame(maxWidth: 180, minHeight: 24)
                    .padding(.leading, 10).padding(.trailing, 2).contentShape(Capsule())
            }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture(count: 2).onEnded { pin?() })
                .help(help)
                .accessibilityAddTraits(selected ? .isSelected : [])
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 18, height: 24).contentShape(Rectangle())
            }
                .buttonStyle(.plain).foregroundStyle(theme.secondary)
                .opacity(selected || hovering ? 1 : 0).allowsHitTesting(selected || hovering)
                .padding(.trailing, 4)
                .shortcutHint("closePanelTab", active: selected).help("Close tab").accessibilityLabel("Close tab")
        }
        .foregroundStyle(selected ? theme.foreground : theme.secondary)
        .background {
            if selected { Capsule().fill(theme.background).shadow(color: .black.opacity(0.12), radius: 1.5, y: 1) }
            else if hovering { Capsule().fill(Color.primary.opacity(0.05)) }
        }
        .onHover { hovering = $0 }
    }
}

/// A changed file as a conversation-style row: status circle, name over folder, and line counts.
private struct ChangedFileRow: View {
    let file: ChangedFile
    let lines: DiffStat.Lines?
    @Environment(\.octoTheme) private var theme
    @Environment(\.backgroundProminence) private var prominence
    var body: some View {
        // The focused list draws its selection in the accent colour.
        let onSelection = prominence == .increased
        let status = self.status
        let name = (file.path as NSString).lastPathComponent, folder = (file.path as NSString).deletingLastPathComponent
        HStack(spacing: 9) {
            Text(status.letter).font(.system(size: 10.5, weight: .bold)).foregroundStyle(onSelection ? .white : status.color)
                .frame(width: 24, height: 24).background((onSelection ? Color.white : status.color).opacity(0.2), in: Circle())
                .help(status.label)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                if !folder.isEmpty {
                    Text(folder).font(.system(size: 11)).foregroundStyle(onSelection ? Color.white.opacity(0.8) : theme.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
            if let lines {
                HStack(spacing: 5) {
                    Text("+\(lines.additions)").foregroundStyle(onSelection ? .white : theme.green)
                    Text("−\(lines.deletions)").foregroundStyle(onSelection ? .white : theme.red)
                }.font(.system(size: 11).monospacedDigit())
                    .accessibilityLabel("\(lines.additions) lines added, \(lines.deletions) removed")
            }
        }.frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
    }
    private var status: (letter: String, label: String, color: Color) {
        if file.isUntracked { return ("U", "Untracked", theme.green) }
        if file.indexStatus == "D" || file.worktreeStatus == "D" { return ("D", "Deleted", theme.red) }
        if file.hasStaged { return ("S", "Staged", theme.blue) }
        return ("M", "Modified", theme.yellow)
    }
}

/// Both lists flatten their rows for AppKit and diff them on every update. Built
/// inside WorkspaceView, they re-diffed the whole repository tree on every store
/// publication, even with the panel hidden. They now update only from ReviewModel.
private struct ReviewFileLists: View, Equatable {
    @ObservedObject var review: ReviewModel
    let projectID: UUID
    let action: (FileAction.Kind, String) -> Void
    let openFile: (_ path: String, _ pinned: Bool) -> Void
    let selectChange: (ChangedFile) -> Void
    @Environment(\.octoTheme) private var theme
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.review === rhs.review && lhs.projectID == rhs.projectID }
    var body: some View {
        ZStack {
            ScrollViewReader { proxy in
                List {
                    FileTreeRows(nodes: review.tree, review: review, action: action, select: openFile)
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
                    .onChange(of: review.revealRequest) { _, _ in
                        if let path = review.selectedPath { proxy.scrollTo(path, anchor: .center) }
                    }
            }.opacity(review.browsingFiles ? 1 : 0).allowsHitTesting(review.browsingFiles).accessibilityHidden(!review.browsingFiles)
            List(review.files, selection: Binding(get: { review.selectedPath }, set: { path in
                if let file = review.files.first(where: { $0.path == path }) { selectChange(file) }
            })) { file in
                ChangedFileRow(file: file, lines: review.diffStat?.files[file.path])
                    .listRowInsets(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 8))
                    .contentShape(Rectangle()).hoverFeedback().help(file.path).tag(file.path)
                    .contextMenu { if file.worktreeStatus != "D" && file.indexStatus != "D" { Button("Open File") { openFile(file.path, true) } } }
            }.listStyle(.plain).scrollContentBackground(.hidden)
                .opacity(review.browsingFiles ? 0 : 1).allowsHitTesting(!review.browsingFiles).accessibilityHidden(review.browsingFiles)
        }
    }
}

private struct FileTreeRows: View {
    let nodes: [FileNode]
    @ObservedObject var review: ReviewModel
    let action: (FileAction.Kind, String) -> Void
    /// A single click opens a replaceable preview tab; double-clicking or Open File keeps the tab.
    let select: (_ path: String, _ pinned: Bool) -> Void
    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                DisclosureGroup(isExpanded: Binding(get: { review.expandedFolders.contains(node.id) }, set: {
                    if $0 { review.expandedFolders.insert(node.id) } else { review.expandedFolders.remove(node.id) }
                })) {
                    FileTreeRows(nodes: children, review: review, action: action, select: select)
                } label: {
                    Label(node.name, systemImage: "folder").font(.system(size: 13)).lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .contentShape(Rectangle())
                        .contextMenu { Button("New File Here…") { action(.create, node.id + "/") } }
                }
            } else {
                Button { select(node.id, false) } label: {
                    Label(node.name, systemImage: "doc.text").font(.system(size: 13)).lineLimit(1)
                        .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(HoverButtonStyle(padded: false, selected: review.browsingFiles && review.selectedPath == node.id))
                    .simultaneousGesture(TapGesture(count: 2).onEnded { select(node.id, true) })
                    .help(node.id).id(node.id).listRowBackground(Color.clear)
                    .contextMenu {
                        Button("Open File") { select(node.id, true) }
                        Button("New File Here…") {
                            let folder = node.id.lastIndex(of: "/").map { String(node.id[...$0]) } ?? ""
                            action(.create, folder)
                        }
                        Divider()
                        Button("Delete File…", role: .destructive) { action(.delete, node.id) }
                    }
            }
        }
    }
}

/// The same native surface owns hit testing, cursor updates and dragging.
/// A non-hit-testing background cannot reliably override SwiftUI's cursor owner.
struct ResizeHandle: NSViewRepresentable {
    let enabled: Bool
    let color: NSColor
    let activeColor: NSColor
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void
    func makeNSView(context: Context) -> ResizeCursorView { ResizeCursorView() }
    func updateNSView(_ view: ResizeCursorView, context: Context) {
        view.enabled = enabled
        view.color = color
        view.activeColor = activeColor
        view.onDrag = onDrag
        view.onEnd = onEnd
        view.needsDisplay = true
    }
}

class ResizeCursorView: NSView {
    var color: NSColor = .separatorColor
    var activeColor: NSColor = .controlAccentColor
    var onDrag: (CGFloat) -> Void = { _ in }
    var onEnd: () -> Void = {}
    private var dragOrigin: CGFloat?
    private var hovered = false
    private var cursorTracking: NSTrackingArea?
    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            if !enabled { finishDrag(); hovered = false }
            discardCursorRects()
            window?.invalidateCursorRects(for: self)
            updateTrackingAreas()
        }
    }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { enabled ? super.hitTest(point) : nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if enabled && cursorTracking == nil {
            let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate], owner: self)
            addTrackingArea(area); cursorTracking = area
        } else if !enabled, let area = cursorTracking {
            removeTrackingArea(area); cursorTracking = nil
        }
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if enabled && !visibleRect.isEmpty { addCursorRect(visibleRect, cursor: .resizeLeftRight) }
    }
    override func cursorUpdate(with event: NSEvent) { if enabled { NSCursor.resizeLeftRight.set() } }
    override func mouseEntered(with event: NSEvent) {
        guard enabled else { return }
        hovered = true; needsDisplay = true; NSCursor.resizeLeftRight.set()
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false; needsDisplay = true
        if dragOrigin == nil { NSCursor.arrow.set() }
    }
    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        dragOrigin = event.locationInWindow.x
        NSCursor.resizeLeftRight.set(); onDrag(0); needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard enabled, let origin = dragOrigin else { return }
        NSCursor.resizeLeftRight.set(); onDrag(event.locationInWindow.x - origin)
    }
    override func mouseUp(with event: NSEvent) { finishDrag() }
    private func finishDrag() {
        guard dragOrigin != nil else { return }
        dragOrigin = nil; onEnd(); needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finishDrag() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func draw(_ dirtyRect: NSRect) {
        (hovered || dragOrigin != nil ? activeColor : color).setFill()
        NSRect(x: bounds.midX - 0.5, y: bounds.minY, width: 1, height: bounds.height).fill()
    }
}
