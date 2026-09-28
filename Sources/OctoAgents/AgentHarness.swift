import Foundation
import OctoCore

public struct HarnessDescriptor: Identifiable {
    public var id: HarnessID
    public var executable: URL?
    public var supportsApprovals: Bool
    public var detail: String
    public var permissionOptions: [AgentPermissionOption] = []
    public var defaultPermissionMode: AgentPermissionMode? = nil
    public var supportsUsageLimits = false
    public var supportsConversationUsage = false
    public var supportsCompactionStatus = false
    public var capabilities = HarnessCapabilities()
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
    case activityDelta(String)
    case reasoningDelta(String)
    case usage(AgentUsage)
    case conversationUsage(ConversationUsage)
    case compaction(ContextCompaction)
    case toolActivity(ToolActivity)
    case interaction(AgentInteraction)
    case interactionResolved(UUID)
    case interactionUnavailable(String)
    case approval(AgentApproval)
    case approvalResolved(String)
    case finished
    case failed(String)
}
@MainActor public protocol AgentHarness: AnyObject {
    var onEvent: ((AgentEvent) -> Void)? { get set }
    func send(prompt: String, sessionID: String?, directory: String, settings: AgentSettings, images: [ImageAttachment]) async throws
    func respond(to id: UUID, with response: AgentInteractionResponse) throws
    func interrupt() async
    func shutdown()
}
@MainActor public extension AgentHarness {
    func respond(to id: UUID, with response: AgentInteractionResponse) throws {
        throw ProcessFailure.exited("Interactive requests are unavailable in this adapter.")
    }
}
@MainActor public enum HarnessRegistry {
    public static var descriptors: [HarnessDescriptor] {
        [.init(id: .codex, executable: CodexExecutable.resolve(), supportsApprovals: true,
               detail: "App-server · tool activity, bounded forms and app-access decisions; experimental questions require CLI 0.158+. Inventory and URL/device verification are unavailable.",
               permissionOptions: CodexHarness.permissionOptions, defaultPermissionMode: .ask, supportsUsageLimits: true,
               supportsConversationUsage: true, supportsCompactionStatus: true, capabilities: .codex),
         .init(id: .claude, executable: Executables.find("claude"), supportsApprovals: false,
               detail: "CLI print mode · streaming and resume; interactive approvals are unavailable")]
    }
    public static func make(_ id: HarnessID, codexExecutable: URL? = nil) -> any AgentHarness {
        switch id { case .codex: return CodexHarness(executable: codexExecutable); case .claude: return ClaudeHarness() }
    }
    public static func usage(_ id: HarnessID, directory: String, codexExecutable: URL? = nil) async throws -> AgentUsage {
        switch id {
        case .codex: return try await CodexHarness.usage(directory: directory, executable: codexExecutable)
        case .claude: throw ProcessFailure.exited("This provider does not expose account usage limits through the current adapter.")
        }
    }
}

public struct AgentPermissionOption: Identifiable {
    public var id: AgentPermissionMode { mode }
    public let mode: AgentPermissionMode
    public let detail: String
}

/// Account limits, not a token count for this conversation. Never infer missing limits as zero.
public struct AgentUsage: Equatable, Sendable {
    public var buckets: [AgentUsageBucket]
    public var fetchedAt: Date
}
public struct AgentUsageBucket: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var windows: [AgentUsageWindow]
}
public struct AgentUsageWindow: Identifiable, Equatable, Sendable {
    public var id: String
    public var usedPercent: Double?
    public var durationMinutes: Int?
    public var resetsAt: Date?
    public var remainingPercent: Double? { usedPercent.map { max(0, min(100, 100 - $0)) } }
    public var title: String {
        guard let minutes = durationMinutes, minutes > 0 else { return id.capitalized + " window" }
        if minutes == 10_080 { return "Weekly" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)-day window" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour window" }
        return "\(minutes)-minute window"
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
