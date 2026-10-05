import Foundation
import GhosttyKit

/// Octo's launch contract. A command is already quoted by the terminal launch boundary.
public struct GhosttyLaunchOptions {
    public var directory: String
    public var environment: [String: String]
    public var command: String?
    public var fontSize: Float
    public var waitAfterCommand: Bool

    public init(directory: String, environment: [String: String] = [:], command: String? = nil,
                fontSize: Float = 13, waitAfterCommand: Bool = true) {
        self.directory = directory; self.environment = environment; self.command = command
        self.fontSize = fontSize; self.waitAfterCommand = waitAfterCommand
    }
}

/// Explicit color overrides; an empty value restores the user's base configuration.
public struct GhosttyColors: Equatable {
    public var background: String
    public var foreground: String
    public var cursor: String
    public var cursorText: String
    public var selectionBackground: String
    public var selectionForeground: String
    public var palette: [String]
    public init(background: String, foreground: String, cursor: String, cursorText: String,
                selectionBackground: String, selectionForeground: String, palette: [String]) {
        self.background = background; self.foreground = foreground; self.cursor = cursor
        self.cursorText = cursorText; self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground; self.palette = palette
    }

    func rendered() throws -> String {
        let values = [background, foreground, cursor, cursorText, selectionBackground, selectionForeground] + palette
        guard palette.count <= 256, values.allSatisfy(Self.isColor) else {
            throw GhosttyFailure.message("Invalid terminal color override.")
        }
        var lines = ["background = \(background)", "foreground = \(foreground)",
                     "cursor-color = \(cursor)", "cursor-text = \(cursorText)",
                     "selection-background = \(selectionBackground)", "selection-foreground = \(selectionForeground)"]
        lines += palette.enumerated().map { "palette = \($0.offset)=\($0.element)" }
        return lines.joined(separator: "\n") + "\n"
    }
    static func isColor(_ value: String) -> Bool {
        let raw = value.hasPrefix("#") ? String(value.dropFirst()) : value
        return raw.utf8.count == 6 && raw.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
}

enum GhosttyFailure: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case let .message(text): return text } }
}

/// All configurations are built from the base again: removing an overlay must not
/// leave a previous theme's palette in a cloned, already-finalized configuration.
@MainActor final class GhosttyConfiguration {
    let handle: ghostty_config_t
    let diagnostics: [String]
    init(path: String?, colors: GhosttyColors? = nil) throws {
        guard let config = ghostty_config_new() else { throw GhosttyFailure.message("Ghostty could not allocate its configuration.") }
        do {
            if let path { path.withCString { ghostty_config_load_file(config, $0) } }
            ghostty_config_load_recursive_files(config)
            if let colors { try Self.loadOverlay(colors.rendered(), into: config) }
            ghostty_config_finalize(config)
            diagnostics = (0..<ghostty_config_diagnostics_count(config)).compactMap { index in
                ghostty_config_get_diagnostic(config, index).message.map { String(cString: $0) }
            }
            handle = config
        } catch { ghostty_config_free(config); throw error }
    }
    deinit { ghostty_config_free(handle) }

    private static func loadOverlay(_ contents: String, into config: ghostty_config_t) throws {
        var template = Array((NSTemporaryDirectory() + "octo-ghostty-config.XXXXXX").utf8CString)
        guard let directory = mkdtemp(&template) else { throw POSIXError(.EIO) }
        let url = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("config")
        guard FileManager.default.createFile(atPath: file.path, contents: Data(contents.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw GhosttyFailure.message("Cannot prepare terminal appearance configuration.")
        }
        file.path.withCString { ghostty_config_load_file(config, $0) }
    }
}
