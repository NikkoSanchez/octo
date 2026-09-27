import AppKit
import SwiftUI
import GhosttyTerminal
import OctoCore

@MainActor public final class TerminalTab: ObservableObject, Identifiable {
    public let id = UUID()
    public let projectID: UUID
    public let directory: String
    public let editorSocket: String?
    private var editorDirectory: PrivateTemporaryDirectory?
    @Published public var label: String
    @Published public var exited = false
    public let state: TerminalViewState
    init(projectID: UUID, directory: String, label: String, command: String? = nil, editorSocket: String? = nil, editorDirectory: PrivateTemporaryDirectory? = nil) {
        self.projectID = projectID; self.directory = directory; self.label = label; self.editorSocket = editorSocket; self.editorDirectory = editorDirectory
        let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ghostty/config").path
        state = TerminalViewState(configFilePath: FileManager.default.fileExists(atPath: config) ? config : nil)
        state.configuration = TerminalSurfaceOptions(backend: .exec, fontSize: 13, workingDirectory: directory,
            envVars: ["PATH": Executables.searchPath, "OCTO_PROJECT_ID": projectID.uuidString], command: command, waitAfterCommand: true)
        state.onClose = { [weak self] _ in self?.exited = true; self?.editorDirectory = nil }
    }
}

@MainActor public final class TerminalWorkspace: ObservableObject {
    @Published public private(set) var tabs: [TerminalTab] = []
    @Published public var selectedTabs: [UUID: UUID] = [:]
    private var theme: AppTheme = .system
    public init() {}
    @discardableResult public func applyTheme(_ theme: AppTheme) -> Bool {
        self.theme = theme
        var succeeded = true
        for tab in tabs { if !applyTheme(to: tab) { succeeded = false } }
        return succeeded
    }
    @discardableResult private func applyTheme(to tab: TerminalTab) -> Bool {
        var config = TerminalConfiguration()
        if let palette = theme.palette {
            config = config.background(palette.base).foreground(palette.text)
                .cursorColor(palette.rosewater).cursorText(palette.cursorText)
                .selectionBackground(palette.terminalSelectionBackground).selectionForeground(palette.text)
            for (index, color) in palette.ansi.enumerated() { config = config.palette(index, color: color) }
            config = config.palette(16, color: palette.peach).palette(17, color: palette.rosewater)
        }
        // Live config updates preserve the surface, PTY, editor and scrollback.
        return tab.state.setTheme(TerminalTheme(light: config, dark: config))
    }
    public func focusSelected(projectID: UUID) {
        tabs.first { $0.id == selectedTabs[projectID] }?.state.requestFocus()
    }
    public func cycle(projectID: UUID, offset: Int) {
        let candidates = tabs.filter { $0.projectID == projectID }
        guard !candidates.isEmpty else { return }
        let current = candidates.firstIndex { $0.id == selectedTabs[projectID] } ?? 0
        select(candidates[(current + offset + candidates.count) % candidates.count])
    }
    @discardableResult public func newTab(projectID: UUID, directory: String) -> TerminalTab {
        let tab = TerminalTab(projectID: projectID, directory: directory, label: "Terminal")
        applyTheme(to: tab); tabs.append(tab); selectedTabs[projectID] = tab.id; tab.state.requestFocus(); return tab
    }
    public func ensureTab(projectID: UUID, directory: String) {
        if !tabs.contains(where: { $0.projectID == projectID }) { newTab(projectID: projectID, directory: directory) }
    }
    public func select(_ tab: TerminalTab) { selectedTabs[tab.projectID] = tab.id; tab.state.requestFocus() }
    public func close(_ tab: TerminalTab) { tabs.removeAll { $0.id == tab.id }; selectedTabs[tab.projectID] = tabs.last(where: { $0.projectID == tab.projectID })?.id }
    public func openInEditor(projectID: UUID, directory: String, relativePath: String, line: Int = 1) async throws {
        guard let nvim = Executables.find("nvim") else { throw ProcessFailure.missing("nvim (LazyVim uses your existing Neovim configuration)") }
        let root = URL(fileURLWithPath: directory).resolvingSymlinksInPath()
        let file = root.appendingPathComponent(relativePath).resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: file.path) else {
            throw ProcessFailure.exited("The selected file no longer exists in this checkout.")
        }
        if let tab = tabs.first(where: { $0.projectID == projectID && $0.directory == directory && $0.editorSocket != nil && !$0.exited }), let socket = tab.editorSocket {
            // RPC talks only to an editor Octo launched; it never types a command into a busy shell.
            let pathData = try JSONSerialization.data(withJSONObject: [file.path])
            let pathJSON = String(decoding: pathData, as: UTF8.self)
            let expression = "luaeval('(function() vim.cmd.edit(vim.fn.fnameescape(_A[1])); vim.api.nvim_win_set_cursor(0, {math.min(\(max(1,line)), vim.api.nvim_buf_line_count(0)), 0}); return 1 end)()', json_decode('\(pathJSON.replacingOccurrences(of: "'", with: "''"))'))"
            let result = try await ProcessRunner.run(nvim, arguments: ["--server", socket, "--remote-expr", expression], directory: root)
            guard result.status == 0 else { throw ProcessFailure.exited("The editor tab is not ready or has exited. Close it and try again. " + String(decoding: result.error, as: UTF8.self)) }
            tab.label = file.lastPathComponent; select(tab); return
        }
        let socketDirectory = try PrivateTemporaryDirectory()
        let socket = socketDirectory.url.appendingPathComponent("nvim.sock").path
        let command = [nvim.path, "--listen", socket, "+\(max(1,line))", "--", file.path].map(Executables.shellQuote).joined(separator: " ")
        let tab = TerminalTab(projectID: projectID, directory: directory, label: file.lastPathComponent, command: command, editorSocket: socket, editorDirectory: socketDirectory)
        applyTheme(to: tab); tabs.append(tab); select(tab)
    }
}

/// All tabs stay mounted even while chat is selected, preserving PTY processes and scrollback.
public struct TerminalSurfaces: View {
    @ObservedObject var workspace: TerminalWorkspace
    var projectID: UUID?
    var visible: Bool
    public init(workspace: TerminalWorkspace, projectID: UUID?, visible: Bool) {
        self.workspace = workspace; self.projectID = projectID; self.visible = visible
    }
    public var body: some View {
        ZStack {
            ForEach(workspace.tabs) { tab in
                Surface(tab: tab, visible: visible && tab.projectID == projectID && workspace.selectedTabs[tab.projectID] == tab.id)
            }
        }
    }
    private struct Surface: View {
        @ObservedObject var tab: TerminalTab
        var visible: Bool
        var body: some View {
            TerminalSurfaceView(context: tab.state)
                .opacity(visible ? 1 : 0).allowsHitTesting(visible).accessibilityHidden(!visible)
                .onAppear { tab.state.isSurfaceVisible = visible; if visible { tab.state.requestFocus() } }
                .onChange(of: visible) { _, value in tab.state.isSurfaceVisible = value; if value { tab.state.requestFocus() } }
        }
    }
}
