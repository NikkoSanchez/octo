import AppKit
import GhosttyKit

/// An outstanding engine request is resolved once, including when its tab closes.
@MainActor final class GhosttyClipboardRequest {
    let id = UUID()
    private var completion: ((Bool) -> Void)?
    private var alert: NSAlert?
    init(completion: @escaping (Bool) -> Void) { self.completion = completion }
    func present(in window: NSWindow, title: String, message: String) {
        guard completion != nil else { return }
        guard window.attachedSheet == nil else { resolve(allow: false); return }
        let alert = NSAlert()
        self.alert = alert
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Allow Once")
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.resolve(allow: response == .alertSecondButtonReturn)
        }
    }
    func resolve(allow: Bool) {
        guard let completion else { return }
        self.completion = nil
        if let alert, let parent = alert.window.sheetParent { parent.endSheet(alert.window) }
        alert = nil
        completion(allow)
    }
}

enum GhosttyClipboard {
    static let limit = 8 * 1024 * 1024
    struct Content { let mime: String; let bytes: Data }
    // Ghostty 1.3.1 provides NUL-terminated UTF-8, not binary payload lengths.
    // Bound the scan and copy while the callback's borrowed memory is valid.
    static func text(_ pointer: UnsafePointer<CChar>?, limit: Int = limit) -> String? {
        guard let pointer, limit >= 0 else { return nil }
        let count = strnlen(pointer, limit + 1)
        guard count <= limit else { return nil }
        return String(bytes: UnsafeRawBufferPointer(start: pointer, count: count), encoding: .utf8)
    }
    static func copy(_ pointer: UnsafePointer<ghostty_clipboard_content_s>?, count: Int) -> [Content]? {
        guard count <= 32, count >= 0, count == 0 || pointer != nil else { return nil }
        var size = 0
        var result: [Content] = []
        for item in UnsafeBufferPointer(start: pointer, count: count) {
            guard let mime = text(item.mime, limit: 256), let value = text(item.data, limit: limit - size) else { return nil }
            let bytes = Data(value.utf8)
            size += bytes.count
            result.append(Content(mime: mime, bytes: bytes))
        }
        return result
    }
    @MainActor static func board(_ kind: ghostty_clipboard_e) -> NSPasteboard? {
        switch kind {
        case GHOSTTY_CLIPBOARD_STANDARD: return .general
        case GHOSTTY_CLIPBOARD_SELECTION: return NSPasteboard(name: .init("com.octo.terminal.selection"))
        default: return nil
        }
    }
    @MainActor static func pasteText(_ board: NSPasteboard) -> String? {
        if let urls = board.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            let text = urls.map { $0.isFileURL ? GhosttyInput.shellQuotedPath($0.path) : $0.absoluteString }.joined(separator: " ")
            return text.utf8.count <= limit ? text : nil
        }
        guard let value = board.string(forType: .string), value.utf8.count <= limit else { return nil }
        return value
    }
    // The full embedding API invokes clipboard callbacks on the UI thread.
    // Complete reads synchronously so borrowed state is never left untracked.
    static let read: ghostty_runtime_read_clipboard_cb = { pointer, kind, state in
        MainActor.assumeIsolated {
            guard let context = GhosttySurfaceContext.from(pointer), !context.isClosed,
                  let session = context.session, let surface = session.surface,
                  let board = board(kind), let value = pasteText(board), !value.utf8.contains(0) else { return false }
            complete(surface, state: state, text: value, confirmed: false)
            return true
        }
    }
    static let confirm: ghostty_runtime_confirm_read_clipboard_cb = { pointer, payload, state, kind in
        MainActor.assumeIsolated {
            guard let context = GhosttySurfaceContext.from(pointer), let session = context.session,
                  let surface = session.surface else { return }
            guard !context.isClosed, let value = text(payload) else {
                complete(surface, state: state, text: "", confirmed: true); return
            }
            let title = kind == GHOSTTY_CLIPBOARD_REQUEST_PASTE ? "Paste this text into the terminal?" : "Allow this program to read the clipboard?"
            ask(session, title: title, message: "The terminal requested clipboard access. Allowing applies to this request only.\n\n" + String(value.prefix(500))) { [weak session] allow in
                guard let surface = session?.surface else { return }
                // 1.3.1 has no deny API. Complete with empty text to consume the
                // request without disclosing/pasting its contents. For OSC 52
                // this sends an empty response; for paste it performs no input.
                // confirmed suppresses another prompt for that empty response.
                complete(surface, state: state, text: allow ? value : "", confirmed: true)
            }
        }
    }
    static let write: ghostty_runtime_write_clipboard_cb = { pointer, kind, contents, count, confirmation in
        MainActor.assumeIsolated {
            guard let context = GhosttySurfaceContext.from(pointer), !context.isClosed, let session = context.session,
                  let board = board(kind), let copied = copy(contents, count: count),
                  let text = copied.first(where: { $0.mime == "text/plain" }), let value = String(data: text.bytes, encoding: .utf8) else { return }
            let write = { [weak session] (allow: Bool) in
                guard allow, session?.isClosed == false else { return }
                board.clearContents(); board.setString(value, forType: .string)
            }
            if confirmation { ask(session, title: "Allow this program to replace the clipboard?", message: String(value.prefix(500)), completion: write) }
            else { write(true) }
        }
    }
    @MainActor private static func ask(_ session: GhosttySession, title: String, message: String, completion: @escaping (Bool) -> Void) {
        // One prompt per surface; deny requests from hidden tabs or while another
        // sheet is active. In particular, never auto-approve unsafe multiline paste.
        guard session.clipboardRequests.isEmpty, session.isSurfaceVisible, let window = session.view?.window, window.attachedSheet == nil else { completion(false); return }
        var id = UUID()
        let request = GhosttyClipboardRequest { [weak session] allow in
            session?.clipboardRequests.removeValue(forKey: id)
            completion(allow)
        }
        id = request.id
        session.clipboardRequests[id] = request
        DispatchQueue.main.async { [weak session] in
            guard session?.isClosed == false, session?.isSurfaceVisible == true else { request.resolve(allow: false); return }
            request.present(in: window, title: title, message: message)
        }
    }
    @MainActor private static func complete(_ surface: ghostty_surface_t, state: UnsafeMutableRawPointer?, text: String, confirmed: Bool) {
        text.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, confirmed) }
    }
}
