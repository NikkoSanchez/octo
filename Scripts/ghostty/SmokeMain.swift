import AppKit
import GhosttyKit

/// Standalone native smoke host linked only against Octo's wrapper and build.
/// It launches a disposable /bin/sh, never the user's login shell or editor.
@main @MainActor struct SmokeMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = SmokeDelegate()
        app.delegate = delegate
        app.setActivationPolicy(ProcessInfo.processInfo.environment["OCTO_GHOSTTY_SMOKE_BACKGROUND"] == "1" ? .accessory : .regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor final class SmokeDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var session: GhosttySession!
    private var checks: [String] = []
    private var skipped: [String] = []
    private let background = ProcessInfo.processInfo.environment["OCTO_GHOSTTY_SMOKE_BACKGROUND"] == "1"
    private var menuInvocations = 0
    @objc private func menuProbe(_ sender: Any?) { menuInvocations += 1 }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 850, height: 480),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Octo-owned Ghostty — native smoke"
        let command = "printf 'OCTO_NATIVE_READY\\n'; while IFS= read -r line; do case \"$line\" in identity) printf 'OCTO_PID:%s\\n' \"$$\";; hidden) sleep 1; printf 'HIDDEN_OUTPUT_READY\\n';; quit) exit;; *) printf 'RECEIVED:%s\\n' \"$line\";; esac; done"
        session = GhosttySession(options: .init(directory: NSTemporaryDirectory(), command: "/bin/sh -c " + GhosttyInput.shellQuotedPath(command)))
        session.isSurfaceVisible = true
        window.contentView = session.nativeView()
        if background { window.orderBack(nil) }
        else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        session.requestFocus()
        Task { await runChecks() }
    }
    private func waitFor(_ label: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { checks.append(label); return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw GhosttyFailure.message("Timed out: " + label + "; notice=" + (session.notice ?? "none") + "; text=" + session.visibleText())
    }
    private func enter(_ text: String) throws {
        if background {
            // This mode verifies engine I/O without pretending to test native
            // key events or capturing the user's foreground keyboard input.
            guard let surface = session.surface else { throw GhosttyFailure.message("Missing smoke surface") }
            let value = text + "\r"
            value.withCString { ghostty_surface_text(surface, $0, UInt(value.utf8.count)) }
            return
        }
        let view = session.nativeView()
        // Select this app's key window without activating it over the user's app.
        window.makeKey()
        window.makeFirstResponder(view)
        guard window.isKeyWindow, window.firstResponder === view else {
            throw GhosttyFailure.message("Smoke window lost keyboard focus before input")
        }
        view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        view.keyDown(with: event)
        let release = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        view.keyUp(with: release)
    }
    private func runChecks() async {
        do {
            try await waitFor("source-built renderer and shell") { session.visibleText().contains("OCTO_NATIVE_READY") }
            let info = ghostty_info()
            let version = String(decoding: UnsafeRawBufferPointer(start: info.version, count: Int(info.version_len)), as: UTF8.self)
            guard version == ProcessInfo.processInfo.environment["OCTO_GHOSTTY_EXPECTED_VERSION"] else {
                throw GhosttyFailure.message("Linked engine version differs from lock: " + version)
            }
            checks.append("linked engine reports " + version)
            if background { skipped += ["native first responder", "native Unicode key translation"] }
            else { try await waitFor("native first responder") { window.firstResponder === session.view && window.isKeyWindow } }
            try enter("identity")
            try await waitFor("shell reports its process identity") { reportedPID() != nil }
            let pid = reportedPID()!
            let original = session.surface
            if background { skipped.append("native Settings/Quit shortcuts") }
            else {
                let oldMenu = NSApp.mainMenu
                let menu = NSMenu()
                let rootItem = NSMenuItem()
                let submenu = NSMenu()
                for (title, key) in [("Settings", ","), ("Quit", "q")] {
                    let item = NSMenuItem(title: title, action: #selector(menuProbe(_:)), keyEquivalent: key)
                    item.target = self; item.keyEquivalentModifierMask = .command
                    submenu.addItem(item)
                }
                rootItem.submenu = submenu; menu.addItem(rootItem); NSApp.mainMenu = menu
                for (key, code) in [(",", UInt16(43)), ("q", UInt16(12))] {
                    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
                    guard session.nativeView().performKeyEquivalent(with: event) else { throw GhosttyFailure.message("Menu key equivalent was swallowed") }
                }
                NSApp.mainMenu = oldMenu
                guard menuInvocations == 2 else { throw GhosttyFailure.message("Settings/Quit were captured by Ghostty") }
                checks.append("native Settings/Quit shortcuts win")
            }
            try enter("unicode-λ-🐙")
            try await waitFor(background ? "engine Unicode input and Return" : "Unicode input and Return") { session.visibleText().contains("RECEIVED:unicode-λ-🐙") }
            try enter("hidden")
            session.isSurfaceVisible = false
            guard session.nativeView().isAccessibilityHidden() else { throw GhosttyFailure.message("Hidden terminal still exposed to accessibility") }
            try await waitFor("hidden surface continues processing") { session.visibleText().contains("HIDDEN_OUTPUT_READY") }
            session.view?.insertText("SHOULD_NOT_ARRIVE", replacementRange: NSRange(location: NSNotFound, length: 0))
            session.isSurfaceVisible = true
            session.requestFocus()
            if background { skipped.append("focus restored") }
            else { try await waitFor("focus restored") { window.firstResponder === session.view } }
            try enter("restored")
            try await waitFor("hidden input ignored") { session.visibleText().contains("RECEIVED:restored") && !session.visibleText().contains("SHOULD_NOT_ARRIVE") }
            let before = ghostty_surface_size(original!)
            window.setContentSize(NSSize(width: 940, height: 520))
            session.view?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            guard session.surface == original, kill(pid, 0) == 0 else { throw GhosttyFailure.message("Resize recreated the process/surface") }
            let after = ghostty_surface_size(original!)
            guard after.columns > before.columns, after.rows > before.rows else { throw GhosttyFailure.message("Resize did not update the grid") }
            try enter("identity")
            try await waitFor("resize and visibility preserve process") { session.visibleText().components(separatedBy: "OCTO_PID:\(pid)").count >= 3 }
            // Exercise the stable C clipboard callback with a real engine-owned
            // request. Use the private selection board, preserving its contents.
            let board = GhosttyClipboard.board(GHOSTTY_CLIPBOARD_SELECTION)!
            let saved = board.string(forType: .string)
            defer { board.clearContents(); if let saved { board.setString(saved, forType: .string) } }
            board.clearContents(); board.setString("CANCELLED_PASTE\n", forType: .string)
            guard session.nativeView().binding("paste_from_selection") else { throw GhosttyFailure.message("Paste binding unavailable") }
            try await waitFor("unsafe paste requires confirmation") { !session.clipboardRequests.isEmpty && window.attachedSheet != nil }
            session.clipboardRequests.values.first?.resolve(allow: false)
            try await Task.sleep(for: .milliseconds(200))
            guard session.clipboardRequests.isEmpty, !session.visibleText().contains("RECEIVED:CANCELLED_PASTE") else { throw GhosttyFailure.message("Cancelled paste reached the shell") }
            checks.append("cancelled paste sends no input")
            board.clearContents(); board.setString("APPROVED_PASTE\n", forType: .string)
            guard session.nativeView().binding("paste_from_selection") else { throw GhosttyFailure.message("Paste binding unavailable") }
            try await waitFor("next clipboard request remains usable") { !session.clipboardRequests.isEmpty && window.attachedSheet != nil }
            session.clipboardRequests.values.first?.resolve(allow: true)
            try await waitFor("approved paste reaches shell once") { session.visibleText().components(separatedBy: "RECEIVED:APPROVED_PASTE").count == 2 }
            let colors = GhosttyColors(background: "1e1e2e", foreground: "cdd6f4", cursor: "f5e0dc", cursorText: "1e1e2e", selectionBackground: "45475a", selectionForeground: "cdd6f4", palette: [])
            guard session.setColors(colors), session.setColors(nil), session.surface == original else { throw GhosttyFailure.message("Live configuration failed") }
            checks.append("theme apply and reset preserve surface")
            let view = session.nativeView()
            window.contentView = NSView()
            try await Task.sleep(for: .milliseconds(100))
            window.contentView = view
            session.requestFocus()
            if background { skipped.append("reattachment restores focus") }
            else { try await waitFor("reattachment restores focus") { window.firstResponder === view } }
            guard session.surface == original else { throw GhosttyFailure.message("Reattachment recreated the terminal") }
            try enter("quit")
            try await waitFor("child exit notification") { session.processExited }
            session.close(); session.close()
            guard session.surface == nil, session.isClosed else { throw GhosttyFailure.message("Surface not released") }
            checks.append("idempotent explicit teardown")
            session = GhosttySession(options: .init(directory: NSTemporaryDirectory(), command: "/bin/sh -c " + GhosttyInput.shellQuotedPath("printf 'OCTO_PID:%s\\n' \"$$\"; exec /bin/sleep 120")))
            session.isSurfaceVisible = true
            window.contentView = session.nativeView()
            try await waitFor("live child starts") { reportedPID() != nil }
            let child = reportedPID()!
            board.clearContents(); board.setString("NEVER_PASTE_ON_CLOSE\n", forType: .string)
            guard session.nativeView().binding("paste_from_selection") else { throw GhosttyFailure.message("Paste binding unavailable") }
            try await waitFor("live child has pending clipboard request") { !session.clipboardRequests.isEmpty }
            session.close()
            guard session.clipboardRequests.isEmpty else { throw GhosttyFailure.message("Close left a clipboard request pending") }
            checks.append("close cancels engine clipboard request before freeing surface")
            try await waitFor("explicit close terminates owned child") { kill(child, 0) == -1 && errno == ESRCH }
            finish(success: true, error: nil)
        } catch { session.close(); finish(success: false, error: error.localizedDescription) }
    }
    private func reportedPID() -> pid_t? {
        for line in session.visibleText().components(separatedBy: .newlines) {
            if line.hasPrefix("OCTO_PID:"), let pid = pid_t(line.dropFirst(9).trimmingCharacters(in: .whitespaces)), pid > 0 { return pid }
        }
        return nil
    }
    private func finish(success: Bool, error: String?) {
        let result: [String: Any] = ["success": success, "checks": checks, "skipped": skipped,
                                   "mode": background ? "background" : "foreground", "error": error ?? ""]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        if let path = ProcessInfo.processInfo.environment["OCTO_GHOSTTY_SMOKE_RESULT"] { try? data.write(to: URL(fileURLWithPath: path)) }
        print(String(decoding: data, as: UTF8.self))
        NSApp.terminate(nil)
    }
}
