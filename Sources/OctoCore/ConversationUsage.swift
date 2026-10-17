import Foundation

/// Provider-reported counts. Cached input and reasoning are subsets, not extra tokens.
public struct TokenCounts: Codable, Equatable, Sendable {
    public let total: Int
    public let input: Int?
    public let cachedInput: Int?
    public let cacheWriteInput: Int?
    public let output: Int?
    public let reasoning: Int?

    public init(total: Int, input: Int? = nil, cachedInput: Int? = nil, cacheWriteInput: Int? = nil,
                output: Int? = nil, reasoning: Int? = nil) {
        self.total = total; self.input = input; self.cachedInput = cachedInput
        self.cacheWriteInput = cacheWriteInput; self.output = output; self.reasoning = reasoning
    }
}

/// A replacement snapshot, never an increment. `latest` describes one model response, not a turn.
public struct ConversationUsage: Codable, Equatable, Sendable {
    public let latest: TokenCounts
    /// Cumulative thread totals; nil when the provider's session log cannot be read.
    public let session: TokenCounts?
    public let contextWindow: Int?
    /// Occupied context when the provider measures it separately; otherwise the latest response total.
    public let contextTokens: Int?
    /// The provider's reported automatic-compaction point, when it reports one.
    public let autoCompactThreshold: Int?
    public let updatedAt: Date

    public init(latest: TokenCounts, session: TokenCounts?, contextWindow: Int?, contextTokens: Int? = nil,
                autoCompactThreshold: Int? = nil, updatedAt: Date = Date()) {
        self.latest = latest; self.session = session; self.contextWindow = contextWindow
        self.contextTokens = contextTokens; self.autoCompactThreshold = autoCompactThreshold; self.updatedAt = updatedAt
    }
    public var usedTokens: Int { contextTokens ?? latest.total }
    public var usedFraction: Double? {
        guard let contextWindow, contextWindow > 0, usedTokens >= 0 else { return nil }
        return min(1, Double(usedTokens) / Double(contextWindow))
    }
    public var remainingTokens: Int? {
        guard let contextWindow, contextWindow > 0, usedTokens >= 0 else { return nil }
        return max(0, contextWindow - usedTokens)
    }
    public var percentUsed: Int? { usedFraction.map { Int(($0 * 100).rounded()) } }
    /// True when another snapshot differs in anything but its timestamp.
    public func differsInCounts(from other: ConversationUsage?) -> Bool {
        guard let other else { return true }
        return latest != other.latest || session != other.session || contextWindow != other.contextWindow ||
            contextTokens != other.contextTokens || autoCompactThreshold != other.autoCompactThreshold
    }
}

public struct ContextCompaction: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case compacting, completed, interrupted }
    public let id: String
    public var state: State
    public let startedAt: Date
    public var endedAt: Date?
    public init(id: String, state: State, startedAt: Date = Date(), endedAt: Date? = nil) {
        self.id = id; self.state = state; self.startedAt = startedAt; self.endedAt = endedAt
    }
}
