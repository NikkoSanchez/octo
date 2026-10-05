import AppKit
import SwiftUI
import GhosttyKit

@MainActor public final class GhosttySession: ObservableObject {
    public let id = UUID()
    public let options: GhosttyLaunchOptions
    @Published public private(set) var notice: String?
    @Published public private(set) var processExited = false
    public private(set) var isClosed = false
    public var onClose: ((Bool) -> Void)?
    public var isSurfaceVisible = false {
        didSet { if oldValue != isSurfaceVisible { view?.synchronizeVisibility() } }
    }
    var surface: ghostty_surface_t?
    var view: GhosttyNativeView?
    private var runtime: GhosttyRuntime?
    private var context: GhosttySurfaceContext?
    private var colors: GhosttyColors?
    private var focusPending = false
    private var appearanceIsDark = false
    var clipboardRequests: [UUID: GhosttyClipboardRequest] = [:]

    public init(options: GhosttyLaunchOptions) { self.options = options }
    deinit {
        // Session ownership is MainActor; C teardown joins its owned workers.
        MainActor.assumeIsolated { close() }
    }

    func nativeView() -> GhosttyNativeView {
        if let view { return view }
        let created = GhosttyNativeView(session: self)
        view = created
        return created
    }

    func attach(to view: GhosttyNativeView) {
        guard !isClosed, surface == nil, view.window != nil else { return }
        do {
            let runtime = try GhosttyRuntime.shared.get()
            self.runtime = runtime
            let context = GhosttySurfaceContext(self)
            self.context = context
            var config = ghostty_surface_config_new()
            config.platform_tag = GHOSTTY_PLATFORM_MACOS
            config.platform.macos = ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(view).toOpaque())
            config.userdata = Unmanaged.passUnretained(context).toOpaque()
            config.scale_factor = Double(view.window?.backingScaleFactor ?? 1)
            config.font_size = options.fontSize
            config.wait_after_command = options.waitAfterCommand
            config.context = GHOSTTY_SURFACE_CONTEXT_TAB
            var strings: [UnsafeMutablePointer<CChar>] = []
            defer { strings.forEach { free($0) } }
            func cString(_ text: String) throws -> UnsafePointer<CChar> {
                guard !text.utf8.contains(0), let pointer = strdup(text) else { throw GhosttyFailure.message("Invalid terminal launch string.") }
                strings.append(pointer); return UnsafePointer(pointer)
            }
            config.working_directory = try cString(options.directory)
            if let command = options.command { config.command = try cString(command) }
            var environment: [ghostty_env_var_s] = try options.environment.sorted(by: { $0.key < $1.key }).map {
                guard !$0.key.isEmpty, !$0.key.contains("=") else { throw GhosttyFailure.message("Invalid terminal environment name.") }
                return try ghostty_env_var_s(key: cString($0.key), value: cString($0.value))
            }
            surface = environment.withUnsafeMutableBufferPointer {
                config.env_vars = $0.baseAddress; config.env_var_count = $0.count
                return ghostty_surface_new(runtime.app, &config)
            }
            guard surface != nil else { throw GhosttyFailure.message("Ghostty could not start this terminal.") }
            _ = reloadConfiguration()
            view.synchronizeMetrics()
            view.synchronizeVisibility()
            replayFocus()
        } catch { report(error.localizedDescription) }
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        focusPending = false
        context?.isClosed = true
        // Requests must be denied before their surface and request pointers die.
        let pending = Array(clipboardRequests.values)
        clipboardRequests.removeAll()
        pending.forEach { $0.resolve(allow: false) }
        if let surface {
            ghostty_surface_set_focus(surface, false)
            ghostty_surface_free(surface)
            self.surface = nil
        }
        view?.sessionClosed()
        context = nil
    }

    public func requestFocus() {
        guard !isClosed else { return }
        focusPending = true
        DispatchQueue.main.async { [weak self] in self?.replayFocus() }
    }
    func replayFocus() {
        guard focusPending, isSurfaceVisible, !isClosed, let view, let window = view.window,
              window.isKeyWindow, window.attachedSheet == nil else { return }
        focusPending = !window.makeFirstResponder(view)
    }
    public func setColors(_ colors: GhosttyColors?) -> Bool {
        do { _ = try colors?.rendered() } catch { report(error.localizedDescription); return false }
        guard self.colors != colors else { return true }
        self.colors = colors
        return reloadConfiguration()
    }
    @discardableResult func reloadConfiguration() -> Bool {
        guard !isClosed else { return false }
        guard let runtime, let surface else { return true }
        do {
            let configuration = try GhosttyConfiguration(path: runtime.basePath, colors: colors)
            ghostty_surface_update_config(surface, configuration.handle)
            setDarkAppearance(appearanceIsDark)
            report(configuration.diagnostics.isEmpty ? nil : configuration.diagnostics.joined(separator: "\n"))
            return configuration.diagnostics.isEmpty
        } catch { report(error.localizedDescription); return false }
    }
    func setDarkAppearance(_ value: Bool) {
        appearanceIsDark = value
        if let surface { ghostty_surface_set_color_scheme(surface, value ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT) }
    }
    func refresh() { if let surface, isSurfaceVisible, !isClosed { ghostty_surface_refresh(surface) } }
    func requestClose(processAlive: Bool) {
        guard !isClosed else { return }
        // Natural exit and an explicit close binding are distinct. The host UI
        // must ask before ending a live process, just as the tab's close button does.
        if processAlive {
            guard isSurfaceVisible, let window = view?.window, window.attachedSheet == nil else { return }
            let alert = NSAlert()
            alert.messageText = "Close this terminal?"
            alert.informativeText = "Closing ends the shell and programs running in this tab."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Close Terminal")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertSecondButtonReturn else { return }
                self?.markExited(); self?.close()
            }
        } else {
            markExited()
        }
    }
    func markExited() {
        guard !processExited else { return }
        processExited = true
        onClose?(false)
    }
    func report(_ text: String?) {
        // Creation, resize, and theme changes can run inside updateNSView.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isClosed, self.notice != text else { return }
            self.notice = text
        }
    }
    public func dismissNotice() { notice = nil }

    /// Read-only text for accessibility and native lifecycle checks.
    public func visibleText() -> String {
        guard let surface, !isClosed else { return "" }
        var selection = ghostty_selection_s()
        selection.top_left = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        selection.bottom_right = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        var result = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &result) else { return "" }
        defer { ghostty_surface_free_text(surface, &result) }
        guard let text = result.text else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: text, count: Int(result.text_len)), as: UTF8.self)
    }
}

/// The session retains its native view across SwiftUI updates and detach/reattach.
public struct GhosttyTerminalSurface: View {
    @ObservedObject var session: GhosttySession
    public init(session: GhosttySession) { self.session = session }
    public var body: some View {
        ZStack(alignment: .top) {
            GhosttyRepresentable(session: session)
            if let notice = session.notice {
                HStack(alignment: .top) {
                    Text(notice).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button { session.dismissNotice() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("Dismiss terminal notice")
                }.padding(8).background(.regularMaterial)
            }
        }
    }
}
private struct GhosttyRepresentable: NSViewRepresentable {
    let session: GhosttySession
    func makeNSView(context: Context) -> GhosttyNativeView { session.nativeView() }
    func updateNSView(_ view: GhosttyNativeView, context: Context) { view.synchronizeVisibility() }
    static func dismantleNSView(_ view: GhosttyNativeView, coordinator: ()) { view.detach() }
}
