import Foundation
import OctoCore

public struct HarnessDescriptor: Identifiable {
    public var id: HarnessID
    public var executable: URL?
    public var supportsApprovals: Bool
    public var detail: String
}
public struct AgentApproval: Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    public var respond: (Bool) -> Void
}
public enum AgentEvent {
    case session(String)
    case textDelta(String)
    case message(String)
    case activity(String)
    case approval(AgentApproval)
    case approvalResolved(String)
    case finished
    case failed(String)
}
@MainActor public protocol AgentHarness: AnyObject {
    var onEvent: ((AgentEvent) -> Void)? { get set }
    func send(prompt: String, sessionID: String?, directory: String, settings: AgentSettings, images: [ImageAttachment]) async throws
    func interrupt() async
    func shutdown()
}
@MainActor public enum HarnessRegistry {
    public static var descriptors: [HarnessDescriptor] {
        [.init(id: .codex, executable: CodexExecutable.resolve(), supportsApprovals: true,
               detail: "App-server · streaming, resume, command and file approvals"),
         .init(id: .claude, executable: Executables.find("claude"), supportsApprovals: false,
               detail: "CLI print mode · streaming and resume; interactive approvals are unavailable")]
    }
    public static func make(_ id: HarnessID, codexExecutable: URL? = nil) -> any AgentHarness {
        switch id { case .codex: return CodexHarness(executable: codexExecutable); case .claude: return ClaudeHarness() }
    }
}

/// Provider-neutral catalog consumed by the composer. Values come from the installed CLI.
public struct AgentModel: Identifiable, Decodable, Equatable, Sendable {
    public var id: String { model }
    public let model: String
    public let displayName: String
    public let description: String
    public let hidden: Bool
    public let isDefault: Bool
    public let defaultReasoningEffort: String
    public let inputModalities: [String]?
    public var supportsImages: Bool { inputModalities?.contains("image") ?? true }
    public let supportedReasoningEfforts: [ReasoningOption]
}
public struct ReasoningOption: Identifiable, Decodable, Equatable, Sendable {
    public var id: String { reasoningEffort }
    public let reasoningEffort: String
    public let description: String
    public var title: String {
        switch reasoningEffort {
        case "xhigh": return "Extra high"
        default: return reasoningEffort.capitalized
        }
    }
}
