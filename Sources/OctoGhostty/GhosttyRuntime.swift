import AppKit
import GhosttyKit

/// Process-lifetime runtime. The renderer/PTY threads belong to Ghostty; Octo owns
/// only the native host and drains the application mailbox on the main actor.
@MainActor final class GhosttyRuntime {
    static let shared: Result<GhosttyRuntime, Error> = Result { try GhosttyRuntime() }
    let app: ghostty_app_t
    let basePath: String?
    let initialDiagnostics: [String]
    private let wakeup = GhosttyWakeup()
    private var observations: [NSObjectProtocol] = []

    private init() throws {
        let resources: URL
        #if SWIFT_PACKAGE
        guard let bundled = Bundle.module.url(forResource: "Runtime", withExtension: nil) else {
            throw GhosttyFailure.message("Ghostty resources are missing. Rebuild Octo with Scripts/build-app.sh.")
        }
        resources = bundled
        #else
        // Used only by the independent native source-build smoke executable.
        guard let path = ProcessInfo.processInfo.environment["OCTO_GHOSTTY_RESOURCES"] else {
            throw GhosttyFailure.message("Set OCTO_GHOSTTY_RESOURCES for the standalone smoke host.")
        }
        resources = URL(fileURLWithPath: path)
        #endif
        let terminfo = resources.appendingPathComponent("terminfo/78/xterm-ghostty")
        guard FileManager.default.fileExists(atPath: terminfo.path) else {
            throw GhosttyFailure.message("The bundled Ghostty terminfo database is missing.")
        }
        setenv("GHOSTTY_RESOURCES_DIR", resources.appendingPathComponent("ghostty").path, 1)
        // Do not expose Octo's --project or test-runner arguments as Ghostty options.
        let name = strdup("octo")!
        defer { free(name) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [name, nil]
        let result = arguments.withUnsafeMutableBufferPointer { ghostty_init(1, $0.baseAddress) }
        guard result == GHOSTTY_SUCCESS else { throw GhosttyFailure.message("Ghostty initialization failed (\(result)).") }
        let configPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ghostty/config").path
        basePath = FileManager.default.fileExists(atPath: configPath) ? configPath : nil
        let config = try GhosttyConfiguration(path: basePath)
        initialDiagnostics = config.diagnostics
        var callbacks = ghostty_runtime_config_s()
        callbacks.userdata = Unmanaged.passUnretained(wakeup).toOpaque()
        callbacks.supports_selection_clipboard = true
        callbacks.wakeup_cb = { pointer in
            guard let pointer else { return }
            Unmanaged<GhosttyWakeup>.fromOpaque(pointer).takeUnretainedValue().signal()
        }
        callbacks.action_cb = GhosttyCallbacks.action
        callbacks.close_surface_cb = GhosttyCallbacks.close
        callbacks.read_clipboard_cb = GhosttyClipboard.read
        callbacks.confirm_read_clipboard_cb = GhosttyClipboard.confirm
        callbacks.write_clipboard_cb = GhosttyClipboard.write
        guard let handle = ghostty_app_new(&callbacks, config.handle) else {
            throw GhosttyFailure.message("Ghostty could not create its native runtime.")
        }
        app = handle
        wakeup.onTick = { [weak self] in
            guard let self else { return }
            ghostty_app_tick(self.app)
        }
        ghostty_app_set_focus(app, NSApp.isActive)
        let center = NotificationCenter.default
        for notification in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observations.append(center.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    ghostty_app_set_focus(self.app, NSApp.isActive)
                    self.wakeup.signal()
                }
            })
        }
        observations.append(center.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { ghostty_app_keyboard_changed(self.app) } }
        })
    }
}

/// Coalesce worker-thread wakeups without gating them on tab/app visibility.
/// This object outlives every C callback because the runtime lives until exit.
final class GhosttyWakeup: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled = false
    @MainActor var onTick: (() -> Void)?
    func signal() {
        lock.lock()
        if scheduled { lock.unlock(); return }
        scheduled = true
        lock.unlock()
        DispatchQueue.main.async { [self] in
            lock.lock(); scheduled = false; lock.unlock()
            onTick?()
        }
    }
}

/// Queued host events retain this token, never a raw surface handle. Closing a
/// session invalidates it before freeing C state, so late callbacks are inert.
@MainActor final class GhosttySurfaceContext {
    weak var session: GhosttySession?
    var isClosed = false
    init(_ session: GhosttySession) { self.session = session }
    nonisolated static func from(_ pointer: UnsafeMutableRawPointer?) -> GhosttySurfaceContext? {
        pointer.map { Unmanaged<GhosttySurfaceContext>.fromOpaque($0).takeUnretainedValue() }
    }
    nonisolated func enqueue(_ operation: @escaping @MainActor (GhosttySession) -> Void) {
        DispatchQueue.main.async { [self] in
            guard !isClosed, let session else { return }
            operation(session)
        }
    }
}

private enum GhosttyCallbacks {
    static let close: ghostty_runtime_close_surface_cb = { pointer, alive in
        GhosttySurfaceContext.from(pointer)?.enqueue { $0.requestClose(processAlive: alive) }
    }
    static let action: ghostty_runtime_action_cb = { _, target, action in
        if action.tag == GHOSTTY_ACTION_QUIT {
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return true
        }
        guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface,
              let context = GhosttySurfaceContext.from(ghostty_surface_userdata(surface)) else { return false }
        // Consume borrowed pointers before scheduling beyond the C callback.
        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            // The macOS Metal renderer presents its own layer. Do not schedule
            // another engine render in response to a completed frame.
            return true
        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_TAB_TITLE:
            return true // Octo owns the generic tab/editor labels.
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            context.enqueue { $0.markExited() }; return true
        case GHOSTTY_ACTION_RING_BELL:
            context.enqueue { _ in NSSound.beep() }; return true
        case GHOSTTY_ACTION_RENDERER_HEALTH:
            if action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_UNHEALTHY {
                context.enqueue { $0.report("The terminal renderer reported a problem. Try reopening this terminal tab.") }
            }
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            let item = action.action.open_url
            guard let pointer = item.url, item.len <= 32_768 else { return true }
            let value = String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(item.len)), as: UTF8.self)
            context.enqueue { session in
                guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) else {
                    session.report("This terminal link uses an unsupported URL scheme."); return
                }
                NSWorkspace.shared.open(url)
            }
            return true // Never fall back to an unvalidated engine-side /usr/bin/open.
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            context.enqueue { _ = $0.reloadConfiguration() }; return true
        case GHOSTTY_ACTION_SCROLLBAR, GHOSTTY_ACTION_COMMAND_FINISHED:
            context.enqueue { $0.view?.accessibilityTextChanged() }; return true
        case GHOSTTY_ACTION_PWD, GHOSTTY_ACTION_CELL_SIZE,
             GHOSTTY_ACTION_INITIAL_SIZE, GHOSTTY_ACTION_SIZE_LIMIT,
             GHOSTTY_ACTION_KEY_SEQUENCE, GHOSTTY_ACTION_KEY_TABLE, GHOSTTY_ACTION_PROGRESS_REPORT,
             GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_CONFIG_CHANGE,
             GHOSTTY_ACTION_MOUSE_OVER_LINK:
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            let shape = action.action.mouse_shape
            context.enqueue { $0.view?.setCursorShape(shape) }; return true
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            let hidden = action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN
            context.enqueue { session in if session.isSurfaceVisible { NSCursor.setHiddenUntilMouseMoves(hidden) } }; return true
        default:
            context.enqueue { $0.report("This Ghostty feature isn't available in Octo. Use Octo's workspace controls for tabs and windows.") }
            return false
        }
    }
}
