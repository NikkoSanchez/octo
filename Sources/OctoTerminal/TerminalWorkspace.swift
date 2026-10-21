import AppKit
import SwiftUI
import OctoGhostty
import OctoCore

@MainActor public final class TerminalTab: ObservableObject, Identifiable {
    public let id = UUID()
    public let projectID: UUID
    public let directory: String
    public var editorSocket: String? { editorSession?.socket }
    private var editorSession: EditorSession?
    private var editorMonitor: Task<Void, Never>?
    @Published public var label: String
    /// Set by the user; overrides the automatic label until cleared.
    @Published public private(set) var customName: String?
    /// The last pane's process has ended.
    @Published public var exited = false
    /// Panes in creation order. Layout changes never reorder them, so no surface is remounted.
    @Published public private(set) var panes: [GhosttySession] = []
    @Published public private(set) var layout: SplitLayout<UUID>
    @Published public private(set) var focusedPane: UUID
    /// The pane that runs the editor command, if any; splits are always shells.
    private let primaryPane: UUID
    private let environment: [String: String]
    private var colors: GhosttyColors?
    /// The laid-out size, for Ghostty's point-based `resize_split`.
    var bounds: CGRect = .zero
    /// The focused pane, which keyboard focus and tab-level commands go to.
    public var state: GhosttySession { pane(focusedPane) ?? panes[0] }
    public var isSplit: Bool { panes.count > 1 }

    init(projectID: UUID, directory: String, label: String, command: String? = nil, editorSession: EditorSession? = nil) {
        self.projectID = projectID; self.directory = directory; self.label = label; self.editorSession = editorSession
        environment = ["PATH": Executables.searchPath, "OCTO_PROJECT_ID": projectID.uuidString]
        let primary = GhosttySession(options: .init(directory: directory, environment: environment, command: command))
        primaryPane = primary.id; focusedPane = primary.id; layout = SplitLayout(primary.id)
        adopt(primary)
        if editorSession != nil {
            editorMonitor = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    guard let self, self.editorSession != nil else { return }
                    self.refreshEditorSession()
                }
            }
        }
    }
    deinit { editorMonitor?.cancel() }
    public var title: String { customName ?? label }
    /// A blank name restores the automatic label.
    public func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        customName = trimmed.isEmpty ? nil : trimmed
    }
    func close() { editorMonitor?.cancel(); editorSession = nil; panes.forEach { $0.close() } }

    func refreshEditorSession() {
        guard editorSession?.hasExited == true else { return }
        editorSession = nil
        label = "Terminal"
        editorMonitor?.cancel()
    }

    public func pane(_ id: UUID) -> GhosttySession? { panes.first { $0.id == id } }
    @discardableResult func setColors(_ colors: GhosttyColors?) -> Bool {
        self.colors = colors
        // Live config updates preserve the surface, PTY, editor and scrollback.
        return panes.map { $0.setColors(colors) }.allSatisfy { $0 }
    }

    // MARK: Splits

    /// Splits the focused pane through Ghostty, so the new shell starts in the focused one's
    /// current directory as `new_split` does.
    public func split(_ direction: SplitDirection) {
        let name: String
        switch direction { case .right: name = "right"; case .down: name = "down"; case .left: name = "left"; case .up: name = "up" }
        if !state.perform("new_split:\(name)") { handle(.new(direction, directory: nil, fontSize: nil), from: focusedPane) }
    }
    public func focus(_ target: SplitFocusTarget) { handle(.focus(target), from: focusedPane) }
    public func equalize() { handle(.equalize, from: focusedPane) }
    public func toggleZoom() { handle(.toggleZoom, from: focusedPane) }
    /// Ghostty confirms first only when a program other than the shell is running.
    public func closeFocusedPane() { state.requestHostClose() }
    public func setRatio(_ ratio: Double, at path: [Int]) { layout.setRatio(ratio, at: path) }
    /// Opening a file belongs in the editor's pane, not a shell split beside it.
    func focusEditorPane() {
        guard editorSession != nil, layout.contains(primaryPane) else { return }
        if layout.zoomed != primaryPane { layout.zoomed = nil }
        focusedPane = primaryPane
    }

    func handle(_ action: GhosttySplitAction, from id: UUID) {
        guard !exited, layout.contains(id) else { return }
        switch action {
        case let .new(direction, inherited, fontSize):
            var isDirectory: ObjCBool = false
            let start = inherited.flatMap { FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue ? $0 : nil }
            let pane = GhosttySession(options: .init(directory: start ?? directory, environment: environment,
                fontSize: fontSize ?? GhosttyLaunchOptions(directory: directory).fontSize, isSplit: true))
            adopt(pane)
            layout.insert(pane.id, beside: id, direction: direction)
            focus(pane: pane.id)
        case let .focus(target):
            guard let next = layout.focusTarget(target, from: id) else { return }
            layout.zoomed = nil
            focus(pane: next)
        case let .resize(direction, points):
            guard !bounds.isEmpty else { return }
            layout.resize(id, direction: direction, by: points, in: bounds)
        case .equalize:
            layout.equalize()
        case .toggleZoom:
            guard layout.isSplit else { return }
            layout.zoomed = layout.zoomed == id ? nil : id
            focus(pane: id)
        }
    }
    private func adopt(_ pane: GhosttySession) {
        let id = pane.id
        pane.onClose = { [weak self] _ in self?.paneExited(id) }
        pane.onSplitAction = { [weak self] in self?.handle($0, from: id) }
        pane.onFocus = { [weak self] in if self?.focusedPane != id { self?.focusedPane = id } }
        if let colors { _ = pane.setColors(colors) }
        panes.append(pane)
    }
    private func focus(pane id: UUID) {
        focusedPane = id
        pane(id)?.requestFocus()
    }
    /// A pane whose process ends closes, as in Ghostty; the tab's last pane stays to show it exited.
    private func paneExited(_ id: UUID) {
        if id == primaryPane, editorSession != nil {
            editorSession = nil; editorMonitor?.cancel()
            if layout.isSplit { label = "Terminal" }
        }
        guard layout.isSplit, let pane = pane(id) else { exited = true; return }
        let next = layout.focusTarget(.previous, from: id)
        layout.remove(id)
        pane.close()
        panes.removeAll { $0.id == id }
        if focusedPane == id, let next { focus(pane: next) }
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
        var colors: GhosttyColors?
        if let palette = theme.palette {
            colors = GhosttyColors(background: palette.base, foreground: palette.text,
                cursor: palette.cursor, cursorText: palette.cursorText,
                selectionBackground: palette.terminalSelectionBackground, selectionForeground: palette.text,
                palette: palette.ansi)
        }
        return tab.setColors(colors)
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
    public func close(_ tab: TerminalTab) {
        tab.close()
        tabs.removeAll { $0.id == tab.id }
        selectedTabs[tab.projectID] = tabs.last(where: { $0.projectID == tab.projectID })?.id
    }
    public func shutdown() { tabs.forEach { $0.close() }; tabs.removeAll(); selectedTabs.removeAll() }
    public func openInEditor(projectID: UUID, directory: String, relativePath: String, line: Int = 1) async throws {
        guard let nvim = Executables.find("nvim") else { throw ProcessFailure.missing("nvim (LazyVim uses your existing Neovim configuration)") }
        let root = URL(fileURLWithPath: directory).resolvingSymlinksInPath()
        let file = root.appendingPathComponent(relativePath).resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: file.path) else {
            throw ProcessFailure.exited("The selected file no longer exists in this checkout.")
        }
        for tab in tabs { tab.refreshEditorSession() }
        if let tab = tabs.first(where: { $0.projectID == projectID && $0.directory == directory && $0.editorSocket != nil && !$0.exited }), let socket = tab.editorSocket {
            // RPC talks only to an editor Octo launched; it never types a command into a busy shell.
            let pathData = try JSONSerialization.data(withJSONObject: [file.path])
            let pathJSON = String(decoding: pathData, as: UTF8.self)
            let expression = "luaeval('(function() vim.cmd.edit(vim.fn.fnameescape(_A[1])); vim.api.nvim_win_set_cursor(0, {math.min(\(max(1,line)), vim.api.nvim_buf_line_count(0)), 0}); return 1 end)()', json_decode('\(pathJSON.replacingOccurrences(of: "'", with: "''"))'))"
            let result = try await ProcessRunner.run(nvim, arguments: ["--server", socket, "--remote-expr", expression], directory: root)
            guard tabs.contains(where: { $0.id == tab.id }) else { return }
            tab.refreshEditorSession()
            if tab.editorSocket != nil && !tab.exited {
                guard result.status == 0 else { throw ProcessFailure.exited("The editor tab is not ready or could not open the file. " + String(decoding: result.error, as: UTF8.self)) }
                tab.label = file.lastPathComponent; tab.focusEditorPane(); select(tab); return
            }
        }
        let session = try EditorSession()
        let command = session.command(editor: nvim, file: file, line: line)
        let tab = TerminalTab(projectID: projectID, directory: directory, label: file.lastPathComponent, command: command, editorSession: session)
        applyTheme(to: tab); tabs.append(tab); select(tab)
    }
    /// Selects this checkout's running editor tab, or starts Neovim on the checkout root.
    public func openDirectoryInEditor(projectID: UUID, directory: String) throws {
        guard let nvim = Executables.find("nvim") else { throw ProcessFailure.missing("nvim (LazyVim uses your existing Neovim configuration)") }
        let root = URL(fileURLWithPath: directory).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProcessFailure.exited("This checkout no longer exists.")
        }
        for tab in tabs { tab.refreshEditorSession() }
        if let tab = tabs.first(where: { $0.projectID == projectID && $0.directory == directory && $0.editorSocket != nil && !$0.exited }) {
            tab.focusEditorPane(); select(tab); return
        }
        let session = try EditorSession()
        let command = session.command(editor: nvim, file: root, line: 1)
        let tab = TerminalTab(projectID: projectID, directory: directory, label: root.lastPathComponent, command: command, editorSession: session)
        applyTheme(to: tab); tabs.append(tab); select(tab)
    }
}

/// A pane divider the host draws, so it matches the app's other resize handles.
public struct TerminalSplitHandle {
    /// Drags up and down along a horizontal divider, between stacked panes.
    public let vertical: Bool
    /// Ghostty's `split-divider-color`, when set.
    public let color: NSColor?
    /// Translation from the drag's start, positive rightwards or downwards.
    public let onDrag: (CGFloat) -> Void
    public let onEnd: () -> Void
}

/// All tabs and panes stay mounted even while chat is selected, preserving PTY processes and scrollback.
public struct TerminalSurfaces<Handle: View>: View {
    @ObservedObject var workspace: TerminalWorkspace
    var projectID: UUID?
    var visible: Bool
    let handle: (TerminalSplitHandle) -> Handle
    public init(workspace: TerminalWorkspace, projectID: UUID?, visible: Bool, @ViewBuilder handle: @escaping (TerminalSplitHandle) -> Handle) {
        self.workspace = workspace; self.projectID = projectID; self.visible = visible; self.handle = handle
    }
    public var body: some View {
        ZStack {
            ForEach(workspace.tabs) { tab in
                Panes(tab: tab, visible: visible && tab.projectID == projectID && workspace.selectedTabs[tab.projectID] == tab.id, handle: handle)
            }
        }
    }
    /// Panes are placed by frame rather than nested stacks: a nested layout would give a pane a
    /// new identity whenever the tree around it changed, remounting its surface.
    private struct Panes: View {
        @ObservedObject var tab: TerminalTab
        var visible: Bool
        let handle: (TerminalSplitHandle) -> Handle
        static var gap: CGFloat { 1 }
        /// Wide enough to grab; the drawn line stays in the gap.
        static var grip: CGFloat { 7 }
        @State private var dragStart: Double?
        var body: some View {
            GeometryReader { proxy in
                let bounds = CGRect(origin: .zero, size: proxy.size)
                let frames = tab.layout.frames(in: bounds, gap: Self.gap)
                let zoomed = tab.layout.zoomed
                let tiled = tab.isSplit && zoomed == nil
                ZStack(alignment: .topLeading) {
                    ForEach(tab.panes, id: \.id) { pane in
                        let frame = zoomed == pane.id ? bounds : frames[pane.id] ?? bounds
                        Pane(session: pane, visible: visible && (zoomed == nil || zoomed == pane.id),
                             focused: tab.focusedPane == pane.id, dimmed: tiled && tab.focusedPane != pane.id)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                    if tiled && visible {
                        ForEach(tab.layout.dividers(in: bounds, gap: Self.gap), id: \.path) { item in
                            divider(item)
                        }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .onAppear { tab.bounds = bounds }
                .onChange(of: proxy.size) { _, size in tab.bounds = CGRect(origin: .zero, size: size) }
            }
        }
        private func divider(_ divider: SplitDivider) -> some View {
            let vertical = divider.axis == .vertical
            let extent = (vertical ? divider.container.height : divider.container.width) - Self.gap
            let grip = vertical ? divider.frame.insetBy(dx: 0, dy: -(Self.grip - Self.gap) / 2)
                                : divider.frame.insetBy(dx: -(Self.grip - Self.gap) / 2, dy: 0)
            return handle(TerminalSplitHandle(vertical: vertical, color: tab.state.splitAppearance.divider, onDrag: { translation in
                if dragStart == nil { dragStart = divider.ratio }
                tab.setRatio((dragStart ?? divider.ratio) + translation / max(1, extent), at: divider.path)
            }, onEnd: { dragStart = nil }))
            .frame(width: grip.width, height: grip.height)
            .position(x: grip.midX, y: grip.midY)
        }
    }
    private struct Pane: View {
        @ObservedObject var session: GhosttySession
        var visible: Bool
        var focused: Bool
        var dimmed: Bool
        var body: some View {
            GhosttyTerminalSurface(session: session)
                .overlay {
                    // Ghostty's unfocused-split-opacity and unfocused-split-fill.
                    if dimmed, let fill = session.splitAppearance.unfocusedFill {
                        Color(nsColor: fill).opacity(1 - session.splitAppearance.unfocusedOpacity).allowsHitTesting(false)
                    }
                }
                .opacity(visible ? 1 : 0).allowsHitTesting(visible).accessibilityHidden(!visible)
                .onAppear { session.isSurfaceVisible = visible; if visible && focused { session.requestFocus() } }
                .onChange(of: visible) { _, value in session.isSurfaceVisible = value; if value && focused { session.requestFocus() } }
        }
    }
}
