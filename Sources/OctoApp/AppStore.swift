import AppKit
import SwiftUI
import OctoCore
import OctoGit
import OctoAgents
import OctoTerminal

@MainActor final class AppStore: ObservableObject {
    @Published private(set) var codexExecutablePath: String?
    @Published private(set) var codexConfigurationID = UUID()
    @Published private(set) var codexVersion = "Checking version…"
    private let preferences: UserDefaults
    private static let codexPathKey = "codexExecutablePath"
    var codexExecutable: URL? { CodexExecutable.resolve(customPath: codexExecutablePath) }
    var harnessDescriptors: [HarnessDescriptor] {
        HarnessRegistry.descriptors.map { descriptor in
            var descriptor = descriptor
            if descriptor.id == .codex { descriptor.executable = codexExecutable }
            if descriptor.id == .codex && !CodexHarness.supportsAutoReview(version: codexVersion) {
                descriptor.permissionOptions.removeAll { $0.mode == .autoReview }
            }
            return descriptor
        }
    }
    var codexIsRunning: Bool {
        archive.projects.flatMap(\.threads).contains { $0.harness == .codex && running.contains($0.id) }
    }
    @Published var theme: AppTheme = .system {
        didSet {
            preferences.set(theme.rawValue, forKey: "appearanceTheme")
            if !terminal.applyTheme(theme) { error = "Some terminal colors could not be updated. Your terminal processes are still running." }
        }
    }
    @Published var composerFocus = 0
    @Published var findingThread = false
    @Published var threadQuery = ""
    @Published var findStep = 0
    @Published var findFocus = 0
    @Published var sidebarEdit: SidebarEdit?
    @Published var closingTerminal: UUID?
    @Published var archive = WorkspaceArchive()
    @Published var showingTerminal = false {
        didSet { if oldValue != showingTerminal { NativeWorkspaceFocus.clear() } }
    }
    @Published var showingReview = false
    @Published var modelCatalogs: [String: [AgentModel]] = [:]
    @Published var modelErrors: [String: String] = [:]
    @Published var loadingModels = Set<String>()
    @Published var usageSnapshots: [String: AgentUsage] = [:]
    @Published var usageErrors: [String: String] = [:]
    @Published var loadingUsage = Set<String>()
    @Published var error: String?
    @Published var drafts: [UUID: String] = [:]
    @Published var draftImages: [UUID: [ImageAttachment]] = [:]
    @Published var attachments: [UUID: [CodeAttachment]] = [:]
    @Published var running = Set<UUID>()
    @Published var approvals: [UUID: [AgentApproval]] = [:]
    let terminal = TerminalWorkspace()
    let git = GitService()
    private let storage: WorkspaceStore
    private var canSave = true
    private var harnesses: [UUID: any AgentHarness] = [:]
    private var saveTask: Task<Void, Never>?
    var project: WorkspaceProject? { archive.projects.first { $0.id == archive.selectedProjectID } }
    var thread: WorkspaceThread? { project?.threads.first { $0.id == archive.selectedThreadID } }
    init(storage: WorkspaceStore = .standard, preferences: UserDefaults = .standard) {
        self.storage = storage; self.preferences = preferences
        theme = AppTheme(rawValue: preferences.string(forKey: "appearanceTheme") ?? "") ?? .system
        terminal.applyTheme(theme)
        codexExecutablePath = preferences.string(forKey: Self.codexPathKey)
        do { archive = try storage.load() } catch { self.error = "Could not load workspace: \(error.localizedDescription)\nThe existing file will not be overwritten."; canSave = false }
        if archive.rememberedAgentSettings == nil, let thread {
            archive.lastHarness = thread.harness
            archive.rememberedAgentSettings = [thread.harness.rawValue: thread.agentSettings]
        }
    }
    func saveSoon() {
        guard canSave else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.saveNow()
        }
    }
    func saveNow() {
        guard canSave else { return }
        do { try storage.save(archive) } catch { self.error = "Could not save workspace: \(error.localizedDescription)" }
    }
    func chooseProject() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = "Add Project"; panel.message = "Choose a local Git repository."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await addProject(url) }
    }
    func addProject(_ url: URL) async {
        do {
            let root = try await git.repositoryRoot(url.path)
            if let existing = archive.projects.first(where: { $0.rootPath == root }) { selectProject(existing); return }
            let project = WorkspaceProject(name: URL(fileURLWithPath: root).lastPathComponent, rootPath: root)
            archive.projects.append(project); selectProject(project); newThread()
        } catch { self.error = "Could not add project: \(error.localizedDescription)" }
    }
    func selectProject(_ project: WorkspaceProject) {
        archive.selectedProjectID = project.id; archive.selectedThreadID = project.orderedThreads.first?.id; showingTerminal = false; saveSoon()
    }
    func selectThread(_ thread: WorkspaceThread, project: WorkspaceProject) {
        NativeWorkspaceFocus.clear()
        archive.selectedProjectID = project.id; archive.selectedThreadID = thread.id; showingTerminal = false; composerFocus += 1; saveSoon()
    }
    func openTerminal(_ project: WorkspaceProject) {
        archive.selectedProjectID = project.id
        if !project.threads.contains(where: { $0.id == archive.selectedThreadID }) { archive.selectedThreadID = project.orderedThreads.first?.id }
        terminal.ensureTab(projectID: project.id, directory: project.rootPath); showingTerminal = true; saveSoon()
    }
    func focusComposer() { showingTerminal = false; composerFocus += 1; NativeWorkspaceFocus.focus("OctoComposer") }
    private func rememberedSettings(for harness: HarnessID) -> AgentSettings {
        archive.rememberedAgentSettings?[harness.rawValue]
            ?? (thread?.harness == harness ? thread?.agentSettings : nil) ?? AgentSettings()
    }
    private func rememberAgentChoices() {
        guard let thread else { return }
        archive.lastHarness = thread.harness
        if archive.rememberedAgentSettings == nil { archive.rememberedAgentSettings = [:] }
        archive.rememberedAgentSettings?[thread.harness.rawValue] = thread.agentSettings
        saveSoon()
    }
    func newThread(harness requestedHarness: HarnessID? = nil, projectID: UUID? = nil) {
        guard let p = archive.projects.firstIndex(where: { $0.id == (projectID ?? archive.selectedProjectID) }) else { return }
        let harness = requestedHarness ?? archive.lastHarness ?? thread?.harness ?? .codex
        let settings = rememberedSettings(for: harness)
        NativeWorkspaceFocus.clear()
        // Reopen the project's unfinished composer, including text and attachments.
        // Existing duplicate drafts remain intact; this action never creates more.
        let candidates = archive.projects[p].threads.filter {
            $0.messages.isEmpty && $0.remoteSessionID == nil && !running.contains($0.id)
        }
        let existing = candidates.first { $0.id == archive.selectedThreadID } ?? candidates.last
        let id: UUID
        if let existing {
            id = existing.id
            let hasDraft = !(drafts[id] ?? "").isEmpty || !(draftImages[id] ?? []).isEmpty || !(attachments[id] ?? []).isEmpty
            if requestedHarness != nil || !hasDraft {
                mutate(id) { $0.harness = harness; $0.agentSettings = settings }
            }
        } else {
            var thread = WorkspaceThread(harness: harness, workingDirectory: archive.projects[p].rootPath)
            thread.agentSettings = settings
            archive.projects[p].threads.append(thread); id = thread.id
        }
        archive.projects[p].isCollapsed = false
        archive.selectedProjectID = archive.projects[p].id
        archive.selectedThreadID = id; showingTerminal = false; composerFocus += 1; saveSoon()
    }
    func toggleProjectPin(_ id: UUID) {
        guard let p = archive.projects.firstIndex(where: { $0.id == id }) else { return }
        archive.projects[p].isPinned.toggle(); saveSoon()
    }
    func toggleProjectCollapse(_ id: UUID) {
        guard let p = archive.projects.firstIndex(where: { $0.id == id }) else { return }
        archive.projects[p].isCollapsed.toggle(); saveSoon()
    }
    func toggleThreadPin(_ id: UUID) { mutate(id) { $0.isPinned.toggle() } }
    func renameProject(_ id: UUID, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let p = archive.projects.firstIndex(where: { $0.id == id }) else { return }
        archive.projects[p].name = name; saveSoon()
    }
    func renameThread(_ id: UUID, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        mutate(id) { $0.title = title }
    }
    func deleteThread(_ id: UUID, projectID: UUID) {
        guard !running.contains(id) else { error = "Stop the running agent before deleting this thread."; return }
        harnesses.removeValue(forKey: id)?.shutdown()
        drafts[id] = nil; draftImages[id] = nil; attachments[id] = nil; approvals[id] = nil
        archive.removeThread(id, projectID: projectID); saveSoon()
    }
    func removeProject(_ id: UUID) {
        guard let project = archive.projects.first(where: { $0.id == id }) else { return }
        guard !project.threads.contains(where: { running.contains($0.id) }), !terminal.tabs.contains(where: { $0.projectID == id }) else {
            error = "Stop this project's agents and close its terminal tabs before removing it."; return
        }
        for thread in project.threads { deleteThread(thread.id, projectID: id) }
        archive.removeProject(id)
        if archive.selectedProjectID == nil { showingTerminal = false }
        saveSoon()
    }
    func changeHarness(_ harness: HarnessID) {
        guard let thread, !running.contains(thread.id) else { return }
        if thread.harness == harness { return }
        rememberAgentChoices()
        if thread.messages.isEmpty && thread.remoteSessionID == nil {
            let settings = rememberedSettings(for: harness)
            mutate(thread.id) { $0.harness = harness; $0.agentSettings = settings }
        }
        else { newThread(harness: harness) }
        rememberAgentChoices()
    }
    func chooseCodexExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.showsHiddenFiles = true
        panel.prompt = "Use Codex"; panel.message = "Choose the Codex executable."
        if let executable = codexExecutable { panel.directoryURL = executable.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setCodexExecutable(path: url.path)
    }
    func setCodexExecutable(path: String?) {
        guard !codexIsRunning else { error = "Stop running Codex turns before changing its executable."; return }
        if let path, CodexExecutable.executable(at: path) == nil {
            error = "Choose an executable file using an absolute path."; return
        }
        // Idle connections must be recreated with the same binary used by discovery.
        for thread in archive.projects.flatMap(\.threads) where thread.harness == .codex {
            harnesses.removeValue(forKey: thread.id)?.shutdown()
        }
        codexExecutablePath = path
        if let path { preferences.set(path, forKey: Self.codexPathKey) }
        else { preferences.removeObject(forKey: Self.codexPathKey) }
        codexConfigurationID = UUID(); codexVersion = "Checking version…"
        modelCatalogs.removeAll(); modelErrors.removeAll(); loadingModels.removeAll()
        usageSnapshots.removeAll(); usageErrors.removeAll(); loadingUsage.removeAll()
    }
    func refreshCodexVersion() async {
        let configuration = codexConfigurationID
        guard let executable = codexExecutable else { codexVersion = "Executable not found"; return }
        do {
            let version = try await CodexExecutable.version(of: executable)
            guard configuration == codexConfigurationID else { return }
            codexVersion = version.isEmpty ? "Version unavailable" : version
        } catch {
            if configuration == codexConfigurationID { codexVersion = "Version unavailable: \(error.localizedDescription)" }
        }
    }
    func loadModels(directory: String, refresh: Bool = false) async {
        guard !loadingModels.contains(directory), refresh || modelCatalogs[directory] == nil else { return }
        let configuration = codexConfigurationID
        loadingModels.insert(directory); modelErrors[directory] = nil
        defer { if configuration == codexConfigurationID { loadingModels.remove(directory) } }
        do {
            guard let executable = codexExecutable else { throw ProcessFailure.missing("Codex executable (choose one in Settings)") }
            let models = try await CodexHarness.models(directory: directory, executable: executable)
            guard configuration == codexConfigurationID else { return }
            modelCatalogs[directory] = models
        } catch {
            if configuration == codexConfigurationID { modelErrors[directory] = "Could not load Codex models: \(error.localizedDescription)" }
        }
    }
    func selectModel(_ model: AgentModel) {
        guard let thread, thread.harness == .codex, !running.contains(thread.id) else { return }
        mutate(thread.id) {
            let previous = $0.agentSettings.reasoningEffort
            $0.agentSettings = AgentSettings(model: model.model, reasoningEffort:
                model.supportedReasoningEfforts.contains { $0.reasoningEffort == previous } ? previous : model.defaultReasoningEffort,
                permissionMode: $0.agentSettings.permissionMode)
        }
        rememberAgentChoices()
    }
    func selectPermissions(_ mode: AgentPermissionMode, threadID: UUID) {
        guard let thread, thread.id == threadID, !running.contains(thread.id),
              harnessDescriptors.first(where: { $0.id == thread.harness })?.permissionOptions.contains(where: { $0.mode == mode }) == true else { return }
        mutate(thread.id) { $0.agentSettings.permissionMode = mode }
        rememberAgentChoices()
    }
    func usageKey(_ thread: WorkspaceThread) -> String { "\(thread.harness.rawValue):\(thread.workingDirectory)" }
    func loadUsage(_ thread: WorkspaceThread) async {
        let key = usageKey(thread), configuration = codexConfigurationID
        guard !loadingUsage.contains(key) else { return }
        loadingUsage.insert(key); usageErrors[key] = nil
        defer { if configuration == codexConfigurationID { loadingUsage.remove(key) } }
        do {
            if thread.harness == .codex && codexExecutable == nil { throw ProcessFailure.missing("Codex executable") }
            let usage = try await HarnessRegistry.usage(thread.harness, directory: thread.workingDirectory, codexExecutable: codexExecutable)
            guard configuration == codexConfigurationID else { return }
            usageSnapshots[key] = usage
        } catch {
            if configuration == codexConfigurationID { usageErrors[key] = "Usage unavailable: \(error.localizedDescription)" }
        }
    }
    func selectReasoning(_ effort: String) {
        guard let thread, thread.harness == .codex, !running.contains(thread.id),
              let model = modelCatalogs[thread.workingDirectory]?.first(where: { $0.model == thread.agentSettings.model }),
              model.supportedReasoningEfforts.contains(where: { $0.reasoningEffort == effort }) else { return }
        mutate(thread.id) { $0.agentSettings.reasoningEffort = effort }
        rememberAgentChoices()
    }
    /// Returns true when the pasteboard contains an image, even if rejected, so it
    /// cannot silently fall through to a text/file-path paste.
    @discardableResult func pasteScreenshot(from pasteboard: NSPasteboard, threadID: UUID) -> Bool {
        guard let type = pasteboard.availableType(from: [.png, .tiff]) else { return false }
        guard let owner = archive.projects.flatMap(\.threads).first(where: { $0.id == threadID }) else { return true }
        guard owner.harness == .codex else { error = "Screenshot attachments currently require Codex."; return true }
        guard (draftImages[threadID]?.count ?? 0) < 4 else { error = "You can attach up to four screenshots per message."; return true }
        guard let data = pasteboard.data(forType: type), data.count <= 30 * 1_024 * 1_024,
              let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
              Double(bitmap.pixelsWide) * Double(bitmap.pixelsHigh) <= 32_000_000,
              let png = bitmap.representation(using: .png, properties: [:]), png.count <= 5 * 1_024 * 1_024 else {
            error = "Could not attach this image. Use a smaller screenshot (up to 5 MB as PNG and 32 megapixels)."; return true
        }
        draftImages[threadID, default: []].append(ImageAttachment(pngData: png))
        return true
    }
    func canSend(_ thread: WorkspaceThread) -> Bool {
        !(drafts[thread.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(draftImages[thread.id] ?? []).isEmpty
    }
    func attach(_ attachment: CodeAttachment) {
        guard let project, project.id == attachment.projectID else { return }
        if thread == nil { newThread() }
        guard let thread, thread.workingDirectory == attachment.workingDirectory else { error = "This selection belongs to a different checkout."; return }
        attachments[thread.id, default: []].append(attachment); showingTerminal = false
    }
    func openInEditor(_ snapshot: ReviewSnapshot, selection: CodeAttachment?) {
        Task {
            do {
                try await terminal.openInEditor(projectID: snapshot.projectID, directory: snapshot.workingDirectory, relativePath: snapshot.path, line: selection?.newLines?.lowerBound ?? 1)
                showingTerminal = true
            } catch { self.error = error.localizedDescription }
        }
    }
    func send() {
        guard let thread, !running.contains(thread.id) else { return }
        if let mode = thread.agentSettings.permissionMode,
           harnessDescriptors.first(where: { $0.id == thread.harness })?.permissionOptions.contains(where: { $0.mode == mode }) != true {
            error = "The saved permission mode is unavailable with this CLI. Choose a supported mode before sending."; return
        }
        let images = draftImages[thread.id] ?? []
        if !images.isEmpty {
            guard thread.harness == .codex else { error = "Screenshot attachments currently require Codex. Remove them or switch providers."; return }
            if let model = modelCatalogs[thread.workingDirectory]?.first(where: { $0.model == thread.agentSettings.model }), !model.supportsImages {
                error = "This model does not support images. Choose an image-capable model or remove the screenshots."; return
            }
        }
        if thread.harness == .codex && codexExecutable == nil {
            error = "Codex executable not found. Choose an installation in Settings."; return
        }
        if thread.harness == .codex, let modelID = thread.agentSettings.model,
           let catalog = modelCatalogs[thread.workingDirectory] {
            guard let model = catalog.first(where: { $0.model == modelID }) else {
                error = "The selected model is unavailable. Choose a model from the current catalog."; return
            }
            if let effort = thread.agentSettings.reasoningEffort,
               effort != model.defaultReasoningEffort && !model.supportedReasoningEfforts.contains(where: { $0.reasoningEffort == effort }) {
                error = "The selected reasoning effort is unavailable for this model. Choose a supported effort."; return
            }
        }
        let text = (drafts[thread.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let selections = attachments[thread.id] ?? []
        guard !text.isEmpty || !images.isEmpty else { return }
        let id = thread.id
        let prompt = text + (selections.isEmpty ? "" : "\n\nSelected code context (captured snapshots):\n" + selections.map(\.promptContext).joined(separator: "\n\n"))
        mutate(id) {
            if $0.messages.isEmpty && $0.title == "New thread" { $0.title = text.isEmpty ? "Screenshot discussion" : String(text.prefix(52)) }
            $0.messages.append(ChatMessage(role: .user, text: text, attachments: selections, images: images))
        }
        drafts[id] = ""; attachments[id] = []; draftImages[id] = []; running.insert(id)
        let harness: any AgentHarness
        if let existing = harnesses[id] { harness = existing } else {
            harness = HarnessRegistry.make(thread.harness, codexExecutable: codexExecutable); harnesses[id] = harness
            harness.onEvent = { [weak self] event in self?.handle(event, threadID: id) }
        }
        Task {
            do { try await harness.send(prompt: prompt, sessionID: thread.remoteSessionID, directory: thread.workingDirectory, settings: thread.agentSettings, images: images) }
            catch { handle(.failed(error.localizedDescription), threadID: id) }
        }
    }
    func stop(_ id: UUID) { Task { await harnesses[id]?.interrupt() } }
    func handle(_ event: AgentEvent, threadID: UUID) {
        guard archive.projects.contains(where: { $0.threads.contains(where: { $0.id == threadID }) }) else { return }
        switch event {
        case .session(let remoteID): mutate(threadID) { $0.remoteSessionID = remoteID }
        case .textDelta(let text): mutate(threadID) {
            if $0.messages.last?.role == .assistant { $0.messages[$0.messages.count - 1].text += text }
            else { $0.messages.append(ChatMessage(role: .assistant, text: text)) }
        }
        case .message(let text): mutate(threadID) { $0.messages.append(ChatMessage(role: .assistant, text: text)) }
        case .activity(let text): mutate(threadID) { $0.messages.append(ChatMessage(role: .activity, text: text)) }
        case .activityDelta(let text): mutate(threadID) {
            if $0.messages.last?.role == .activity { $0.messages[$0.messages.count - 1].text += text }
            else { $0.messages.append(ChatMessage(role: .activity, text: text)) }
        }
        case .reasoningDelta(let text): mutate(threadID) {
            if $0.messages.last?.role == .reasoning { $0.messages[$0.messages.count - 1].text += text }
            else { $0.messages.append(ChatMessage(role: .reasoning, text: text)) }
        }
        case .usage(let usage):
            if let owner = archive.projects.flatMap(\.threads).first(where: { $0.id == threadID }) {
                let key = usageKey(owner)
                var buckets = usageSnapshots[key]?.buckets ?? []
                for bucket in usage.buckets {
                    buckets.removeAll { $0.id == bucket.id }; buckets.append(bucket)
                }
                var merged = usage; merged.buckets = buckets.sorted { $0.id < $1.id }
                usageSnapshots[key] = merged
            }
        case .failed(let text):
            running.remove(threadID); approvals[threadID] = []
            mutate(threadID) { $0.messages.append(ChatMessage(role: .error, text: text)) }
        case .finished: running.remove(threadID); approvals[threadID] = []; saveSoon()
        case .approval(let approval): approvals[threadID, default: []].append(approval)
        case .approvalResolved(let id): approvals[threadID]?.removeAll { $0.id == id }
        }
    }
    func answer(_ approval: AgentApproval, threadID: UUID, allow: Bool) {
        approval.respond(allow); approvals[threadID]?.removeAll { $0.id == approval.id }
    }
    private func mutate(_ id: UUID, _ update: (inout WorkspaceThread) -> Void) {
        for p in archive.projects.indices {
            if let t = archive.projects[p].threads.firstIndex(where: { $0.id == id }) {
                update(&archive.projects[p].threads[t]); saveSoon(); return
            }
        }
    }
    func shutdown() { saveTask?.cancel(); saveNow(); harnesses.values.forEach { $0.shutdown() } }
}

struct SidebarEdit: Identifiable {
    enum Kind { case rename, remove }
    let id = UUID()
    let projectID: UUID
    var threadID: UUID?
    let kind: Kind
}
