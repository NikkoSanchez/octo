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
    public let session: TokenCounts
    public let contextWindow: Int?
    public let updatedAt: Date

    public init(latest: TokenCounts, session: TokenCounts, contextWindow: Int?, updatedAt: Date = Date()) {
        self.latest = latest; self.session = session; self.contextWindow = contextWindow; self.updatedAt = updatedAt
    }
    public var usedFraction: Double? {
        guard let contextWindow, contextWindow > 0, latest.total >= 0 else { return nil }
        return min(1, Double(latest.total) / Double(contextWindow))
    }
    public var remainingTokens: Int? {
        guard let contextWindow, contextWindow > 0, latest.total >= 0 else { return nil }
        return max(0, contextWindow - latest.total)
    }
    public var percentUsed: Int? { usedFraction.map { Int(($0 * 100).rounded()) } }
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
