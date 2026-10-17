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
    @State private var sidebarWidth: CGFloat = 270
    @State private var sidebarDragStart: CGFloat?
    @State private var windowWidth: CGFloat = 1380
    @State private var palette: PaletteMode?
    @State private var paletteAction: (() -> Void)?
    @State private var fileAction: FileAction?
    @State private var reviewFocus = 0
    @State private var showingShortcutHints = false
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.octoTheme) private var theme
    @Environment(\.scenePhase) private var phase
    var body: some View {
        GeometryReader { geometry in
            let layout = layout(at: geometry.size.width)
            ZStack(alignment: .leading) {
                VStack(spacing: 0) {
                    titlebar(showSidebarToggle: !layout.sidebarVisible)
                    Divider()
                    GeometryReader { contentGeometry in
                        ZStack {
                            threadWorkspace.opacity(store.showingTerminal ? 0 : 1).allowsHitTesting(!store.showingTerminal).accessibilityHidden(store.showingTerminal)
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

                VStack(spacing: 0) {
                    HStack {
                        Text("Octo").font(.headline)
                        Spacer()
                        Button(action: toggleSidebar) { Image(systemName: "sidebar.left") }
                            .hoverFeedback().shortcutHint("sidebar").help("Hide sidebar (⌘B)").accessibilityLabel("Hide sidebar")
                    }.padding(12)
                    sidebar
                }
                .frame(width: layout.sidebarWidth, height: geometry.size.height).background(theme.panel).clipped()
                .offset(x: layout.sidebarVisible ? 0 : -layout.sidebarWidth - 7)
                .allowsHitTesting(layout.sidebarVisible).accessibilityHidden(!layout.sidebarVisible)

                ResizeHandle(enabled: layout.sidebarVisible && !layout.compact, color: NSColor(theme.border), activeColor: NSColor(theme.activeBorder), onDrag: { translation in
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
        .onChange(of: layout.compact) { _, _ in compactSidebarOpen = false }
        .onChange(of: singleReview) { _, visible in
            if visible { NativeWorkspaceFocus.clear() }
        }
        .onChange(of: store.composerFocus) { _, _ in
            compactSidebarOpen = false
            if layout.detailWidth < 737 { store.showingReview = false }
        }
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
                await review.fileDidChange(path, deleted: action.kind == .delete, projectID: action.projectID, root: action.root)
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
    private var singleReview: Bool { store.isProjectChat && layout.detailWidth < 737 && store.showingReview && !store.showingTerminal }
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
        Task { await review.reveal(link, projectID: project.id, root: root) }
    }
    private var sidebar: some View {
        ProjectSidebar(store: store, switchProject: { NativeWorkspaceFocus.clear(); palette = .projects }, didNavigate: { compactSidebarOpen = false })
    }
    private func titlebar(showSidebarToggle: Bool) -> some View {
        HStack {
            if showSidebarToggle {
                Button(action: toggleSidebar) { Image(systemName: "sidebar.left") }
                    .hoverFeedback().shortcutHint("sidebar").help("Show sidebar (⌘B)").accessibilityLabel("Show sidebar")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(store.showingTerminal ? "\(store.project?.name ?? "Octo") · Terminal" : store.thread?.title ?? "Welcome to Octo").font(.headline).lineLimit(1)
                Text(store.showingTerminal ? "Project terminal workspace" : store.project?.isChatCollection == true ? "Chats" : "\(store.project?.name ?? "Local development")  /  \(review.branch)").font(.system(size: 13)).foregroundStyle(theme.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if store.isProjectChat && !store.showingTerminal {
                Button { store.showingReview.toggle() } label: { Image(systemName: "sidebar.right") }
                    .hoverFeedback().shortcutHint("review")
                    .help(store.showingReview ? "Hide review panel" : "Show review panel")
                    .accessibilityLabel(store.showingReview ? "Hide review panel" : "Show review panel")

            }
            if store.showingTerminal { Button { store.focusComposer() } label: { Image(systemName: "bubble.left") }.hoverFeedback().shortcutHint("terminal").help("Back to thread").accessibilityLabel("Back to thread") }
            else if let project = store.project, store.isProjectChat { Button { store.openTerminal(project) } label: { Image(systemName: "terminal") }.hoverFeedback().shortcutHint("terminal").help("Terminal").accessibilityLabel("Terminal") }
        }.padding(.horizontal, 12).padding(.vertical, 13)
    }
    @ViewBuilder private var threadWorkspace: some View {
        if let project = store.project {
            ResizableColumns(minLeading: 300, minTrailing: 430, initialFraction: 0.42, trailingVisible: store.isProjectChat && store.showingReview, singleColumnWhenNarrow: true) {
                ChatPane(store: store, isVisible: !store.showingTerminal && !singleReview && !layout.overlayVisible && palette == nil && store.error == nil, openFile: openMarkdownFile)
            } trailing: {
                if !project.isChatCollection { reviewPane(project) }
            }
        } else {
            ContentUnavailableView {
                Label("A home for your projects", systemImage: "square.stack.3d.up")
            } description: { Text("Add a Git repository to start an agent thread, review changes, or open your terminal.") }
            actions: { Button("Add Project…") { store.chooseProject() }.buttonStyle(.borderedProminent).foregroundStyle(theme.onAccent) }
        }
    }
    private func reviewPane(_ project: WorkspaceProject) -> some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 3) {
                    Button { revealReview(files: false) } label: {
                        Text("Changes (\(review.files.count))").frame(maxWidth: .infinity, minHeight: 28)
                    }.buttonStyle(HoverButtonStyle(padded: false, selected: !review.browsingFiles && !store.showingBrowser))
                        .shortcutHint("changes")
                        .accessibilityAddTraits(!review.browsingFiles && !store.showingBrowser ? .isSelected : [])
                    Button { revealReview(files: true) } label: {
                        Text("Files").frame(maxWidth: .infinity, minHeight: 28)
                    }.buttonStyle(HoverButtonStyle(padded: false, selected: review.browsingFiles && !store.showingBrowser))
                        .shortcutHint("browseFiles")
                        .accessibilityAddTraits(review.browsingFiles && !store.showingBrowser ? .isSelected : [])
                    Button { revealBrowser() } label: {
                        Text("Browser").frame(maxWidth: .infinity, minHeight: 28)
                    }.buttonStyle(HoverButtonStyle(padded: false, selected: store.showingBrowser))
                        .shortcutHint("browser")
                        .accessibilityAddTraits(store.showingBrowser ? .isSelected : [])
                }.padding(3).background(theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: 330)
                Spacer()
                if !store.showingBrowser { reviewControls }
            }.padding(12)
            Divider()
            ZStack {
                reviewContent(project).opacity(store.showingBrowser ? 0 : 1).allowsHitTesting(!store.showingBrowser).accessibilityHidden(store.showingBrowser)
                // Mounted while hidden so the page, scroll position and dev-server session survive.
                BrowserPane(session: store.browserSession(for: project.id)) { store.attachBrowserScreenshot($0, projectID: project.id) }
                    .id(project.id)
                    .opacity(store.showingBrowser ? 1 : 0).allowsHitTesting(store.showingBrowser).accessibilityHidden(!store.showingBrowser)
            }
        }
    }
    @ViewBuilder private var reviewControls: some View {
        if !review.browsingFiles {
            Picker("Diff layout", selection: $review.diffLayout) {
                Text("Stacked").tag(DiffLayout.stacked)
                Text("Side by Side").tag(DiffLayout.sideBySide)
            }.labelsHidden().frame(width: 120).hoverFeedback().help("Diff layout")
        }
        ProgressView().controlSize(.small).opacity(review.loading || review.loadingSnapshot ? 1 : 0).accessibilityHidden(!review.loading && !review.loadingSnapshot)
        if review.browsingFiles {
            Button { requestFileAction(.create, path: "") } label: { Image(systemName: "doc.badge.plus") }
                .hoverFeedback().help("New file").accessibilityLabel("New file")
        }
        Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }.hoverFeedback().shortcutHint("refresh").help("Refresh changes")
    }
    private func reviewContent(_ project: WorkspaceProject) -> some View {
        VStack(spacing: 0) {
            if let error = review.error { Text(error).font(.system(size: 13)).foregroundStyle(theme.red).padding() }
                ResizableColumns(minLeading: 150, maxLeading: 260, minTrailing: 270, initialFraction: 0.3) {
                    ZStack {
                        ScrollViewReader { proxy in
                            List {
                                FileTreeRows(nodes: review.tree, review: review, action: requestFileAction) { path in
                                    let root = store.thread?.workingDirectory ?? project.rootPath
                                    Task {
                                        await review.selectPath(path, projectID: project.id, root: root)
                                        if review.browsingFiles && review.selectedPath == path && review.represents(projectID: project.id, root: root) { reviewFocus += 1 }
                                    }
                                }
                            }.listStyle(.sidebar).scrollContentBackground(.hidden)
                                .onChange(of: review.revealRequest) { _, _ in
                                    if let path = review.selectedPath { proxy.scrollTo(path, anchor: .center) }
                                }
                        }.opacity(review.browsingFiles ? 1 : 0).allowsHitTesting(review.browsingFiles).accessibilityHidden(!review.browsingFiles)
                    List(review.files, selection: Binding(get: { review.selectedPath }, set: { path in
                        if let file = review.files.first(where: { $0.path == path }) { Task { await review.select(file, projectID: project.id, root: store.thread?.workingDirectory ?? project.rootPath) } }
                    })) { file in
                        HStack { Image(systemName: "doc.text").foregroundStyle(theme.secondary); Text(file.path).font(.system(size: 13)).lineLimit(1).truncationMode(.middle); Spacer(minLength: 0); Text(file.isUntracked ? "U" : file.hasStaged ? "S" : "M").font(.system(size: 12, weight: .medium)).foregroundStyle(file.isUntracked ? theme.green : theme.secondary) }
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                            .contentShape(Rectangle()).hoverFeedback().help(file.path).tag(file.path)
                    }.listStyle(.plain).scrollContentBackground(.hidden)
                        .opacity(review.browsingFiles ? 0 : 1).allowsHitTesting(!review.browsingFiles).accessibilityHidden(review.browsingFiles)
                    }
                } trailing: {
                    VStack(spacing: 0) {
                        if let snapshot = review.snapshot {
                            HStack {
                                if review.browsingFiles { Text("File").font(.system(size: 13)).foregroundStyle(theme.secondary) }
                                else { Picker("Scope", selection: $review.scope) { Text("Working").tag(DiffScope.working); Text("Staged").tag(DiffScope.staged) }.labelsHidden().frame(width: 110).hoverFeedback() }
                                Spacer()
                                Button("Open in LazyVim") { store.openInEditor(snapshot, selection: review.selection) }.font(.system(size: 13)).hoverFeedback().shortcutHint("editor")
                            }.padding(9)
                            .onChange(of: review.scope) { _, _ in
                                if !review.browsingFiles, let file = review.files.first(where: { $0.path == review.selectedPath }) { Task { await review.select(file, projectID: project.id, root: store.thread?.workingDirectory ?? project.rootPath) } }
                            }
                            Divider()
                            if review.browsingFiles, let editor = review.editor {
                                InlineFilePane(session: editor, windowID: editorWindowID, theme: store.theme, focusRequest: reviewFocus,
                                    revealLine: review.revealLine, revealRequest: review.revealRequest,
                                    onSelection: { selection in
                                        if review.browsingFiles && review.editor === editor && !review.loadingSnapshot { review.selection = selection }
                                    }, onAskAgent: { if review.browsingFiles && review.editor === editor && !review.loadingSnapshot { attachToDraft($0) } })
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
                            Divider()
                            HStack {
                                Text(review.selection.map { $0.label } ?? "Hover a line and click + to attach code").font(.system(size: 12)).foregroundStyle(theme.secondary).lineLimit(1)
                                Spacer()
                                Button("Ask Agent") { if let selection = review.selection { attachToDraft(selection) } }.hoverFeedback().disabled(review.selection == nil).controlSize(.small).shortcutHint("attach")
                            }.padding(10)
                        } else { ContentUnavailableView(!review.browsingFiles && review.files.isEmpty ? "No changes" : "Choose a file", systemImage: !review.browsingFiles && review.files.isEmpty ? "checkmark.circle" : "doc.text.magnifyingglass") }
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
    let didNavigate: () -> Void
    @StateObject private var observation: SidebarObservation
    init(store: AppStore, switchProject: @escaping () -> Void, didNavigate: @escaping () -> Void) {
        self.store = store; self.switchProject = switchProject; self.didNavigate = didNavigate
        _observation = StateObject(wrappedValue: SidebarObservation(store))
    }
    var body: some View {
        ProjectSidebarContent(store: store, switchProject: switchProject, didNavigate: didNavigate,
                              presentation: observation.presentation).equatable()
    }
}

@MainActor private final class SidebarObservation: ObservableObject {
    @Published private(set) var presentation: SidebarPresentation
    private weak var store: AppStore?
    private var subscription: AnyCancellable?
    private var updateScheduled = false
    init(_ store: AppStore) {
        self.store = store; presentation = SidebarPresentation(store)
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
            let next = SidebarPresentation(store)
            if self.presentation != next { self.presentation = next }
        }
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
    let terminalProjects: Set<UUID>
    let running: Set<UUID>
    let edit: UUID?

    @MainActor init(_ store: AppStore) {
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
        terminalProjects = Set(store.terminal.tabs.map(\.projectID))
        running = store.running; edit = store.sidebarEdit?.id
    }
}

private struct ProjectSidebarContent: View, Equatable {
    let store: AppStore
    let switchProject: () -> Void
    let didNavigate: () -> Void
    let presentation: SidebarPresentation
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.store === rhs.store && lhs.presentation == rhs.presentation
    }
    @Environment(\.octoTheme) private var theme
    @State private var renaming: SidebarTarget?
    @State private var removing: SidebarTarget?
    @State private var name = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let chats = store.archive.chats {
                        VStack(alignment: .leading, spacing: 3) {
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
                            if !chats.isCollapsed {
                                ForEach(chats.orderedThreads) { thread in
                                    SidebarThreadRow(thread: thread, projectName: "Chats", running: store.running.contains(thread.id),
                                                     selected: store.archive.selectedThreadID == thread.id && !store.showingTerminal,
                                                     select: { didNavigate(); store.selectThread(thread, project: chats) },
                                                     togglePin: { store.toggleThreadPin(thread.id) })
                                        .contextMenu { threadMenu(thread, project: chats) }
                                }
                                if chats.threads.isEmpty {
                                    Button { didNavigate(); store.newChat() } label: {
                                        Label("Start a chat", systemImage: "bubble.left")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(HoverButtonStyle()).font(.system(size: 13))
                                }
                            }
                        }
                        Divider().padding(.horizontal, 8)
                    }
                    HStack(spacing: 2) {
                        sectionHeader("Projects", collapsed: store.archive.projectsSectionCollapsed == true,
                                      unread: unreadCount, toggle: store.toggleProjectsSection)
                        Button(action: switchProject) { Image(systemName: "magnifyingglass").frame(width: 26, height: 28) }
                            .buttonStyle(HoverButtonStyle(padded: false)).shortcutHint("projects").help("Switch Project (⇧⌘K)")
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
                    Divider().padding(.horizontal, 8)
                    VStack(alignment: .leading, spacing: 3) {
                        sectionHeader("Recent", collapsed: store.archive.recentSectionCollapsed == true,
                                      unread: store.archive.recentThreads.filter { $0.thread.hasUnreadCompletion }.count, toggle: store.toggleRecentSection)
                        if store.archive.recentSectionCollapsed != true {
                            if store.archive.recentThreads.isEmpty {
                                Text("Your conversations will appear here.")
                                    .font(.system(size: 12)).foregroundStyle(theme.secondary).padding(8)
                            }
                            ForEach(store.archive.recentThreads) { entry in
                                SidebarThreadRow(thread: entry.thread, projectName: entry.project.name, showsProjectName: true,
                                                 running: store.running.contains(entry.id),
                                                 selected: store.archive.selectedThreadID == entry.id && !store.showingTerminal,
                                                 select: { didNavigate(); store.selectThread(entry.thread, project: entry.project) },
                                                 togglePin: { store.toggleThreadPin(entry.id) })
                                    .contextMenu { threadMenu(entry.thread, project: entry.project) }
                            }
                        }
                    }
                }.padding(10)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            Divider()
            SettingsLink { HStack { Label("Settings", systemImage: "gearshape"); Spacer() } }
                .buttonStyle(HoverButtonStyle()).shortcutHint("settings", placement: .inline).help("Settings (⌘,)")
                .font(.system(size: 13)).foregroundStyle(theme.secondary).padding(14)
                .frame(maxWidth: .infinity).background(theme.panel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.panel)
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
            VStack(spacing: 3) {
                HStack(spacing: 2) {
                    Button { store.toggleProjectCollapse(project.id) } label: {
                        HStack(spacing: 8) {
                            ProjectFolderIcon(isOpen: !project.isCollapsed)
                                .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                                .foregroundStyle(theme.secondary).frame(width: 20, height: 20)
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
                            if project.isPinned { Image(systemName: "pin.fill").font(.system(size: 12)).foregroundStyle(theme.secondary) }
                        }.font(.system(size: 14, weight: .semibold)).padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(HoverButtonStyle(padded: false, selected: store.project?.id == project.id && project.isCollapsed)).help(project.rootPath)
                        .accessibilityLabel("\(project.isCollapsed ? "Expand" : "Collapse") \(project.name)")
                        .accessibilityValue(project.isCollapsed ? "Collapsed" : "Expanded")
                    Button { didNavigate(); store.newThread(projectID: project.id) } label: {
                        Image(systemName: "plus").frame(width: 26, height: 34)
                    }.buttonStyle(HoverButtonStyle(padded: false)).shortcutHint("newThread", active: store.project?.id == project.id).help("New thread in \(project.name)")
                        .accessibilityLabel("New thread in \(project.name)")
                }.contextMenu { projectMenu(project) }
                if !project.isCollapsed {
                    VStack(spacing: 3) {
                        ForEach(project.orderedThreads) { thread in
                            SidebarThreadRow(thread: thread, projectName: project.name, running: store.running.contains(thread.id),
                                             selected: store.archive.selectedThreadID == thread.id && !store.showingTerminal,
                                             select: { didNavigate(); store.selectThread(thread, project: project) },
                                             togglePin: { store.toggleThreadPin(thread.id) })
                                .contextMenu { threadMenu(thread, project: project) }
                        }
                        if !project.threads.isEmpty {
                            Divider().padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 3)
                        }
                        Button { didNavigate(); store.openTerminal(project) } label: {
                            Label("Terminal", systemImage: "terminal").font(.system(size: 14))
                                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(HoverButtonStyle(padded: false, selected: store.project?.id == project.id && store.showingTerminal))
                    }.padding(.leading, 24)
                }
            }
        }
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
    @Environment(\.octoTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    func makeNSView(context: Context) -> MarqueeTitleView { MarqueeTitleView() }
    func updateNSView(_ view: MarqueeTitleView, context: Context) {
        view.update(title: title, emphasized: weight == .semibold, color: theme.textColor,
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

private struct SidebarThreadRow: View {
    let thread: WorkspaceThread
    let projectName: String
    var showsProjectName = false
    let running: Bool
    let selected: Bool
    let select: () -> Void
    let togglePin: () -> Void
    @Environment(\.octoTheme) private var theme
    @State private var hovering = false
    @FocusState private var pinFocused: Bool
    private var showsPin: Bool { hovering || thread.isPinned || pinFocused }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: select) {
                HStack(spacing: 9) {
                    VStack(alignment: .leading, spacing: 3) {
                        HoverScrollingTitle(title: thread.title, hovering: hovering, weight: thread.hasUnreadCompletion ? .semibold : .regular)
                        if showsProjectName {
                            Text(projectName).font(.system(size: 11)).foregroundStyle(theme.secondary).lineLimit(1)
                        }
                    }.padding(.vertical, showsProjectName ? 5 : 0)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if running { WorkingIndicator().frame(width: 16, height: 16).accessibilityHidden(true) }
                    else if thread.hasUnreadCompletion {
                        Label("New", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.accent)
                            .fixedSize().help("Finished — unread")
                    }
                }.font(.system(size: 14)).padding(.leading, 10).padding(.trailing, 6)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(HoverButtonStyle(padded: false))
                .padding(.trailing, showsPin ? 32 : 0)
                .accessibilityLabel(thread.title + ", " + projectName)
                .accessibilityHint("Last activity " + ThreadHoverDetails.activityDate(thread).formatted())
                .accessibilityValue(running ? "Working" : thread.hasUnreadCompletion ? "Finished, unread" : "Read")
            Button(action: togglePin) {
                Image(systemName: thread.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12)).foregroundStyle(thread.isPinned ? theme.accent : theme.secondary)
                    .frame(width: 28, height: 30)
            }.buttonStyle(HoverButtonStyle(padded: false))
                .focused($pinFocused)
                .opacity(showsPin ? 1 : 0)
                .allowsHitTesting(showsPin)
                .help(thread.isPinned ? "Unpin thread" : "Pin thread")
                .accessibilityLabel("\(thread.isPinned ? "Unpin" : "Pin") \(thread.title)")
                .padding(.trailing, 4)
        }.background(selected ? theme.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .background(ThreadHoverAnchor(thread: thread, projectName: projectName, theme: theme, onHover: { hovering = $0 }))
    }
}

enum ThreadHoverDetails {
    static func activityDate(_ thread: WorkspaceThread) -> Date {
        max(thread.createdAt, thread.lastActivityAt ?? .distantPast,
            thread.messages.last.map { $0.completedAt ?? $0.createdAt } ?? .distantPast)
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

final class ThreadHoverAnchorView: NSView {
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var hoverRevision = 0
    private(set) var panel: NSPanel?
    private var content: ThreadHoverContent?
    private var eventMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { dismiss() } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // inVisibleRect follows geometry automatically. Replacing this area on every
        // layout synthesizes exit/enter events and can feed back into SwiftUI layout.
        guard tracking == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseMoved(with event: NSEvent) { setHovered(true) }
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
            if self.hovered { self.present() }
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
    func makeBody(configuration: Configuration) -> some View {
        HoverButton(configuration: configuration, padded: padded, selected: selected)
    }
    private struct HoverButton: View {
        @Environment(\.octoTheme) private var theme
        let configuration: ButtonStyle.Configuration
        let padded: Bool
        let selected: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
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
            let split = trailingVisible && !single
            let leadingVisible = !trailingVisible || !single
            ZStack(alignment: .leading) {
                leading().frame(height: geometry.size.height)
                    .modifier(PanelFrame(width: split ? width : geometry.size.width))
                    .opacity(leadingVisible ? 1 : 0).allowsHitTesting(leadingVisible).accessibilityHidden(!leadingVisible)
                ResizeHandle(enabled: split, color: NSColor(theme.border), activeColor: NSColor(theme.activeBorder), onDrag: { translation in
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
                trailing().frame(height: geometry.size.height).background(theme.background)
                    .modifier(PanelFrame(width: single ? geometry.size.width : max(0, available - width),
                                         x: trailingVisible ? (split ? width + 7 : 0) : geometry.size.width))
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
    func body(content: Content) -> some View {
        content.frame(width: width).clipped().offset(x: x)
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
    private func revealReview(files: Bool) {
        guard store.isProjectChat else { return }
        store.showingTerminal = false; store.showingReview = true; store.showingBrowser = false; review.browsingFiles = files
        if let project = store.project {
            Task { await review.switchBrowser(projectID: project.id, root: store.thread?.workingDirectory ?? project.rootPath) }
        }
    }
    private func revealBrowser() {
        guard store.isProjectChat else { return }
        store.showingTerminal = false; store.showingReview = true; store.showingBrowser = true
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
            .init(id: "review", title: "Toggle Review Panel", group: "Panels", key: "r", modifiers: [.command, .option], enabled: hasProject) { store.showingTerminal = false; store.showingReview.toggle() },
            .init(id: "composer", title: "Focus Thread / Composer", group: "Panels", key: "1", enabled: hasThread) { store.focusComposer() },
            .init(id: "changes", title: "Show Changes", group: "Panels", key: "2", enabled: hasProject) { revealReview(files: false) },
            .init(id: "browseFiles", title: "Show Files", group: "Panels", key: "3", enabled: hasProject) { revealReview(files: true) },
            .init(id: "browser", title: "Show Browser", group: "Panels", key: "5", enabled: hasProject) { revealBrowser() },
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
            .init(id: "previousTab", title: "Previous Terminal Tab", group: "Terminal", key: "[", modifiers: [.command, .shift], enabled: store.showingTerminal) { if let project { store.terminal.cycle(projectID: project.id, offset: -1) } },
            .init(id: "nextTab", title: "Next Terminal Tab", group: "Terminal", key: "]", modifiers: [.command, .shift], enabled: store.showingTerminal) { if let project { store.terminal.cycle(projectID: project.id, offset: 1) } },
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
                    revealReview(files: true)
                    Task {
                        await review.selectPath(path, projectID: project.id, root: store.thread?.workingDirectory ?? project.rootPath)
                        reviewFocus += 1
                    }
                }
            }
        }
    }
}

private struct FileTreeRows: View {
    let nodes: [FileNode]
    @ObservedObject var review: ReviewModel
    let action: (FileAction.Kind, String) -> Void
    let select: (String) -> Void
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
                Button { select(node.id) } label: {
                    Label(node.name, systemImage: "doc.text").font(.system(size: 13)).lineLimit(1)
                        .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(HoverButtonStyle(padded: false, selected: review.selectedPath == node.id))
                    .help(node.id).id(node.id).listRowBackground(Color.clear)
                    .contextMenu {
                        Button("Open File") { select(node.id) }
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
