import SwiftUI
import OctoCore
import OctoGit
import OctoAgents
import OctoReview
import OctoTerminal

struct WorkspaceView: View {
    @ObservedObject var store: AppStore
    @StateObject private var review = ReviewModel()
    @State private var sidebarOpen = true
    @State private var compactSidebarOpen = false
    @State private var sidebarWidth: CGFloat = 270
    @State private var sidebarDragStart: CGFloat?
    @State private var windowWidth: CGFloat = 1380
    @State private var palette: PaletteMode?
    @State private var paletteAction: (() -> Void)?
    @State private var reviewFocus = 0
    @State private var showingShortcutHints = false
    @Environment(\.openSettings) private var openSettings
    @Environment(\.octoTheme) private var theme
    @Environment(\.scenePhase) private var phase
    var body: some View {
        GeometryReader { geometry in
            let layout = layout(at: geometry.size.width)
            ZStack(alignment: .leading) {
                VStack(spacing: 0) {
                    titlebar
                    Divider()
                    ZStack {
                        threadWorkspace.opacity(store.showingTerminal ? 0 : 1).allowsHitTesting(!store.showingTerminal).accessibilityHidden(store.showingTerminal)
                        TerminalPane(store: store, terminal: store.terminal, visible: store.showingTerminal && !layout.overlayVisible)
                            .opacity(store.showingTerminal ? 1 : 0).allowsHitTesting(store.showingTerminal).accessibilityHidden(!store.showingTerminal)
                    }
                }
                .frame(width: layout.detailWidth, height: geometry.size.height).clipped()
                .background(theme.background).offset(x: layout.detailOffset)
                .allowsHitTesting(!layout.overlayVisible).accessibilityHidden(layout.overlayVisible)

                Color.black.opacity(layout.overlayVisible ? 0.2 : 0)
                    .contentShape(Rectangle()).onTapGesture { closeCompactSidebar() }
                    .allowsHitTesting(layout.overlayVisible).accessibilityHidden(true)

                VStack(spacing: 0) {
                    HStack {
                        Text("Octo").font(.headline)
                        Spacer()
                        Button(action: toggleSidebar) { Image(systemName: "sidebar.left") }
                            .hoverFeedback().help("Hide sidebar (⌘B)").accessibilityLabel("Hide sidebar")
                    }.padding(12)
                    sidebar
                }
                .frame(width: layout.sidebarWidth, height: geometry.size.height).background(theme.panel).clipped()
                .opacity(layout.sidebarVisible ? 1 : 0)
                .allowsHitTesting(layout.sidebarVisible).accessibilityHidden(!layout.sidebarVisible)

                Rectangle().fill(theme.border).frame(width: 1).frame(width: 7).contentShape(Rectangle())
                    .offset(x: layout.sidebarWidth)
                    .opacity(layout.sidebarVisible && !layout.compact ? 1 : 0)
                    .allowsHitTesting(layout.sidebarVisible && !layout.compact)
                    .accessibilityHidden(!layout.sidebarVisible || layout.compact)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        if sidebarDragStart == nil { sidebarDragStart = sidebarWidth }
                        sidebarWidth = min(320, max(240, (sidebarDragStart ?? sidebarWidth) + value.translation.width))
                    }.onEnded { _ in sidebarDragStart = nil })
                    .accessibilityLabel("Resize sidebar")
                    .accessibilityValue("\(Int(sidebarWidth)) points")
                    .accessibilityAdjustableAction { direction in sidebarWidth = min(320, max(240, sidebarWidth + (direction == .increment ? 20 : -20))) }
            }
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
    private var singleReview: Bool { layout.detailWidth < 737 && store.showingReview && !store.showingTerminal }
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
        guard let project = store.project else { return }
        await review.refresh(projectID: project.id, root: store.thread?.workingDirectory ?? project.rootPath)
    }
    private func openMarkdownFile(_ url: URL) {
        guard let project = store.project else { return }
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
    private var titlebar: some View {
        HStack {
            Button(action: toggleSidebar) { Image(systemName: "sidebar.left") }
                .hoverFeedback().shortcutHint("sidebar").help("Toggle sidebar (⌘B)").accessibilityLabel("Toggle sidebar")
            VStack(alignment: .leading, spacing: 3) {
                Text(store.showingTerminal ? "\(store.project?.name ?? "Octo") · Terminal" : store.thread?.title ?? "Welcome to Octo").font(.headline).lineLimit(1)
                Text(store.showingTerminal ? "Project terminal workspace" : "\(store.project?.name ?? "Local development")  /  \(review.branch)").font(.system(size: 13)).foregroundStyle(theme.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if store.project != nil && !store.showingTerminal {
                Button { store.showingReview.toggle() } label: { Image(systemName: "sidebar.right") }
                    .hoverFeedback().shortcutHint("review")
                    .help(store.showingReview ? "Hide review panel" : "Show review panel")
                    .accessibilityLabel(store.showingReview ? "Hide review panel" : "Show review panel")

            }
            if store.showingTerminal { Button { store.focusComposer() } label: { Image(systemName: "bubble.left") }.hoverFeedback().shortcutHint("terminal").help("Back to thread").accessibilityLabel("Back to thread") }
            else if let project = store.project { Button { store.openTerminal(project) } label: { Image(systemName: "terminal") }.hoverFeedback().shortcutHint("terminal").help("Terminal").accessibilityLabel("Terminal") }
        }.padding(.horizontal, 12).padding(.vertical, 13)
    }
    @ViewBuilder private var threadWorkspace: some View {
        if let project = store.project {
            ResizableColumns(minLeading: 300, minTrailing: 430, initialFraction: 0.42, trailingVisible: store.showingReview, singleColumnWhenNarrow: true) {
                ChatPane(store: store, openFile: openMarkdownFile)
            } trailing: {
                reviewPane(project)
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
                    }.buttonStyle(HoverButtonStyle(padded: false, selected: !review.browsingFiles))
                        .shortcutHint("changes")
                        .accessibilityAddTraits(!review.browsingFiles ? .isSelected : [])
                    Button { revealReview(files: true) } label: {
                        Text("Files").frame(maxWidth: .infinity, minHeight: 28)
                    }.buttonStyle(HoverButtonStyle(padded: false, selected: review.browsingFiles))
                        .shortcutHint("browseFiles")
                        .accessibilityAddTraits(review.browsingFiles ? .isSelected : [])
                }.padding(3).background(theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: 240)
                Spacer()
                ProgressView().controlSize(.small).opacity(review.loading || review.loadingSnapshot ? 1 : 0).accessibilityHidden(!review.loading && !review.loadingSnapshot)
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }.hoverFeedback().shortcutHint("refresh").help("Refresh changes")
            }.padding(12)
            Divider()
            if let error = review.error { Text(error).font(.system(size: 13)).foregroundStyle(theme.red).padding() }
                ResizableColumns(minLeading: 150, maxLeading: 260, minTrailing: 270, initialFraction: 0.3) {
                    ZStack {
                        ScrollViewReader { proxy in
                            List {
                                FileTreeRows(nodes: review.tree, review: review) { path in
                                    Task { await review.selectPath(path, projectID: project.id, root: store.thread?.workingDirectory ?? project.rootPath) }
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
                            if let notice = snapshot.notice { Text(notice).font(.system(size: 13)).foregroundStyle(theme.secondary).padding(); Spacer() }
                            else {
                                NativeDiffView(snapshot: snapshot, theme: store.theme, focusRequest: reviewFocus, revealLine: review.revealLine, revealRequest: review.revealRequest, onSelection: { if !review.loadingSnapshot { review.selection = $0 } }, onAskAgent: { if !review.loadingSnapshot { attachToDraft($0) } })
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
                            Button { terminal.select(tab) } label: { Text(tab.label).lineLimit(1).padding(.horizontal, 8).frame(minHeight: 30).contentShape(Rectangle()) }.buttonStyle(HoverButtonStyle(padded: false))
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

private struct ProjectSidebar: View {
    @ObservedObject var store: AppStore
    let switchProject: () -> Void
    let didNavigate: () -> Void
    @Environment(\.octoTheme) private var theme
    @State private var renaming: SidebarTarget?
    @State private var removing: SidebarTarget?
    @State private var name = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Projects").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.secondary)
                    Spacer()
                    Button(action: switchProject) { Image(systemName: "magnifyingglass").frame(width: 26, height: 28) }
                        .buttonStyle(HoverButtonStyle(padded: false)).shortcutHint("projects").help("Switch Project (⇧⌘K)")
                        .accessibilityLabel("Switch Project")
                    Button { store.chooseProject() } label: { Image(systemName: "plus").frame(width: 26, height: 28) }
                        .buttonStyle(HoverButtonStyle(padded: false)).shortcutHint("addProject").help("Add Project")
                        .accessibilityLabel("Add Project")
                }.padding(.leading, 8)
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
                                    if project.isPinned { Image(systemName: "pin.fill").font(.system(size: 12)).foregroundStyle(theme.secondary) }
                                }.font(.system(size: 15, weight: .semibold)).padding(.horizontal, 10)
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
                                    SidebarThreadRow(thread: thread, running: store.running.contains(thread.id),
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
            }.padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.panel)
        .safeAreaInset(edge: .bottom) {
            HStack {
                SettingsLink { HStack { Label("Settings", systemImage: "gearshape"); Spacer() } }
                    .buttonStyle(HoverButtonStyle()).shortcutHint("settings", placement: .inline).help("Settings (⌘,)")
            }
                .font(.system(size: 13)).foregroundStyle(theme.secondary).padding(14)
        }
        .overlay {
            if store.archive.projects.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus").font(.largeTitle)
                    Text("Your projects live here").font(.system(size: 14))
                    Button("Add Project…") { store.chooseProject() }
                }.padding()
            }
        }
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
        Button("New Thread in Project") { store.newThread(projectID: project.id) }
        Divider()
        Button("Delete Thread…", role: .destructive) { removing = SidebarTarget(projectID: project.id, threadID: thread.id) }
            .disabled(store.running.contains(thread.id))
    }
}

private struct SidebarThreadRow: View {
    let thread: WorkspaceThread
    let running: Bool
    let selected: Bool
    let select: () -> Void
    let togglePin: () -> Void
    @Environment(\.octoTheme) private var theme
    @State private var hovering = false
    @FocusState private var pinFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 9) {
                    Text(thread.title).lineLimit(1)
                    Spacer(minLength: 0)
                    // Reserve the trailing status slot so starting/stopping work never shifts the title.
                    ZStack {
                        if running { WorkingIndicator().accessibilityHidden(true) }
                    }.frame(width: 16, height: 16)
                }.font(.system(size: 14)).padding(.leading, 10).padding(.trailing, 6)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(HoverButtonStyle(padded: false)).help(thread.title)
                .accessibilityLabel(thread.title).accessibilityValue(running ? "Working" : "Idle")
            Button(action: togglePin) {
                Image(systemName: thread.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12)).foregroundStyle(thread.isPinned ? theme.accent : theme.secondary)
                    .frame(width: 28, height: 30)
            }.buttonStyle(HoverButtonStyle(padded: false))
                .focused($pinFocused)
                .opacity(hovering || thread.isPinned || pinFocused ? 1 : 0)
                .help(thread.isPinned ? "Unpin thread" : "Pin thread")
                .accessibilityLabel("\(thread.isPinned ? "Unpin" : "Pin") \(thread.title)")
                .padding(.trailing, 4)
        }.background(selected ? theme.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle()).onHover { hovering = $0 }
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
private struct ResizableColumns<Leading: View, Trailing: View>: View {
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
    @State private var hovering = false

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
                leading().frame(width: split ? width : geometry.size.width, height: geometry.size.height).clipped()
                    .opacity(leadingVisible ? 1 : 0).allowsHitTesting(leadingVisible).accessibilityHidden(!leadingVisible)
                Rectangle().fill(hovering || dragStart != nil ? theme.activeBorder : theme.border)
                    .frame(width: 1).frame(width: 7).contentShape(Rectangle()).offset(x: width)
                    .opacity(split ? 1 : 0).allowsHitTesting(split).accessibilityHidden(!split)
                    .onHover { hovering = $0 }
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragStart == nil { dragStart = width }
                            let next = min(upper, max(lower, (dragStart ?? width) + value.translation.width))
                            fraction = next / max(1, available)
                        }
                        .onEnded { _ in dragStart = nil })
                    .accessibilityLabel("Resize panels")
                    .accessibilityValue("\(Int(width)) points")
                    .accessibilityAdjustableAction { direction in
                        let next = min(upper, max(lower, width + (direction == .increment ? 20 : -20)))
                        fraction = next / max(1, available)
                    }
                trailing().frame(width: single ? geometry.size.width : max(0, available - width), height: geometry.size.height).clipped()
                    .offset(x: split ? width + 7 : 0)
                    .opacity(trailingVisible ? 1 : 0).allowsHitTesting(trailingVisible).accessibilityHidden(!trailingVisible)
            }
        }
    }
}

extension WorkspaceView {
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
        store.showingTerminal = false; store.showingReview = true; review.browsingFiles = files
        if let project = store.project {
            Task { await review.switchBrowser(projectID: project.id, root: store.thread?.workingDirectory ?? project.rootPath) }
        }
    }
    private func editSidebar(_ kind: SidebarEdit.Kind, thread: Bool) {
        guard let project = store.project else { return }
        showSidebar()
        store.sidebarEdit = SidebarEdit(projectID: project.id, threadID: thread ? store.thread?.id : nil, kind: kind)
    }
    private var commands: [AppCommand] {
        let project = store.project, thread = store.thread
        let hasProject = project != nil, hasThread = thread != nil
        let idle = thread.map { !store.running.contains($0.id) } ?? false
        var result: [AppCommand] = [
            .init(id: "newThread", title: "New Thread", group: "Create", key: "n", enabled: hasProject) { store.newThread() },
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
            .init(id: "send", title: "Send Message", group: "Conversation", key: "\r", enabled: thread.map { idle && store.canSend($0) } ?? false, terminalAllowed: false) { store.send() },
            .init(id: "stop", title: "Stop Agent", group: "Conversation", key: ".", enabled: !idle && hasThread, terminalAllowed: false) { if let thread { store.stop(thread.id) } },
            .init(id: "refresh", title: "Refresh Changes and Files", group: "Review", key: "r", modifiers: [.command, .shift], enabled: hasProject) { Task { await refresh() } },
            .init(id: "focusReview", title: "Focus Code Preview", group: "Review", key: "4", enabled: review.snapshot != nil && !review.loadingSnapshot) {
                compactSidebarOpen = false
                store.showingTerminal = false; store.showingReview = true
                DispatchQueue.main.async { reviewFocus += 1 }
            },
            .init(id: "attach", title: "Attach Selected Code to Draft", group: "Review", key: "a", modifiers: [.command, .shift], enabled: review.selection != nil && !review.loadingSnapshot && store.showingReview, terminalAllowed: false) {
                if let selection = review.selection { store.attach(selection); store.focusComposer() }
            },
            .init(id: "editor", title: "Open Selected File in LazyVim", group: "Review", key: "e", modifiers: [.command, .shift], enabled: review.snapshot?.notice == nil && review.snapshot != nil && !review.loadingSnapshot) {
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
            .init(id: "removeProject", title: "Remove Project…", group: "Project", enabled: project.map { p in !p.threads.contains { store.running.contains($0.id) } && !store.terminal.tabs.contains { $0.projectID == p.id } } ?? false) { editSidebar(.remove, thread: false) }
        ]
        for project in store.archive.orderedProjects {
            result.append(.init(id: "project-\(project.id)", title: "Switch to Project: \(project.name)", group: "Project") { store.selectProject(project) })
        }
        if let thread {
            for descriptor in store.harnessDescriptors {
                result.append(.init(id: "provider-\(descriptor.id)", title: "Provider: \(descriptor.id.title)", group: "Agent", enabled: idle) { store.changeHarness(descriptor.id) })
            }
            if thread.harness == .codex {
                for model in store.modelCatalogs[thread.workingDirectory] ?? [] {
                    result.append(.init(id: "model-\(model.id)", title: "Model: \(model.displayName)", group: "Agent", enabled: idle) { store.selectModel(model) })
                    if model.model == thread.agentSettings.model {
                        for effort in model.supportedReasoningEfforts {
                            result.append(.init(id: "effort-\(effort.id)", title: "Reasoning: \(effort.title)", group: "Agent", enabled: idle) { store.selectReasoning(effort.reasoningEffort) })
                        }
                    }
                }
                result.append(.init(id: "refreshModels", title: "Refresh Models", group: "Agent", enabled: !store.loadingModels.contains(thread.workingDirectory)) { Task { await store.loadModels(directory: thread.workingDirectory, refresh: true) } })
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
            return store.archive.orderedProjects.flatMap { project in project.orderedThreads.map { thread in
                PaletteEntry(id: thread.id.uuidString, title: thread.title, detail: project.name,
                             searchText: thread.messages.map(\.text).joined(separator: "\n")) { store.selectThread(thread, project: project) }
            } }
        case .files:
            guard let project = store.project else { return [] }
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
    let select: (String) -> Void
    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                DisclosureGroup(isExpanded: Binding(get: { review.expandedFolders.contains(node.id) }, set: {
                    if $0 { review.expandedFolders.insert(node.id) } else { review.expandedFolders.remove(node.id) }
                })) {
                    FileTreeRows(nodes: children, review: review, select: select)
                } label: {
                    Label(node.name, systemImage: "folder").font(.system(size: 13)).lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                }
            } else {
                Button { select(node.id) } label: {
                    Label(node.name, systemImage: "doc.text").font(.system(size: 13)).lineLimit(1)
                        .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(HoverButtonStyle(padded: false, selected: review.selectedPath == node.id))
                    .help(node.id).id(node.id).listRowBackground(Color.clear)
            }
        }
    }
}
