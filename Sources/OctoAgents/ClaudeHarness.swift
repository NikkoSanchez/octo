import Foundation
import OctoCore

/// CLI adapter deliberately preserves Claude's permission defaults. Denied operations
/// are reported, never retried with bypassPermissions or auto-approval flags.
@MainActor public final class ClaudeHarness: AgentHarness {
    public var onEvent: ((AgentEvent) -> Void)?
    private var transport: JSONLineProcess?
    private var receivedResult = false
    private var streamed = false
    public init() {}
    public func send(prompt: String, sessionID: String?, directory: String, settings: AgentSettings = AgentSettings(), images: [ImageAttachment] = []) async throws {
        guard images.isEmpty else { throw ProcessFailure.exited("Screenshot attachments are not supported by the Claude adapter yet. Use Codex to send images.") }
        guard settings == AgentSettings() else { throw ProcessFailure.exited("Model, reasoning and permission overrides are not supported by the Claude adapter yet.") }
        guard transport?.running != true else { throw ProcessFailure.exited("This thread already has a running turn.") }
        guard let executable = Executables.find("claude") else { throw ProcessFailure.missing("claude") }
        let process = JSONLineProcess(); transport = process; receivedResult = false; streamed = false
        process.onObject = { [weak self] object in self?.receive(object) }
        process.onExit = { [weak self] code, detail in
            guard let self else { return }
            if !self.receivedResult { self.onEvent?(code == 0 ? .finished : .failed(detail.isEmpty ? "Claude exited with status \(code)." : detail)) }
        }
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--permission-mode", "default"]
        if let sessionID { args += ["--resume", sessionID] }
        try process.start(executable: executable, arguments: args, directory: directory)
        try process.writeInput(prompt)
    }
    private func receive(_ object: [String: Any]) {
        if let id = object["session_id"] as? String { onEvent?(.session(id)) }
        switch object["type"] as? String {
        case "stream_event":
            if let event = object["event"] as? [String: Any], let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let text = delta["text"] as? String { streamed = true; onEvent?(.textDelta(text)) }
        case "assistant":
            let message = object["message"] as? [String: Any]
            for block in message?["content"] as? [[String: Any]] ?? [] {
                if block["type"] as? String == "text", !streamed, let text = block["text"] as? String { onEvent?(.message(text)) }
                if block["type"] as? String == "tool_use" { onEvent?(.activity(block["name"] as? String ?? "Tool call")) }
            }
        case "result":
            receivedResult = true
            if let denials = object["permission_denials"] as? [Any], !denials.isEmpty { onEvent?(.activity("Claude declined \(denials.count) operation(s). Interactive approvals are not available in this adapter yet.")) }
            if object["is_error"] as? Bool == true { onEvent?(.failed(object["result"] as? String ?? "Claude reported an error.")) }
            else { onEvent?(.finished) }
        default: break
        }
    }
    public func interrupt() async { transport?.interrupt() }
    public func shutdown() { transport?.stop() }
}
