import Foundation

/// A tab in a project's review panel. Every tab closes; with none open the panel offers surfaces to open.
/// File paths are checkout-relative, so open files follow the selected thread's checkout.
public enum PanelTab: Hashable, Codable, Sendable {
    case changes
    /// The file tree with no file open. The first file opened from it takes its place.
    case files
    case file(String)
    case browser(UUID)
    public var path: String? { if case .file(let path) = self { return path }; return nil }
    public var browserID: UUID? { if case .browser(let id) = self { return id }; return nil }
}

/// The open panel tabs of one project, in display order.
public struct PanelTabs: Codable, Equatable, Sendable {
    public private(set) var tabs: [PanelTab] = [.changes]
    /// `nil` exactly when no tab is open.
    public private(set) var selected: PanelTab? = .changes
    /// The single-click file tab that the next single click replaces; editing or double-clicking keeps it.
    public private(set) var preview: String?
    public var showsFileTree = true
    /// Last committed address per browser tab, restored on relaunch.
    public private(set) var browserAddresses: [UUID: String] = [:]
    /// Private tabs use a non-persistent website data store and are never saved.
    public private(set) var privateBrowsers: Set<UUID> = []
    private var lastFile: String?
    private var lastBrowser: UUID?

    public init() {}

    public var browsers: [UUID] { tabs.compactMap(\.browserID) }
    public var files: [String] { tabs.compactMap(\.path) }
    public var selectedFile: String? { selected?.path }
    public var selectedBrowser: UUID? { selected?.browserID }
    /// The selected tab shows the file tree: a file tab or the Files tab.
    public var isBrowsingFiles: Bool { selected == .files || selectedFile != nil }
    /// The selected tab shows Changes or Files content rather than a browser or the surface picker.
    public var showsReview: Bool { selected != nil && selectedBrowser == nil }

    public mutating func select(_ tab: PanelTab) {
        guard tabs.contains(tab) else { return }
        selected = tab
        if let path = tab.path { lastFile = path }
        if let id = tab.browserID { lastBrowser = id }
    }
    public mutating func showChanges() {
        if !tabs.contains(.changes) { tabs.append(.changes) }
        select(.changes)
    }
    /// Shows the file tree beside the most recently viewed file, or opens the Files tab.
    public mutating func showFiles() {
        showsFileTree = true
        if isBrowsingFiles { return }
        if let lastFile, tabs.contains(.file(lastFile)) { select(.file(lastFile)) }
        else if let file = files.last { select(.file(file)) }
        else {
            if !tabs.contains(.files) { tabs.append(.files) }
            select(.files)
        }
    }
    /// The most recently viewed browser tab, if any is open.
    public var recentBrowser: UUID? {
        if let lastBrowser, tabs.contains(.browser(lastBrowser)) { return lastBrowser }
        return browsers.last
    }

    public mutating func openFile(_ path: String, pinned: Bool) {
        let tab = PanelTab.file(path)
        if tabs.contains(tab) {
            if pinned && preview == path { preview = nil }
        } else if !pinned, let current = preview, let index = tabs.firstIndex(of: .file(current)) {
            tabs[index] = tab; preview = path
            if lastFile == current { lastFile = nil }
        } else if let index = tabs.firstIndex(of: .files) {
            tabs[index] = tab
            if !pinned { preview = path }
        } else {
            tabs.append(tab)
            if !pinned { preview = path }
        }
        select(tab)
    }
    public mutating func pin(_ path: String) { if preview == path { preview = nil } }

    public mutating func openBrowser(_ id: UUID, address: String? = nil, isPrivate: Bool = false) {
        guard !tabs.contains(.browser(id)) else { select(.browser(id)); return }
        tabs.append(.browser(id))
        if isPrivate { privateBrowsers.insert(id) } else if let address, !address.isEmpty { browserAddresses[id] = address }
        select(.browser(id))
    }
    public mutating func recordAddress(_ address: String, for id: UUID) {
        guard tabs.contains(.browser(id)), !privateBrowsers.contains(id), !address.isEmpty else { return }
        browserAddresses[id] = address
    }

    /// Closes a tab and selects its right neighbor, else its left, else nothing.
    @discardableResult public mutating func close(_ tab: PanelTab) -> Bool {
        guard let index = tabs.firstIndex(of: tab) else { return false }
        tabs.remove(at: index)
        if let path = tab.path {
            if preview == path { preview = nil }
            if lastFile == path { lastFile = nil }
        }
        if let id = tab.browserID {
            browserAddresses[id] = nil; privateBrowsers.remove(id)
            if lastBrowser == id { lastBrowser = nil }
        }
        if selected == tab {
            if tabs.isEmpty { selected = nil } else { select(tabs[min(index, tabs.count - 1)]) }
        }
        return true
    }

    public mutating func selectAdjacent(_ offset: Int) {
        guard !tabs.isEmpty else { return }
        let index = selected.flatMap { tabs.firstIndex(of: $0) } ?? 0
        select(tabs[((index + offset) % tabs.count + tabs.count) % tabs.count])
    }

    private enum CodingKeys: String, CodingKey { case tabs, selected, preview, showsFileTree, browserAddresses }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        var tabs: [PanelTab] = []
        // Drop duplicates and unknown future cases rather than failing the whole archive.
        for tab in (try? values.decodeIfPresent([LossyTab].self, forKey: .tabs))?.compactMap(\.tab) ?? [] where !tabs.contains(tab) { tabs.append(tab) }
        self.tabs = tabs
        let selected = try? values.decodeIfPresent(PanelTab.self, forKey: .selected)
        self.selected = selected.flatMap { tabs.contains($0) ? $0 : nil } ?? tabs.first
        let preview = try? values.decodeIfPresent(String.self, forKey: .preview)
        self.preview = preview.flatMap { tabs.contains(.file($0)) ? $0 : nil }
        showsFileTree = (try? values.decodeIfPresent(Bool.self, forKey: .showsFileTree)) ?? true
        let addresses = (try? values.decodeIfPresent([UUID: String].self, forKey: .browserAddresses)) ?? [:]
        browserAddresses = addresses.filter { tabs.contains(.browser($0.key)) }
        lastFile = self.selected?.path; lastBrowser = self.selected?.browserID
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        let saved = tabs.filter { $0.browserID.map { !privateBrowsers.contains($0) } ?? true }
        try values.encode(saved, forKey: .tabs)
        try values.encodeIfPresent(selected.flatMap { saved.contains($0) ? $0 : saved.first }, forKey: .selected)
        try values.encodeIfPresent(preview, forKey: .preview)
        try values.encode(showsFileTree, forKey: .showsFileTree)
        try values.encode(browserAddresses, forKey: .browserAddresses)
    }
    private struct LossyTab: Decodable {
        let tab: PanelTab?
        init(from decoder: Decoder) throws { tab = try? PanelTab(from: decoder) }
    }
}
