import Foundation
import OctoCore
import OctoGit

@MainActor final class ReviewModel: ObservableObject {
    let editors: FileEditorWorkspace
    @Published private(set) var editor: FileEditorSession?
    init(editors: FileEditorWorkspace? = nil) { self.editors = editors ?? FileEditorWorkspace() }
    @Published var browsingFiles = false
    @Published var tree: [FileNode] = []
    @Published var files: [ChangedFile] = []
    @Published var snapshot: ReviewSnapshot?
    @Published var selectedPath: String?
    @Published var selection: CodeAttachment?
    @Published var scope: DiffScope = .working
    @Published var diffLayout: DiffLayout = .stacked {
        didSet { if diffLayout != oldValue { selection = nil } }
    }
    @Published var branch = ""
    @Published private(set) var branches: [String] = []
    /// Tracked-file line counts against HEAD; nil before the first read or in an unborn repository.
    @Published private(set) var diffStat: DiffStat?
    /// Per-scope line counts for the Staged and Unstaged groups.
    @Published private(set) var stagedStat: DiffStat?
    @Published private(set) var workingStat: DiffStat?
    @Published var error: String?
    @Published var loading = false
    @Published var expandedFolders = Set<String>()
    @Published var revealLine: Int?
    @Published var revealRequest = 0
    @Published private(set) var loadingSnapshot = false
    /// Every change, Staged then Unstaged, for the continuous diff. `snapshot` is the current file:
    /// the one chosen in the list, or the one scrolled to the top.
    @Published private(set) var changeSnapshots: [ReviewSnapshot] = []
    /// Asks the continuous diff to scroll a file to the top; a list click changes the request.
    @Published private(set) var revealFile: Int?
    @Published private(set) var revealFileRequest = 0
    private var currentFile: (path: String, scope: DiffScope)?
    private var filePath: String?
    private var changePath: String?
    private let git = GitService()
    private var generation = UUID()
    private var snapshotGeneration = UUID()
    private var context: String?
    func represents(projectID: UUID, root: String) -> Bool { context == projectID.uuidString + root }
    func fileDidChange(_ path: String, deleted: Bool, projectID: UUID, root: String) async {
        // File actions own their captured checkout; a superseded view must not receive their results.
        let expected = projectID.uuidString + root
        guard context == expected else { return }
        if deleted {
            editor = nil
            if filePath == path { filePath = nil }
            if changePath == path { changePath = nil }
            if selectedPath == path { selectedPath = nil; snapshot = nil; selection = nil }
        }
        await refresh(projectID: projectID, root: root)
        guard context == expected, !deleted else { return }
        browsingFiles = true
        let parts = path.split(separator: "/")
        for count in 1..<max(1, parts.count) { expandedFolders.insert(parts.prefix(count).joined(separator: "/")) }
        await selectPath(path, projectID: projectID, root: root)
        if context == expected { revealRequest += 1 }
    }
    func refresh(projectID: UUID, root: String, refreshSelection: Bool = true) async {
        let token = UUID(); generation = token; loading = true
        if refreshSelection { snapshotGeneration = UUID(); loadingSnapshot = false }
        let nextContext = projectID.uuidString + root
        if context != nextContext {
            // `filePath` belongs to the panel's selected file tab, which applies to every checkout.
            context = nextContext; editor = nil; changePath = nil; files = []; tree = []; snapshot = nil; selection = nil; selectedPath = nil; branch = ""; branches = []; diffStat = nil; stagedStat = nil; workingStat = nil; expandedFolders = []; revealLine = nil
            changeSnapshots = []; currentFile = nil; revealFile = nil
        }
        do {
            let result = try await git.changes(root: root), branch = await git.branch(root: root)
            guard generation == token else { return }
            let paths = try await git.filePaths(root: root)
            let stat = try? await git.diffStat(root: root)
            let staged = try? await git.diffStat(root: root, scope: .staged), working = try? await git.diffStat(root: root, scope: .working)
            guard generation == token else { return }
            if diffStat != stat { diffStat = stat }
            if stagedStat != staged { stagedStat = staged }
            if workingStat != working { workingStat = working }
            tree = FileNode.build(Array(Set(paths + editors.dirtyPaths(root: root))))
            files = result; self.branch = branch; error = nil
            if !refreshSelection { loading = false; return }
            if browsingFiles {
                if let filePath, paths.contains(filePath) || editors.existing(root: root, path: filePath)?.isDirty == true { await selectPath(filePath, projectID: projectID, root: root) }
                else { snapshot = nil; editor = nil; selection = nil; selectedPath = nil }
                if generation == token { loading = false }; return
            }
            await loadChanges(result, projectID: projectID, root: root)
        } catch { if generation == token { self.error = error.localizedDescription; files = []; snapshot = nil } }
        if generation == token { loading = false }
    }
    func loadBranches(projectID: UUID, root: String) async {
        let expected = projectID.uuidString + root
        let list = (try? await git.localBranches(root: root)) ?? []
        if context == expected, branches != list { branches = list }
    }
    /// Git refuses the switch when uncommitted changes would be overwritten; that message is thrown.
    func switchBranch(_ name: String, projectID: UUID, root: String) async throws {
        try await git.switchBranch(name, root: root)
        await refresh(projectID: projectID, root: root)
        await loadBranches(projectID: projectID, root: root)
    }
    func switchBrowser(projectID: UUID, root: String) async {
        selection = nil
        if browsingFiles {
            // Without a file of its own, Files opens the change being read.
            if let path = filePath ?? selectedPath ?? snapshot.flatMap({ $0.scope == .file ? nil : $0.path }) { await selectPath(path, projectID: projectID, root: root) }
            else { snapshotGeneration = UUID(); snapshot = nil; selectedPath = nil; loadingSnapshot = false }
        } else {
            // `selectedPath` held the Files tab's file; Changes restores only its own choice.
            selectedPath = changePath
            await loadChanges(files, projectID: projectID, root: root)
            if let path = selectedPath, let file = files.first(where: { $0.path == path }) { await select(file, projectID: projectID, root: root) }
        }
    }
    /// Mirrors the panel's selected tab before a refresh, so the refresh restores that tab's file.
    func adopt(_ tabs: PanelTabs) {
        guard tabs.showsReview else { return }
        browsingFiles = tabs.isBrowsingFiles
        if browsingFiles { filePath = tabs.selectedFile }
    }
    /// Shows the panel's selected tab. Browser tabs and the empty panel leave the review state untouched.
    func show(_ tabs: PanelTabs, projectID: UUID, root: String) async {
        guard tabs.showsReview else { return }
        adopt(tabs)
        if browsingFiles, filePath == nil {
            snapshotGeneration = UUID(); snapshot = nil; editor = nil; selectedPath = nil; selection = nil; loadingSnapshot = false
        } else if browsingFiles, let filePath, selectedPath == filePath, snapshot?.scope == .file, snapshot?.path == filePath, snapshot?.workingDirectory == root, !loadingSnapshot {
            return
        } else { await switchBrowser(projectID: projectID, root: root) }
    }
    func selectPath(_ path: String, projectID: UUID, root: String) async {
        guard browsingFiles else { return }
        if selectedPath != path || snapshot?.scope != .file || snapshot?.workingDirectory != root { selection = nil }
        let token = UUID(); snapshotGeneration = token; selectedPath = path; filePath = path; loadingSnapshot = true; revealLine = nil
        defer { if snapshotGeneration == token { loadingSnapshot = false } }
        do {
            let value = try await git.fileSnapshot(path: path, projectID: projectID, root: root)
            guard snapshotGeneration == token else { return }
            let session = editors.session(for: value)
            session.didSave = { [weak self] in
                guard let self, self.represents(projectID: projectID, root: root) else { return }
                await self.refresh(projectID: projectID, root: root, refreshSelection: !self.browsingFiles)
            }
            await session.load()
            guard snapshotGeneration == token else { return }
            snapshot = value; editor = session; error = nil
        } catch {
            guard snapshotGeneration == token else { return }
            if let draft = editors.existing(root: root, path: path), draft.isDirty {
                editor = draft; snapshot = draft.context; self.error = nil
            } else { self.error = error.localizedDescription; snapshot = nil; editor = nil }
        }
    }
    func reveal(_ link: MarkdownFileLink, projectID: UUID, root: String) async {
        // Remember the linked file so returning to Files restores this preview.
        filePath = link.path; browsingFiles = true
        let parts = link.path.split(separator: "/")
        for count in 1..<max(1, parts.count) { expandedFolders.insert(parts.prefix(count).joined(separator: "/")) }
        await selectPath(link.path, projectID: projectID, root: root)
        guard selectedPath == link.path, snapshot?.path == link.path, snapshot?.workingDirectory == root else { return }
        revealLine = link.line; revealRequest += 1
    }
    /// Selects a row in the Staged or Unstaged group; a file with both kinds of change has a row in each.
    func select(_ file: ChangedFile, scope: DiffScope, projectID: UUID, root: String) async {
        self.scope = scope
        await select(file, projectID: projectID, root: root)
    }
    /// Shows the selected file's other scope, when it has changes there.
    func toggleScope(projectID: UUID, root: String) async {
        guard !browsingFiles, let file = files.first(where: { $0.path == selectedPath }) else { return }
        let other: DiffScope = scope == .working ? .staged : .working
        guard other == .staged ? file.hasStaged : file.hasWorking else { return }
        await select(file, scope: other, projectID: projectID, root: root)
    }
    /// Loads every staged and unstaged diff. Nothing is selected by default; a chosen row survives
    /// while its file and group still have changes. The current file stays current where it can.
    private func loadChanges(_ files: [ChangedFile], projectID: UUID, root: String) async {
        let token = generation, expected = projectID.uuidString + root
        let entries = files.filter(\.hasStaged).map { (file: $0, scope: DiffScope.staged) } + files.filter(\.hasWorking).map { (file: $0, scope: DiffScope.working) }
        let loaded = await git.snapshots(entries, projectID: projectID, root: root)
        guard generation == token, context == expected, !browsingFiles else { return }
        if changeSnapshots.map(\.id) != loaded.map(\.id) { changeSnapshots = loaded }
        if let path = selectedPath, !loaded.contains(where: { $0.path == path && $0.scope == scope }) { selectedPath = nil; changePath = nil }
        let current = currentFile.flatMap { key in loaded.first { $0.path == key.path && $0.scope == key.scope } } ?? loaded.first
        currentFile = current.map { ($0.path, $0.scope) }
        if snapshot?.id != current?.id || snapshot?.scope == .file { snapshot = current }
        error = nil
    }
    /// The continuous diff scrolled another file to the top. A chosen row follows it.
    func showVisibleFile(_ index: Int) {
        guard !browsingFiles, changeSnapshots.indices.contains(index) else { return }
        let file = changeSnapshots[index]
        currentFile = (file.path, file.scope)
        if snapshot?.id != file.id { snapshot = file }
        if selectedPath != nil, selectedPath != file.path || scope != file.scope { selectedPath = file.path; changePath = file.path; scope = file.scope }
    }
    /// Choosing a row scrolls the continuous diff to that file. Side by side shows it alone.
    func select(_ file: ChangedFile, projectID: UUID, root: String) async {
        guard !browsingFiles else { return }
        if scope == .staged && !file.hasStaged { scope = .working }
        else if scope == .working && !file.hasWorking && file.hasStaged { scope = .staged }
        if let index = changeSnapshots.firstIndex(where: { $0.path == file.path && $0.scope == scope }) {
            snapshotGeneration = UUID(); loadingSnapshot = false
            selectedPath = file.path; changePath = file.path; selection = nil
            currentFile = (file.path, scope); snapshot = changeSnapshots[index]
            revealFile = index; revealFileRequest += 1
            // A file past the continuous diff's line limit is read on its own for side by side.
            guard changeSnapshots[index].notice == GitService.deferredNotice else { return }
        }
        let token = UUID(); snapshotGeneration = token; selectedPath = file.path; changePath = file.path; selection = nil; loadingSnapshot = true
        defer { if snapshotGeneration == token { loadingSnapshot = false } }
        do {
            let value = try await git.snapshot(file: file, projectID: projectID, root: root, scope: scope)
            guard snapshotGeneration == token else { return }; snapshot = value; error = nil
        } catch { if snapshotGeneration == token { self.error = error.localizedDescription; snapshot = nil } }
    }
}

struct FileNode: Identifiable {
    var id: String
    var name: String
    var children: [FileNode]?
    static func build(_ paths: [String], prefix: String = "") -> [FileNode] {
        let groups = Dictionary(grouping: paths) { $0.split(separator: "/", maxSplits: 1).first.map(String.init) ?? $0 }
        return groups.keys.sorted().map { name in
            let entries = groups[name] ?? []
            let nested = entries.compactMap { path -> String? in
                guard let slash = path.firstIndex(of: "/") else { return nil }
                return String(path[path.index(after: slash)...])
            }
            let id = prefix + name
            return FileNode(id: id, name: name, children: nested.isEmpty ? nil : build(nested, prefix: id + "/"))
        }.sorted { a, b in
            if (a.children != nil) != (b.children != nil) { return a.children != nil }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
