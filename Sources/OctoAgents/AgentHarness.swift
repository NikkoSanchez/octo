import Foundation
import OctoCore

public struct HarnessDescriptor: Identifiable {
    public var id: HarnessID
    public var executable: URL?
    public var supportsApprovals: Bool
    public var detail: String
    public var permissionOptions: [AgentPermissionOption] = []
    public var defaultPermissionMode: AgentPermissionMode? = nil
    public var supportsModels = false
    public var supportsImages = false
    public var supportsUsageLimits = false
    /// False when limits arrive only as stream events (no read-only query exists).
    public var supportsUsageRefresh = false
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
    case interrupted
    case failed(String)
}
@MainActor public protocol AgentHarness: AnyObject {
    var onEvent: ((AgentEvent) -> Void)? { get set }
    func send(prompt: String, sessionID: String?, directory: String, settings: AgentSettings, images: [ImageAttachment]) async throws
    func steer(prompt: String, images: [ImageAttachment]) async throws
    func respond(to id: UUID, with response: AgentInteractionResponse) throws
    func interrupt() async
    func shutdown()
}
@MainActor public extension AgentHarness {
    func steer(prompt: String, images: [ImageAttachment]) async throws {
        throw ProcessFailure.exited("Steering is unavailable in this adapter. Queue a follow-up instead.")
    }
    func respond(to id: UUID, with response: AgentInteractionResponse) throws {
        throw ProcessFailure.exited("Interactive requests are unavailable in this adapter.")
    }
}
@MainActor public enum HarnessRegistry {
    public static var descriptors: [HarnessDescriptor] {
        [.init(id: .codex, executable: CodexExecutable.resolve(), supportsApprovals: true,
               detail: "App-server · tool activity, bounded forms and app-access decisions; experimental questions require CLI 0.158+. Inventory and URL/device verification are unavailable.",
               permissionOptions: CodexHarness.permissionOptions, defaultPermissionMode: .ask, supportsModels: true, supportsImages: true, supportsUsageLimits: true, supportsUsageRefresh: true,
               supportsConversationUsage: true, supportsCompactionStatus: true, capabilities: .codex),
         .init(id: .claude, executable: Executables.find("claude"), supportsApprovals: true,
               detail: "CLI SDK stream · models, effort, images, tool activity, approvals and single-choice questions. Sign in with claude auth login. Account limits and context usage update after responses; active steering is unavailable.",
               permissionOptions: ClaudeHarness.permissionOptions, defaultPermissionMode: .autoReview, supportsModels: true, supportsImages: true,
               supportsUsageLimits: true, supportsConversationUsage: true, supportsCompactionStatus: true, capabilities: .claude)]
    }
    public static func make(_ id: HarnessID, codexExecutable: URL? = nil) -> any AgentHarness {
        switch id { case .codex: return CodexHarness(executable: codexExecutable); case .claude: return ClaudeHarness() }
    }
    public static func models(_ id: HarnessID, directory: String, codexExecutable: URL? = nil) async throws -> [AgentModel] {
        switch id {
        case .codex: return try await CodexHarness.models(directory: directory, executable: codexExecutable)
        case .claude: return try await ClaudeHarness.models(directory: directory)
        }
    }
    public static func usage(_ id: HarnessID, directory: String, codexExecutable: URL? = nil) async throws -> AgentUsage {
        switch id {
        case .codex: return try await CodexHarness.usage(directory: directory, executable: codexExecutable)
        case .claude: throw ProcessFailure.exited("Claude reports account limits only alongside responses; there is no read-only query.")
        }
    }
}

public struct AgentPermissionOption: Identifiable, Equatable {
    public var id: AgentPermissionMode { mode }
    public let mode: AgentPermissionMode
    public let title: String
    public let detail: String
    public init(mode: AgentPermissionMode, title: String? = nil, detail: String) {
        self.mode = mode; self.title = title ?? mode.title; self.detail = detail
    }
}

/// Account limits, not a token count for this conversation. Never infer missing limits as zero.
public struct AgentUsage: Equatable, Sendable {
    public var buckets: [AgentUsageBucket]
    public var fetchedAt: Date
    /// Pushed updates may describe only the window that changed; keep other last-known windows.
    public static func merging(_ update: AgentUsage, into existing: AgentUsage?) -> AgentUsage {
        var buckets = existing?.buckets ?? []
        for bucket in update.buckets {
            guard let index = buckets.firstIndex(where: { $0.id == bucket.id }) else { buckets.append(bucket); continue }
            var merged = bucket
            merged.windows = buckets[index].windows
            for window in bucket.windows {
                if let position = merged.windows.firstIndex(where: { $0.id == window.id }) { merged.windows[position] = window }
                else { merged.windows.append(window) }
            }
            buckets[index] = merged
        }
        var result = update; result.buckets = buckets.sorted { $0.id < $1.id }
        return result
    }
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
    /// Provider label when the duration alone is ambiguous (for example per-model weekly limits).
    public var name: String? = nil
    /// The provider reported this window as currently rejecting requests.
    public var isLimited = false
    public var remainingPercent: Double? { usedPercent.map { max(0, min(100, 100 - $0)) } }
    public var title: String {
        if let name { return name }
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
