import AppKit
import SwiftUI
import OctoCore
import OctoGit

/// Where "Open in" can send a checkout. LazyVim runs in Octo's terminal with the user's own
/// Neovim configuration; every other target is an installed app opened through Launch Services.
struct OpenTarget: Identifiable, Equatable {
    enum Kind: Equatable { case lazyVim, finder, app(bundleID: String) }
    let id: String
    let title: String
    let kind: Kind

    static let all: [OpenTarget] = [
        .init(id: "lazyvim", title: "LazyVim", kind: .lazyVim),
        .init(id: "cursor", title: "Cursor", kind: .app(bundleID: "com.todesktop.230313mzl4w4u92")),
        .init(id: "vscode", title: "VS Code", kind: .app(bundleID: "com.microsoft.VSCode")),
        .init(id: "vscode-insiders", title: "VS Code Insiders", kind: .app(bundleID: "com.microsoft.VSCodeInsiders")),
        .init(id: "zed", title: "Zed", kind: .app(bundleID: "dev.zed.Zed")),
        .init(id: "windsurf", title: "Windsurf", kind: .app(bundleID: "com.exafunction.windsurf")),
        .init(id: "sublime", title: "Sublime Text", kind: .app(bundleID: "com.sublimetext.4")),
        .init(id: "xcode", title: "Xcode", kind: .app(bundleID: "com.apple.dt.Xcode")),
        .init(id: "finder", title: "Finder", kind: .finder),
        .init(id: "terminal", title: "Terminal", kind: .app(bundleID: "com.apple.Terminal")),
        .init(id: "ghostty", title: "Ghostty", kind: .app(bundleID: "com.mitchellh.ghostty")),
        .init(id: "iterm", title: "iTerm", kind: .app(bundleID: "com.googlecode.iterm2")),
        .init(id: "warp", title: "Warp", kind: .app(bundleID: "dev.warp.Warp-Stable"))
    ]

    var applicationURL: URL? {
        guard case .app(let bundleID) = kind else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// LazyVim and Finder are always listed; apps only when Launch Services knows them.
    @MainActor static func available() -> [OpenTarget] {
        all.filter { $0.kind == .lazyVim || $0.kind == .finder || $0.applicationURL != nil }
    }

    @MainActor private static var icons: [String: NSImage] = [:]

    @MainActor var icon: NSImage {
        if let icon = Self.icons[id] { return icon }
        let icon: NSImage
        switch kind {
        case .lazyVim: icon = NSImage(systemSymbolName: "terminal", accessibilityDescription: title) ?? NSImage()
        case .finder:
            icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder").map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSImage(systemSymbolName: "folder", accessibilityDescription: title) ?? NSImage()
        case .app:
            icon = applicationURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSImage(systemSymbolName: "app", accessibilityDescription: title) ?? NSImage()
        }
        Self.icons[id] = icon
        return icon
    }
}

/// T3 Code/Codex-style project actions shown while the review panel is hidden:
/// open the checkout elsewhere, switch local branches and jump to changes.
struct ProjectActionsPanel: View, Equatable {
    let projectID: UUID
    let checkout: String
    let branch: String
    let branches: [String]
    let diffStat: DiffStat?
    let changeCount: Int
    /// An agent working in this checkout could be writing files; switching under it is unsafe.
    let agentRunning: Bool
    var floating = true
    let store: AppStore
    let review: ReviewModel
    let openChanges: () -> Void

    @AppStorage("OctoOpenTarget") private var preferredTarget = "lazyvim"
    /// Filled on appear: an initial value here would query Launch Services on every parent render.
    @State private var targets: [OpenTarget] = []
    @State private var choosingBranch = false
    @Environment(\.octoTheme) private var theme

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.projectID == rhs.projectID && lhs.checkout == rhs.checkout && lhs.branch == rhs.branch
            && lhs.branches == rhs.branches && lhs.diffStat == rhs.diffStat && lhs.changeCount == rhs.changeCount
            && lhs.agentRunning == rhs.agentRunning && lhs.floating == rhs.floating
            && lhs.store === rhs.store && lhs.review === rhs.review
    }

    private var target: OpenTarget { targets.first { $0.id == preferredTarget } ?? targets.first ?? OpenTarget.all[0] }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "folder").frame(width: 18)
                Text((checkout as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
            }.foregroundStyle(theme.secondary).padding(.horizontal, 8).padding(.vertical, 6)
                .help((checkout as NSString).abbreviatingWithTildeInPath)
            splitRow {
                open(target)
            } label: {
                Image(nsImage: target.icon).resizable().interpolation(.high).frame(width: 16, height: 16).frame(width: 18)
                Text("Open in \(target.title)").lineLimit(1)
            } menu: {
                ForEach(targets) { item in
                    Button { preferredTarget = item.id; open(item) } label: {
                        Label { Text(item.title) } icon: { Image(nsImage: item.icon.resized(to: 16)) }
                    }
                }
            }.help("Open this checkout in \(target.title)")
            Divider().padding(.vertical, 5)
            Button { choosingBranch.toggle() } label: {
                HStack(spacing: 8) {
                    GitBranchIcon(size: 15).frame(width: 18)
                    Text(branch.isEmpty ? "No branch" : branch).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(HoverButtonStyle())
                .help("Switch branch").accessibilityLabel("Branch \(branch). Switch branch")
                .popover(isPresented: $choosingBranch, arrowEdge: .bottom) {
                    BranchPicker(current: branch, branches: branches, agentRunning: agentRunning,
                                 load: { await review.loadBranches(projectID: projectID, root: checkout) },
                                 switchTo: { name in try await review.switchBranch(name, projectID: projectID, root: checkout) },
                                 dismiss: { choosingBranch = false })
                }
            Button(action: openChanges) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.forwardslash.minus").frame(width: 18)
                    Text("Changes")
                    Spacer(minLength: 8)
                    if let diffStat {
                        Text("+\(diffStat.additions)").foregroundStyle(theme.green)
                        Text("−\(diffStat.deletions)").foregroundStyle(theme.red)
                    } else if changeCount > 0 {
                        Text("\(changeCount) files").foregroundStyle(theme.secondary)
                    }
                }.font(.system(size: 13).monospacedDigit()).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(HoverButtonStyle()).help("Show changes in the review panel")
                .accessibilityValue(diffStat.map { "\($0.additions) lines added, \($0.deletions) removed" } ?? "\(changeCount) files")
        }
        .font(.system(size: 13))
        .padding(floating ? 8 : 10)
        .frame(width: 260)
        .background {
            if floating {
                RoundedRectangle(cornerRadius: 14).fill(theme.panel)
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.border.opacity(0.6)))
            }
        }
        // Apps may be installed or removed while Octo runs.
        .onAppear { targets = OpenTarget.available() }
    }

    private func splitRow<Label: View, Items: View>(action: @escaping () -> Void, @ViewBuilder label: () -> Label,
                                                    @ViewBuilder menu: () -> Items) -> some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 8) { label() }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(HoverButtonStyle())
            Rectangle().fill(theme.border).frame(width: 1, height: 16).padding(.horizontal, 2)
            ChevronMenu { menu() }.help("Choose where to open").accessibilityLabel("Choose where to open")
        }
    }

    private func open(_ target: OpenTarget) {
        let url = URL(fileURLWithPath: checkout, isDirectory: true)
        switch target.kind {
        case .lazyVim:
            store.openCheckoutInEditor(projectID: projectID, directory: checkout)
        case .finder:
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
        case .app:
            guard let application = target.applicationURL else {
                store.error = "\(target.title) is no longer installed."; targets = OpenTarget.available(); return
            }
            let store = store, title = target.title
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard let error else { return }
                Task { @MainActor in store.error = "Could not open in \(title): \(error.localizedDescription)" }
            }
        }
    }
}

/// A dropdown arrow whose whole highlighted box opens the menu.
struct ChevronMenu<Items: View>: View {
    let items: Items
    init(@ViewBuilder items: () -> Items) { self.items = items() }
    var body: some View {
        Menu {
            items
        } label: {
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }.hoverMenuStyle(padded: false).fixedSize()
    }
}

/// Searchable local branches. Arrow keys move the highlight; Return switches.
private struct BranchPicker: View {
    let current: String
    let branches: [String]
    let agentRunning: Bool
    let load: () async -> Void
    let switchTo: (String) async throws -> Void
    let dismiss: () -> Void
    @State private var query = ""
    @State private var highlighted = 0
    @State private var switching: String?
    @State private var error: String?
    @FocusState private var searchFocused: Bool
    @Environment(\.octoTheme) private var theme

    private var matches: [String] {
        let list = query.isEmpty ? branches : branches.filter { $0.localizedStandardContains(query) }
        // The checked-out branch leads, like the other recent branches it is sorted with.
        return list.filter { $0 == current } + list.filter { $0 != current }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.secondary)
                TextField("Search branches…", text: $query).textFieldStyle(.plain).focused($searchFocused)
                    .onSubmit { if matches.indices.contains(highlighted) { choose(matches[highlighted]) } }
            }.padding(.horizontal, 8).padding(.vertical, 7)
            Divider()
            if agentRunning {
                Text("Stop the agent working in this checkout before switching branches.")
                    .font(.system(size: 12)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(theme.red).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled).padding(.horizontal, 8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if matches.isEmpty {
                            Text(branches.isEmpty ? "Loading branches…" : "No matching branches")
                                .foregroundStyle(theme.secondary).padding(8)
                        }
                        ForEach(Array(matches.enumerated()), id: \.element) { index, name in
                            Button { choose(name) } label: {
                                HStack {
                                    Text(name).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    if name == current { Text("current").font(.system(size: 11)).foregroundStyle(theme.secondary) }
                                    if switching == name { ProgressView().controlSize(.small) }
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(HoverButtonStyle(selected: index == highlighted))
                                .disabled(switching != nil || (agentRunning && name != current))
                                .id(name)
                        }
                    }
                }.frame(height: min(300, max(44, CGFloat(matches.count) * 30)))
                    .onChange(of: highlighted) { _, index in
                        if matches.indices.contains(index) { proxy.scrollTo(matches[index]) }
                    }
            }
        }
        .font(.system(size: 13)).padding(10).frame(width: 280)
        .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(0, matches.count - 1)); return .handled }
        .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .task { searchFocused = true; await load() }
    }

    private func choose(_ name: String) {
        guard name != current else { dismiss(); return }
        guard !agentRunning, switching == nil else { return }
        switching = name; error = nil
        Task {
            do { try await switchTo(name); switching = nil; dismiss() }
            catch {
                switching = nil
                self.error = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}

private extension NSImage {
    /// Menu items draw images at their natural size; app icons are 512 pt or larger.
    func resized(to side: CGFloat) -> NSImage {
        let source = self
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            source.draw(in: rect); return true
        }
    }
}

/// The conventional Git branch glyph (trunk, two commits, a fork curve), as used by
/// GitHub, VS Code and most Git clients. SF Symbols has no equivalent.
struct GitBranchIcon: View {
    var size: CGFloat = 15
    var body: some View {
        Path { path in
            // 24-unit grid; the fork is a quarter circle centred on (9, 9).
            path.move(to: CGPoint(x: 6, y: 3)); path.addLine(to: CGPoint(x: 6, y: 15))
            path.addEllipse(in: CGRect(x: 3, y: 15, width: 6, height: 6))
            path.addEllipse(in: CGRect(x: 15, y: 3, width: 6, height: 6))
            path.move(to: CGPoint(x: 18, y: 9))
            path.addCurve(to: CGPoint(x: 9, y: 18), control1: CGPoint(x: 18, y: 13.97), control2: CGPoint(x: 13.97, y: 18))
        }
        .applying(CGAffineTransform(scaleX: size / 24, y: size / 24))
        .stroke(style: StrokeStyle(lineWidth: size / 12, lineCap: .round, lineJoin: .round))
        .frame(width: size, height: size).accessibilityHidden(true)
    }
}
