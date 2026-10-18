import SwiftUI
import OctoCore
import OctoReview

struct FileAction: Identifiable {
    enum Kind { case create, delete }
    let id = UUID()
    let kind: Kind
    let projectID: UUID
    let root: String
    let path: String
}

/// Lives with AppStore, so navigation and closing a window cannot discard a draft.
@MainActor final class FileEditorWorkspace {
    private struct Key: Hashable { let root: String; let path: String }
    private var sessions: [Key: FileEditorSession] = [:]
    var hasUnsavedChanges: Bool { sessions.values.contains { $0.isDirty } }
    var isSaving: Bool { sessions.values.contains { $0.busy } }
    func session(for snapshot: ReviewSnapshot) -> FileEditorSession {
        let key = Key(root: snapshot.workingDirectory, path: snapshot.path)
        if let session = sessions[key] { session.context = snapshot; return session }
        let session = FileEditorSession(context: snapshot)
        sessions[key] = session
        return session
    }
    func dirtyPaths(root: String) -> [String] { sessions.filter { $0.key.root == root && $0.value.isDirty }.map { $0.key.path } }
    func existing(root: String, path: String) -> FileEditorSession? { sessions[Key(root: root, path: path)] }
    func remove(root: String, path: String) {
        sessions.removeValue(forKey: Key(root: root, path: path))?.close()
    }
}

@MainActor final class FileEditorSession: ObservableObject, Identifiable {
    let id = UUID()
    var context: ReviewSnapshot
    @Published var text = "" {
        didSet { if !loadingText && !text.utf8.elementsEqual(oldValue.utf8) { revision += 1; scheduleSave() } }
    }
    @Published private(set) var file: CheckoutFile?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private let service = CheckoutFileService()
    private var pendingSave: Task<Void, Never>?
    private var revision = 0
    private var loadingText = false
    private var loading = false
    private var suspended = false
    private var editors: [UUID: NativeFileEditorState] = [:]
    var didSave: (() async -> Void)?
    let autosaveDelay: UInt64
    var isDirty: Bool { file != nil && !text.utf8.elementsEqual((file?.text ?? "").utf8) }
    var canSave: Bool { isDirty && !busy && !suspended }
    init(context: ReviewSnapshot, autosaveDelay: UInt64 = 500_000_000) {
        self.context = context; self.autosaveDelay = autosaveDelay
    }
    func editorState(for window: UUID) -> NativeFileEditorState {
        if let state = editors[window] { return state }
        let state = NativeFileEditorState(); editors[window] = state; return state
    }
    /// Clean buffers follow disk on refresh; dirty buffers keep their original save baseline.
    func load(discardChanges: Bool = false) async {
        guard !busy, !loading, discardChanges || !isDirty else { return }
        pendingSave?.cancel(); loading = true
        let version = revision
        defer { loading = false }
        do {
            let value = try await service.inspect(path: context.path, root: context.workingDirectory, forEditing: true)
            guard version == revision else { return }
            loadingText = true
            file = value; text = value.text ?? ""; error = nil
            loadingText = false
        } catch { self.error = error.localizedDescription }
    }
    func save() async {
        guard canSave, let file else { return }
        pendingSave?.cancel(); pendingSave = nil
        let contents = text
        busy = true
        do {
            self.file = try await service.save(file, text: contents)
            error = nil
            busy = false
            // Typing remains enabled during IO. Save a newer draft in a subsequent write.
            if isDirty { scheduleSave() }
            await didSave?()
        } catch { self.error = error.localizedDescription; busy = false }
    }
    private func scheduleSave() {
        pendingSave?.cancel(); pendingSave = nil
        guard isDirty, !busy, !suspended, error == nil else { return }
        let delay = autosaveDelay
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.pendingSave = nil
            await self.save()
        }
    }
    func suspend() { suspended = true; pendingSave?.cancel(); pendingSave = nil }
    func close() { suspend(); editors.values.forEach { $0.clearUndoHistory() }; editors.removeAll() }
    func resume() { suspended = false; scheduleSave() }
    deinit { pendingSave?.cancel() }
}

@MainActor final class FileActionModel: ObservableObject {
    let action: FileAction
    var kind: FileAction.Kind { action.kind }
    @Published var path: String
    @Published private(set) var file: CheckoutFile?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private let service = CheckoutFileService()
    private let editors: FileEditorWorkspace
    var canPerform: Bool { !busy && (kind == .create ? !path.isEmpty && !path.hasSuffix("/") : file != nil) }
    init(_ action: FileAction, editors: FileEditorWorkspace? = nil) {
        self.action = action; self.editors = editors ?? FileEditorWorkspace(); path = action.path
    }
    func load() async {
        guard kind == .delete else { return }
        let session = editors.existing(root: action.root, path: path)
        session?.suspend()
        // Let an already-started save settle before capturing deletion's disk identity.
        busy = true; defer { busy = false }
        while session?.busy == true { try? await Task.sleep(nanoseconds: 10_000_000) }
        do { file = try await service.inspect(path: path, root: action.root, forEditing: false); error = nil }
        catch { self.error = error.localizedDescription }
    }
    func resumeEditor() { editors.existing(root: action.root, path: path)?.resume() }
    func perform(changed: (String) async -> Void) async -> Bool {
        guard canPerform else { return false }
        busy = true; defer { busy = false }
        do {
            switch kind {
            case .create: try await service.create(path: path, root: action.root)
            case .delete:
                guard let file else { return false }
                try await service.delete(file)
                editors.remove(root: action.root, path: path)
            }
            error = nil; await changed(path); return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

struct FileActionSheet: View {
    @ObservedObject var store: AppStore
    @StateObject private var model: FileActionModel
    @FocusState private var pathFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.octoTheme) private var theme
    let changed: (String) async -> Void
    init(action: FileAction, store: AppStore, changed: @escaping (String) async -> Void) {
        self.store = store; self.changed = changed
        _model = StateObject(wrappedValue: FileActionModel(action, editors: store.fileEditors))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.kind == .create ? "New File" : "Delete File?").font(.title2.bold())
            Text(model.action.root).font(.system(size: 12)).foregroundStyle(theme.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            if model.kind == .create {
                TextField("Relative file path", text: $model.path).textFieldStyle(.roundedBorder).focused($pathFocused)
                    .accessibilityLabel("New file path")
                Text("Use an existing folder, for example Sources/NewFile.swift.").font(.system(size: 12)).foregroundStyle(theme.secondary)
            } else {
                Text(model.path).font(.system(size: 13, weight: .medium, design: .monospaced)).textSelection(.enabled)
                Text("This permanently deletes the file from disk and discards its unsaved edits in Octo.").fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.error { Text(error).font(.system(size: 13)).foregroundStyle(theme.red).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                if model.kind == .delete {
                    Button("Delete File", role: .destructive) { perform() }.disabled(!model.canPerform)
                } else {
                    Button("Create") { perform() }.keyboardShortcut(.defaultAction).disabled(!model.canPerform)
                }
            }
        }.padding(20).frame(width: 460)
            .interactiveDismissDisabled(model.busy)
            .task { await model.load(); pathFocused = model.kind == .create }
            .onChange(of: model.busy) { _, busy in store.fileOperationInProgress = busy }
            .onDisappear { model.resumeEditor(); store.fileOperationInProgress = false }
    }
    private func perform() { Task { if await model.perform(changed: changed) { dismiss() } } }
}

struct InlineFilePane: View {
    @ObservedObject var session: FileEditorSession
    let windowID: UUID
    let theme: AppTheme
    let focusRequest: Int
    let revealLine: Int?
    let revealRequest: Int
    let onSelection: (CodeAttachment?) -> Void
    let onAskAgent: (CodeAttachment) -> Void
    var onEdit: () -> Void = {}
    @Environment(\.octoTheme) private var colors
    @State private var confirmingReload = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(session.context.path).lineLimit(1).truncationMode(.middle).help(session.context.path)
                Spacer(minLength: 4)
                Text(session.busy ? "Saving…" : session.error != nil && session.file != nil ? "Not saved" : session.isDirty ? "Unsaved" : session.file != nil ? "Saved" : "")
                    .foregroundStyle(colors.secondary)
                Button("Save") { Task { await session.save() } }.disabled(!session.canSave).help("Save file (⌘S)")
            }.font(.system(size: 12)).padding(9)
            if let error = session.error {
                HStack(alignment: .top) {
                    Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Reload") {
                        if session.isDirty { confirmingReload = true } else { Task { await session.load() } }
                    }.disabled(session.busy)
                }.font(.system(size: 12)).foregroundStyle(colors.red).padding(9)
            }
            Divider()
            if session.file != nil {
                NativeFileEditor(text: $session.text, context: session.context, state: session.editorState(for: windowID), theme: theme,
                    focusRequest: focusRequest, revealLine: revealLine, revealRequest: revealRequest,
                    onSelection: onSelection, onAskAgent: onAskAgent)
            } else if session.error == nil { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { Spacer() }
        }
        .onChange(of: session.isDirty) { _, dirty in if dirty { onEdit() } }
        .alert("Reload file from disk?", isPresented: $confirmingReload) {
            Button("Reload", role: .destructive) { Task { await session.load(discardChanges: true) } }
            Button("Keep Editing", role: .cancel) {}
        } message: { Text("Your unsaved edits to \(session.context.path) will be discarded.") }
    }
}
