import AppKit
import SwiftUI
import OctoCore

struct AppCommand: Identifiable {
    /// Badged while ⌘ is held. Every other shortcut is in its control's tooltip: badging all of them crowded the window.
    static let heldHints: Set<String> = ["newThread", "chats", "sidebar", "terminal", "review"]
    let id: String
    let title: String
    let group: String
    var key: String? = nil
    var modifiers: NSEvent.ModifierFlags = [.command]
    var enabled = true
    var terminalAllowed = true
    var terminalRequired = false
    /// Shown for a key another component owns, such as a Ghostty binding; Octo does not route it.
    var hint: String? = nil
    let action: () -> Void
    var shortcut: String {
        guard let key else { return hint ?? "" }
        return (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "") + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "") + (key == "\r" ? "↩" : key.uppercased())
    }
    func isAvailable(inTerminal: Bool) -> Bool { enabled && (!inTerminal || terminalAllowed) && (inTerminal || !terminalRequired) }
    func matches(_ event: NSEvent) -> Bool {
        guard let key else { return false }
        // Ignore Caps Lock and device flags, but never steal Control/Option combinations.
        return event.modifierFlags.intersection([.command, .shift, .option, .control]) == modifiers && (event.characters(byApplyingModifiers: [])?.lowercased() == key || event.charactersIgnoringModifiers?.lowercased() == key)
    }
}
struct WorkspaceCommandContext {
    var commands: [AppCommand]
    var terminalVisible: Bool
}
private struct WorkspaceCommandsKey: FocusedValueKey { typealias Value = WorkspaceCommandContext }
extension FocusedValues {
    var workspaceCommands: WorkspaceCommandContext? {
        get { self[WorkspaceCommandsKey.self] }
        set { self[WorkspaceCommandsKey.self] = newValue }
    }
}
struct WorkspaceCommandMenu: Commands {
    @FocusedValue(\.workspaceCommands) private var context
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            command("newThread", title: "New Thread", key: "n")
            Button("New Chat Without a Project") { context?.commands.first { $0.id == "newChat" }?.action() }
                .disabled(context?.commands.first { $0.id == "newChat" }?.enabled != true)
            command("addProject", title: "Add Project…", key: "o", modifiers: [.command, .shift])
        }
        CommandMenu("Workspace") {
            ForEach(["Navigate", "Panels", "Conversation", "Review", "Terminal"], id: \.self) { group in
                Section(group) {
                    ForEach((context?.commands ?? []).filter { $0.group == group }) { item in
                        if let key = item.key, let character = key.first {
                            Button(item.title, action: item.action)
                                .keyboardShortcut(KeyEquivalent(character), modifiers: eventModifiers(item.modifiers))
                                .disabled(!item.isAvailable(inTerminal: context?.terminalVisible == true))
                        } else { Button(item.title, action: item.action).disabled(!item.enabled) }
                    }
                }
            }
        }
    }
    private func command(_ id: String, title: String, key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View {
        Button(title) { context?.commands.first { $0.id == id }?.action() }
            .keyboardShortcut(key, modifiers: modifiers)
            .disabled(context?.commands.first { $0.id == id }?.enabled != true)
    }
    private func eventModifiers(_ value: NSEvent.ModifierFlags) -> EventModifiers {
        var result: EventModifiers = []
        if value.contains(.command) { result.insert(.command) }
        if value.contains(.option) { result.insert(.option) }
        if value.contains(.shift) { result.insert(.shift) }
        if value.contains(.control) { result.insert(.control) }
        return result
    }
}

/// A local, window-scoped monitor runs before Ghostty's performKeyEquivalent.
/// Unmatched keys and modal dialogs keep their native responder behavior.
struct WorkspaceKeyRouter: NSViewRepresentable {
    var commands: [AppCommand]
    var terminalVisible: Bool
    var hintsChanged: (Bool) -> Void
    func makeNSView(context: Context) -> KeyRoutingView { KeyRoutingView() }
    func updateNSView(_ view: KeyRoutingView, context: Context) {
        view.commands = commands; view.terminalVisible = terminalVisible; view.hintsChanged = hintsChanged
    }
    static func dismantleNSView(_ view: KeyRoutingView, coordinator: ()) { view.stop() }
}
/// One reveal per uninterrupted Command hold. Shortcut use suppresses that hold.
@MainActor final class ShortcutHintHold {
    static let delay: TimeInterval = 0.65
    private var commandDown = false
    private var pendingReveal: DispatchWorkItem?
    private var generation = 0
    private let schedule: (TimeInterval, DispatchWorkItem) -> Void
    var changed: (Bool) -> Void = { _ in }
    var canReveal: () -> Bool = { true }

    init(schedule: @escaping (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }) { self.schedule = schedule }

    func update(commandDown: Bool, keyDown: Bool) {
        guard commandDown else { reset(); return }
        let began = !self.commandDown
        self.commandDown = true
        if keyDown {
            cancelReveal(); changed(false)
        } else if began {
            let token = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.generation == token, self.commandDown, self.canReveal() else { return }
                self.pendingReveal = nil
                self.changed(true)
            }
            pendingReveal = work
            schedule(Self.delay, work)
        }
    }

    func reset() {
        commandDown = false
        cancelReveal(); changed(false)
    }
    private func cancelReveal() {
        generation += 1
        pendingReveal?.cancel(); pendingReveal = nil
    }
    deinit { pendingReveal?.cancel() }
}

final class KeyRoutingView: NSView {
    var commands: [AppCommand] = []
    var terminalVisible = false
    var hintsChanged: ((Bool) -> Void)?
    private var hintsVisible = false
    private var resignObserver: NSObjectProtocol?
    private var sheetObserver: NSObjectProtocol?
    private var monitor: Any?
    private let hintHold = ShortcutHintHold()
    private func showHints(_ visible: Bool) {
        guard hintsVisible != visible else { return }
        hintsVisible = visible; hintsChanged?(visible)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); stop()
        guard window != nil else { return }
        hintHold.changed = { [weak self] in self?.showHints($0) }
        hintHold.canReveal = { [weak self] in
            guard let window = self?.window else { return false }
            return window.isKeyWindow && window.attachedSheet == nil && NSApp.modalWindow == nil && NSEvent.modifierFlags.contains(.command)
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hintHold.reset() }
        }
        sheetObserver = NotificationCenter.default.addObserver(forName: NSWindow.willBeginSheetNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hintHold.reset() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, let window = self.window,
                  (event.window === window || event.type == .flagsChanged),
                  window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil else {
                self?.hintHold.reset(); return event
            }
            self.hintHold.update(commandDown: event.modifierFlags.contains(.command), keyDown: event.type == .keyDown)
            guard event.type == .keyDown,
                  let command = Self.command(for: event, in: self.commands, terminalVisible: self.terminalVisible) else { return event }
            // Reserve unavailable app commands too; don't leak them to a shell.
            if command.enabled { command.action() }
            return nil
        }
    }
    /// Terminal and panel commands may share a key; the visible surface's command wins.
    static func command(for event: NSEvent, in commands: [AppCommand], terminalVisible: Bool) -> AppCommand? {
        commands.first { $0.matches(event) && ($0.terminalAllowed || !terminalVisible) && (!$0.terminalRequired || terminalVisible) }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; resignObserver = nil
        if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }; sheetObserver = nil
        hintHold.reset()
        showHints(false)
    }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }
    }
}

enum PaletteMode: String, Identifiable {
    case chats, projects, commands, files
    var id: String { rawValue }
    var placeholder: String {
        switch self {
        case .chats: return "Search all chats…"
        case .projects: return "Switch project by name or path…"
        case .commands: return "Type a command…"
        case .files: return "Find a project file…"
        }
    }
}
struct PaletteEntry: Identifiable {
    let id: String
    let title: String
    let detail: String
    var shortcut: String = ""
    var enabled = true
    let action: () -> Void
}
struct CommandPalette: View {
    let mode: PaletteMode
    let entries: [PaletteEntry]
    /// Ranks entry IDs for a non-empty query off the main thread, as chat search does.
    /// Without it, every word must appear in an entry's title or detail.
    var search: ((String) async -> [String])? = nil
    let dismiss: () -> Void
    let activateEntry: (PaletteEntry) -> Void
    @Environment(\.octoTheme) private var theme
    @State private var query = ""
    @State private var selected = 0
    /// Found once per query rather than on every read in the body; the field never waits on it.
    @State private var matches: [PaletteEntry]
    init(mode: PaletteMode, entries: [PaletteEntry], search: ((String) async -> [String])? = nil,
         dismiss: @escaping () -> Void, activateEntry: @escaping (PaletteEntry) -> Void) {
        self.mode = mode; self.entries = entries; self.search = search
        self.dismiss = dismiss; self.activateEntry = activateEntry
        _matches = State(initialValue: entries)
    }
    private func updateMatches() async {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var found = entries
        if let search, !words.isEmpty {
            let ids = await search(query)
            guard !Task.isCancelled else { return }
            let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            found = ids.compactMap { byID[$0] }
        } else if !words.isEmpty {
            found = entries.filter { entry in words.allSatisfy { (entry.title + " " + entry.detail).localizedStandardContains($0) } }
        }
        matches = found; selected = 0
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: mode == .commands ? "command" : mode == .projects ? "folder" : "magnifyingglass").foregroundStyle(theme.accent)
                SearchInputField(placeholder: mode.placeholder, text: $query,
                                   move: move, submit: activate, cancel: dismiss)
                    .frame(height: 32)
                Button("Esc", action: dismiss).buttonStyle(.plain).foregroundStyle(theme.secondary)
            }.padding(18)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, entry in
                            Button { selected = index; activate() } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.title).font(.system(size: 14, weight: .medium))
                                        Text(entry.detail).font(.system(size: 12)).foregroundStyle(theme.secondary).lineLimit(2)
                                    }
                                    Spacer()
                                    Text(entry.shortcut).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(11)
                                    .background(index == selected ? theme.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(!entry.enabled).opacity(entry.enabled ? 1 : 0.45).id(entry.id)
                        }
                        if matches.isEmpty {
                            Text(mode == .projects && entries.isEmpty ? "No projects yet. Add one with ⇧⌘O." : "No results")
                                .foregroundStyle(theme.secondary).padding(35)
                        }
                    }.padding(10)
                }.frame(height: 350)
                    .onChange(of: selected) { _, value in
                        if matches.indices.contains(value) { proxy.scrollTo(matches[value].id) }
                    }
                    .onChange(of: matches.map(\.id)) { _, ids in
                        if let first = ids.first { proxy.scrollTo(first) }
                    }
            }
            Divider()
            HStack { Text("↑ ↓ to navigate · Return to open · Esc to close"); Spacer(); Text("\(matches.count) results") }
                .font(.system(size: 11)).foregroundStyle(theme.secondary).padding(12)
        }.frame(width: 640).background(theme.background)
            .task(id: query) { await updateMatches() }
    }
    private func move(_ delta: Int) { guard !matches.isEmpty else { return }; selected = (selected + delta + matches.count) % matches.count }
    private func activate() {
        guard matches.indices.contains(selected), matches[selected].enabled else { return }
        activateEntry(matches[selected])
    }
}
struct SearchInputField: NSViewRepresentable {
    let placeholder: String
    var focusRequest: Int = 0
    var autofocus = true
    var identifier: String? = nil
    /// Borderless text with no search icon, for a field drawn inside a glass capsule.
    var plain = false
    @Binding var text: String
    let move: (Int) -> Void
    let submit: () -> Void
    let cancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(); field.placeholderString = placeholder; field.delegate = context.coordinator
        field.focusRingType = .none
        field.identifier = identifier.map { NSUserInterfaceItemIdentifier($0) }
        if plain {
            field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
            field.font = .systemFont(ofSize: 13.5)
            if let cell = field.cell as? NSSearchFieldCell { cell.searchButtonCell = nil; cell.cancelButtonCell = nil }
        }
        context.coordinator.focusRequest = focusRequest
        if autofocus { DispatchQueue.main.async { field.window?.makeFirstResponder(field) } }
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if autofocus && context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var focusRequest: Int?
        var parent: SearchInputField
        init(_ parent: SearchInputField) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) { if let field = obj.object as? NSSearchField { parent.text = field.stringValue } }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.submit()
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            default: return false
            }
            return true
        }
    }
}

/// Focus mounted native editors immediately, before another key event can reach
/// a terminal that SwiftUI is in the process of hiding.
@MainActor enum NativeWorkspaceFocus {
    static func focus(_ identifier: String) {
        guard let window = NSApp?.keyWindow else { return }
        func find(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == identifier { return view }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        if let root = window.contentView, let target = find(root) { window.makeFirstResponder(target) }
    }
    static func clear() { NSApp?.keyWindow?.makeFirstResponder(nil) }
}

private struct ShortcutHintsKey: EnvironmentKey { static let defaultValue: [String: String] = [:] }
extension EnvironmentValues {
    var shortcutHints: [String: String] {
        get { self[ShortcutHintsKey.self] }
        set { self[ShortcutHintsKey.self] = newValue }
    }
}
/// `leading` sits beside the control, for a button whose neighbor's badge already takes the space above.
enum ShortcutHintPlacement { case above, leading }
private struct ShortcutHint: ViewModifier {
    @Environment(\.shortcutHints) private var hints
    @Environment(\.octoTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    let command: String
    let active: Bool
    let placement: ShortcutHintPlacement
    func body(content: Content) -> some View {
        content.overlay(alignment: placement == .above ? .topTrailing : .leading) {
            if active, enabled, let shortcut = hints[command] {
                Text(shortcut.map(String.init).joined(separator: " ")).font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.foreground).padding(.horizontal, 5).padding(.vertical, 3)
                    .background(theme.panel, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.border))
                    .fixedSize()
                    // Align the badge's bottom above the control, leaving a real gap.
                    .alignmentGuide(.top) { $0[.bottom] + 6 }
                    // Leading: a zero-width frame at the control's edge lets the badge extend left of it.
                    .frame(width: placement == .leading ? 0 : nil, alignment: .trailing)
                    .offset(x: placement == .leading ? -4 : 0)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}
extension View {
    func shortcutHint(_ command: String, active: Bool = true, placement: ShortcutHintPlacement = .above) -> some View {
        modifier(ShortcutHint(command: command, active: active, placement: placement))
    }
}
