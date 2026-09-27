import AppKit
import SwiftUI

struct AppCommand: Identifiable {
    let id: String
    let title: String
    let group: String
    var key: String? = nil
    var modifiers: NSEvent.ModifierFlags = [.command]
    var enabled = true
    var terminalAllowed = true
    var terminalRequired = false
    let action: () -> Void
    var shortcut: String {
        guard let key else { return "" }
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
    func makeNSView(context: Context) -> KeyRoutingView { KeyRoutingView() }
    func updateNSView(_ view: KeyRoutingView, context: Context) {
        view.commands = commands; view.terminalVisible = terminalVisible
    }
    static func dismantleNSView(_ view: KeyRoutingView, coordinator: ()) { view.stop() }
}
final class KeyRoutingView: NSView {
    var commands: [AppCommand] = []
    var terminalVisible = false
    private var monitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil,
                  let command = self.commands.first(where: { $0.matches(event) }),
                  (command.terminalAllowed || !self.terminalVisible),
                  (!command.terminalRequired || self.terminalVisible) else { return event }
            // Reserve unavailable app commands too; don't leak them to a shell.
            if command.enabled { command.action() }
            return nil
        }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

enum PaletteMode: String, Identifiable { case chats, commands, files; var id: String { rawValue } }
struct PaletteEntry: Identifiable {
    let id: String
    let title: String
    let detail: String
    var searchText: String = ""
    var shortcut: String = ""
    var enabled = true
    let action: () -> Void
}
struct CommandPalette: View {
    let mode: PaletteMode
    let entries: [PaletteEntry]
    let dismiss: () -> Void
    @Environment(\.octoTheme) private var theme
    @State private var query = ""
    @State private var selected = 0
    private var matches: [PaletteEntry] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return entries.filter { entry in words.allSatisfy { (entry.title + " " + entry.detail + " " + entry.searchText).localizedStandardContains($0) } }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: mode == .commands ? "command" : "magnifyingglass").foregroundStyle(theme.accent)
                SearchInputField(placeholder: mode == .chats ? "Search chats across projects…" : mode == .files ? "Find a project file…" : "Type a command…", text: $query,
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
                            }.buttonStyle(.plain).disabled(!entry.enabled).opacity(entry.enabled ? 1 : 0.45).id(index)
                        }
                        if matches.isEmpty { Text("No results").foregroundStyle(theme.secondary).padding(35) }
                    }.padding(10)
                }.frame(height: 350)
                    .onChange(of: selected) { _, value in proxy.scrollTo(value) }
            }
            Divider()
            HStack { Text("↑ ↓ to navigate · Return to open · Esc to close"); Spacer(); Text("\(matches.count) results") }
                .font(.system(size: 11)).foregroundStyle(theme.secondary).padding(12)
        }.frame(width: 640).background(theme.background)
            .onChange(of: query) { _, _ in selected = 0 }
    }
    private func move(_ delta: Int) { guard !matches.isEmpty else { return }; selected = (selected + delta + matches.count) % matches.count }
    private func activate() {
        guard matches.indices.contains(selected), matches[selected].enabled else { return }
        let action = matches[selected].action
        dismiss()
        // Execute after SwiftUI removes the sheet (important for focus and dialogs).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { action() }
    }
}
struct SearchInputField: NSViewRepresentable {
    let placeholder: String
    var focusRequest: Int = 0
    var autofocus = true
    var identifier: String? = nil
    @Binding var text: String
    let move: (Int) -> Void
    let submit: () -> Void
    let cancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(); field.placeholderString = placeholder; field.delegate = context.coordinator
        field.focusRingType = .none
        field.identifier = identifier.map { NSUserInterfaceItemIdentifier($0) }
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
