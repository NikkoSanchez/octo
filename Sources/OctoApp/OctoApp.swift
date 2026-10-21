import AppKit
import SwiftUI
import OctoCore
import OctoAgents
import OctoTerminal

@main struct OctoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppStore(storage: {
        // An isolated archive lets native smoke tests run without touching personal chats.
        if let path = ProcessInfo.processInfo.environment["OCTO_WORKSPACE_PATH"], !path.isEmpty {
            return WorkspaceStore(fileURL: URL(fileURLWithPath: path))
        }
        return .standard
    }())
    var body: some Scene {
        WindowGroup("Octo") {
            WorkspaceView(store: store)
                .modifier(ThemedContent(theme: store.theme))
                .frame(minWidth: 480, minHeight: 600)
                .onAppear { delegate.store = store }
                .task {
                    if let index = CommandLine.arguments.firstIndex(of: "--project"), CommandLine.arguments.count > index + 1 {
                        await store.addProject(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                    }
                }
        }
        .defaultSize(width: 1380, height: 880)
        // SwiftUI otherwise restores an opaque titlebar over the full-size content whenever the
        // colour scheme changes (every theme switch); this style keeps it transparent.
        .windowStyle(.hiddenTitleBar)
        .commands { WorkspaceCommandMenu() }
        Window("Usage", id: UsageDashboardWindow.id) {
            UsageDashboardView(store: store).modifier(ThemedContent(theme: store.theme)).frame(minWidth: 820, minHeight: 560)
        }.defaultSize(width: 1180, height: 860)
        Settings { SettingsView(store: store).frame(width: 680, height: 600).modifier(ThemedContent(theme: store.theme)) }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if store?.fileOperationInProgress == true || store?.fileEditors.isSaving == true { return .terminateCancel }
        if store?.hasUnsavedFileEdits == true {
            let alert = NSAlert(); alert.messageText = "Discard file changes and quit?"
            alert.informativeText = "Your unsaved file edits will be lost."
            alert.addButton(withTitle: "Discard and Quit"); alert.addButton(withTitle: "Keep Editing")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        if store?.running.isEmpty == false || store?.terminal.tabs.isEmpty == false {
            let alert = NSAlert(); alert.messageText = "Quit Octo?"; alert.informativeText = "Active agent connections and terminal processes will close. Saved chat history will remain."
            alert.addButton(withTitle: "Quit"); alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        store?.shutdown(); return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
struct SettingsView: View {
    @ObservedObject var store: AppStore
    @State private var loginSession: CLISetupSession?
    var body: some View {
        TabView {
            appearance.tabItem { Label("Appearance", systemImage: "paintpalette") }
            shortcuts.tabItem { Label("Keyboard", systemImage: "keyboard") }
            agents.tabItem { Label("Agents", systemImage: "terminal") }
        }.padding(16)
            .sheet(item: $loginSession, onDismiss: {
                store.claudeSetupClosed()
                Task { await store.refreshClaudeAuth() }
            }) { session in
                ClaudeSignInView(session: session, store: store) { loginSession = nil }
            }
    }
    private var appearance: some View {
        Form { ThemeGallery(selection: $store.theme) }.formStyle(.grouped).scrollContentBackground(.hidden)
    }
    private var shortcuts: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Keyboard first").font(.title2.bold())
                Text("⌘⇧P opens every workspace command, including project and thread management, agent choices, and draft attachments. Type to filter; use ↑ / ↓ and Return to run. Escape closes the palette.").foregroundStyle(store.theme.secondary)
                ForEach(Self.shortcutGroups, id: \.0) { group in
                    VStack(alignment: .leading, spacing: 14) {
                        Text(group.0).font(.headline)
                        ForEach(group.1, id: \.0) { row in
                            HStack(spacing: 24) { Text(row.0); Spacer(minLength: 20); Text(row.1).font(.system(.body, design: .monospaced)).foregroundStyle(store.theme.accent) }
                        }
                    }
                    Divider()
                }
                Text("Octo reserves the listed Command shortcuts in workspace windows, including when a terminal is focused. Control, Option-only, Vim leader keys, and Escape stay with the terminal. Copy, paste, undo, and text navigation stay native. In the composer, Return sends and Shift–Return inserts a new line. ⌘Return and ⌘. act on chat only outside the terminal. Approval buttons require an explicit choice; use Tab / Shift-Tab to focus controls (enable Keyboard navigation in macOS Settings).")
                    .font(.system(size: 12)).foregroundStyle(store.theme.secondary)
            }.padding(20)
        }
    }
    static let shortcutGroups: [(String, [(String, String)])] = [
        ("Navigate & create", [("Search chats", "⌘K"), ("Switch project", "⇧⌘K"), ("Find in current thread", "⌘F"), ("Next / previous matching message", "⌘G / ⇧⌘G"), ("New thread / add project", "⌘N / ⇧⌘O"), ("Find file / command palette", "⌘P / ⇧⌘P"), ("Previous / next thread", "⌥⌘[ / ⌥⌘]")]),
        ("Workspace", [("Toggle left sidebar / review panel", "⌘B / ⌥⌘B"), ("Focus composer / show changes / show files", "⌘1 / ⌘2 / ⌘3"), ("Focus code preview", "⌘4"), ("Toggle terminal", "⌘J"), ("Settings", "⌘,")]),
        ("Conversation & review", [("Send message / new line (composer)", "Return / ⇧Return"), ("Send message / stop agent", "⌘Return / ⌘."), ("Attach selected code to draft", "⇧⌘A"), ("Open selected file in LazyVim", "⇧⌘E"), ("Refresh changes and files", "⇧⌘R"), ("Save file now (also autosaves)", "⌘S")]),
        ("Terminal", [("New tab / close tab with confirmation", "⌘T / ⌘W"), ("Previous / next terminal tab", "⇧⌘[ / ⇧⌘]"), ("Split right / down (Ghostty)", "⌘D / ⇧⌘D"), ("Previous / next pane, or by direction", "⌘[ / ⌘], ⌥⌘ arrows"), ("Resize / equalize panes", "⌃⌘ arrows / ⌃⌘="), ("Zoom pane / close pane", "⇧⌘Return / ⌘W")])
    ]
    private var agents: some View {
        Form {
            Section("Agent harnesses") {
                ForEach(store.harnessDescriptors) { descriptor in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(descriptor.id.title).bold(); Spacer(); Text(descriptor.executable == nil ? "Not installed" : "Detected").foregroundStyle(descriptor.executable == nil ? store.theme.secondary : store.theme.green) }
                        Text(descriptor.detail).font(.system(size: 13)).foregroundStyle(store.theme.secondary)
                    }.padding(.vertical, 5)
                }
            }
            Section("Codex executable") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.codexExecutablePath == nil ? "Automatic · desktop app first, then PATH" : "Custom executable").font(.headline)
                    Text(store.codexExecutablePath ?? store.codexExecutable?.path ?? "Not found")
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text(store.codexVersion).font(.system(size: 13)).foregroundStyle(store.theme.secondary).textSelection(.enabled)
                    HStack {
                        Button("Choose Executable…") { store.chooseCodexExecutable() }
                        Button("Use Automatic") { store.setCodexExecutable(path: nil) }
                    }.disabled(store.codexIsRunning)
                    Text(store.codexIsRunning ? "Stop running Codex turns to change installations." : "The same installation supplies the model list and runs your turns. Changing it refreshes models; saved conversations remain.")
                        .font(.system(size: 12)).foregroundStyle(store.theme.secondary)
                }.padding(.vertical, 4)
            }
            Section("Claude CLI sign-in") {
                Text(Executables.find("claude")?.path ?? "Claude CLI not found")
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                Text(store.checkingClaudeAuth ? "Checking sign-in…" : store.claudeAuthStatus?.title ?? "Sign-in status unavailable")
                    .foregroundStyle(store.claudeAuthStatus?.loggedIn == true ? store.theme.green : store.theme.secondary)
                if let error = store.claudeAuthError { Text(error).font(.caption).foregroundStyle(store.theme.secondary) }
                HStack {
                    Button("Open CLI sign-in…") {
                        guard !store.claudeIsRunning, let executable = Executables.find("claude") else { return }
                        loginSession = CLISetupSession(executable: executable, arguments: ClaudeCLI.loginArguments,
                                                       directory: FileManager.default.homeDirectoryForCurrentUser.path)
                    }.disabled(Executables.find("claude") == nil || store.claudeIsRunning)
                    Button("Refresh status") { Task { await store.refreshClaudeAuth() } }.disabled(store.checkingClaudeAuth)
                    Link("Authentication guide", destination: URL(string: "https://code.claude.com/docs/en/authentication")!)
                }
                Text(store.claudeIsRunning ? "Stop Claude turns before signing in again." : "Opens the installed Claude CLI’s browser sign-in flow. Choose your account there; the CLI stores and refreshes its credentials.")
                    .font(.system(size: 13)).foregroundStyle(store.theme.secondary)
            }
            Section("CLI-owned integrations") {
                Text("Configure and authenticate integrations with your selected CLI, including in Octo’s terminal. Octo inherits its launch environment; shell-only variables may differ. Use the executable shown above and the same project. No credentials or MCP settings are copied into Octo.").font(.system(size: 13)).foregroundStyle(store.theme.secondary)
                Text("Missing tools, service connection failures, macOS permissions, app authorization, and unsupported forms are separate issues. Follow the owning CLI’s setup/login workflow; app approval does not repair a transport or OS permission failure.").font(.system(size: 13)).foregroundStyle(store.theme.secondary)
            }
            Section("Local workspace") { Text("Uses your installed CLI authentication and Neovim configuration. Terminal tabs survive navigation, but do not survive app exit.").font(.system(size: 13)).foregroundStyle(store.theme.secondary) }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
            .task(id: store.codexConfigurationID) { await store.refreshCodexVersion() }
            .task { await store.refreshClaudeAuth() }
    }
}

private struct ClaudeSignInView: View {
    @ObservedObject var session: CLISetupSession
    @ObservedObject var store: AppStore
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in through Claude CLI").font(.title2.bold())
            Text("Follow the CLI instructions and finish sign-in in your browser. If it asks for a code, paste it in the terminal below.")
                .font(.callout).foregroundStyle(store.theme.secondary)
            CLISetupTerminal(session: session).frame(minWidth: 560, minHeight: 340)
            HStack {
                Text(session.exited ? "CLI finished. Close to refresh sign-in status." : "Closing ends this sign-in process.")
                    .font(.caption).foregroundStyle(store.theme.secondary)
                Spacer()
                Button("Close") { session.close(); close() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 640, height: 480)
            .onChange(of: session.exited) { _, exited in if exited { Task { await store.refreshClaudeAuth() } } }
    }
}
