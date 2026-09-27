import Foundation
import OctoCore
import OctoGit

@MainActor final class ReviewModel: ObservableObject {
    @Published var browsingFiles = false
    @Published var tree: [FileNode] = []
    @Published var files: [ChangedFile] = []
    @Published var snapshot: ReviewSnapshot?
    @Published var selectedPath: String?
    @Published var selection: CodeAttachment?
    @Published var scope: DiffScope = .working
    @Published var branch = ""
    @Published var error: String?
    @Published var loading = false
    @Published var expandedFolders = Set<String>()
    @Published var revealLine: Int?
    @Published var revealRequest = 0
    @Published private(set) var loadingSnapshot = false
    private var filePath: String?
    private var changePath: String?
    private let git = GitService()
    private var generation = UUID()
    private var snapshotGeneration = UUID()
    private var context: String?
    func refresh(projectID: UUID, root: String) async {
        let token = UUID(); generation = token; loading = true
        snapshotGeneration = UUID(); loadingSnapshot = false
        let nextContext = projectID.uuidString + root
        if context != nextContext {
            context = nextContext; filePath = nil; changePath = nil; files = []; tree = []; snapshot = nil; selection = nil; selectedPath = nil; branch = ""; expandedFolders = []; revealLine = nil
        }
        do {
            let result = try await git.changes(root: root), branch = await git.branch(root: root)
            guard generation == token else { return }
            let paths = try await git.filePaths(root: root)
            guard generation == token else { return }
            tree = FileNode.build(paths)
            files = result; self.branch = branch; error = nil
            if browsingFiles {
                if let selectedPath, paths.contains(selectedPath) { await selectPath(selectedPath, projectID: projectID, root: root) }
                else { snapshot = nil; selection = nil; selectedPath = nil }
                if generation == token { loading = false }; return
            }
            if !result.contains(where: { $0.path == selectedPath }) { selectedPath = result.first?.path }
            if let file = result.first(where: { $0.path == selectedPath }) { await select(file, projectID: projectID, root: root) }
            else { snapshot = nil; selection = nil }
        } catch { if generation == token { self.error = error.localizedDescription; files = []; snapshot = nil } }
        if generation == token { loading = false }
    }
    func switchBrowser(projectID: UUID, root: String) async {
        selection = nil
        if browsingFiles {
            if let path = filePath ?? selectedPath { await selectPath(path, projectID: projectID, root: root) }
            else { snapshotGeneration = UUID(); snapshot = nil; selectedPath = nil; loadingSnapshot = false }
        } else {
            let path = changePath ?? selectedPath
            if let file = files.first(where: { $0.path == path }) ?? files.first { await select(file, projectID: projectID, root: root) }
            else { snapshotGeneration = UUID(); snapshot = nil; selectedPath = nil; loadingSnapshot = false }
        }
    }
    func selectPath(_ path: String, projectID: UUID, root: String) async {
        guard browsingFiles else { return }
        let token = UUID(); snapshotGeneration = token; selectedPath = path; filePath = path; selection = nil; loadingSnapshot = true; revealLine = nil
        defer { if snapshotGeneration == token { loadingSnapshot = false } }
        do {
            let value = try await git.fileSnapshot(path: path, projectID: projectID, root: root)
            guard snapshotGeneration == token else { return }; snapshot = value; error = nil
        } catch { if snapshotGeneration == token { self.error = error.localizedDescription; snapshot = nil } }
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
    func select(_ file: ChangedFile, projectID: UUID, root: String) async {
        guard !browsingFiles else { return }
        let token = UUID(); snapshotGeneration = token; selectedPath = file.path; changePath = file.path; selection = nil; loadingSnapshot = true
        defer { if snapshotGeneration == token { loadingSnapshot = false } }
        if scope == .staged && !file.hasStaged { scope = .working }
        else if scope == .working && !file.hasWorking && file.hasStaged { scope = .staged }
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
