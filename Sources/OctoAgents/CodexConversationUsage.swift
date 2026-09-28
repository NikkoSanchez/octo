import Foundation
import OctoCore

extension CodexHarness {
    /// app-server v2 ThreadTokenUsageUpdatedNotification, CLI 0.158.0-alpha.2.1.
    /// Last-response total approximates occupied context; cumulative totals are not context size.
    static func decodeConversationUsage(_ payload: [String: Any]) throws -> ConversationUsage {
        struct Breakdown: Decodable {
            let totalTokens: Int
            let inputTokens: Int?
            let cachedInputTokens: Int?
            let cacheWriteInputTokens: Int?
            let outputTokens: Int?
            let reasoningOutputTokens: Int?
            func counts() throws -> TokenCounts {
                guard [totalTokens, inputTokens, cachedInputTokens, cacheWriteInputTokens, outputTokens, reasoningOutputTokens]
                    .compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else {
                    throw ProcessFailure.exited("Invalid negative token count.")
                }
                return TokenCounts(total: totalTokens, input: inputTokens, cachedInput: cachedInputTokens,
                                   cacheWriteInput: cacheWriteInputTokens, output: outputTokens, reasoning: reasoningOutputTokens)
            }
        }
        struct Usage: Decodable { let last: Breakdown; let total: Breakdown; let modelContextWindow: Int? }
        struct Payload: Decodable { let tokenUsage: Usage }
        let wire = try JSONDecoder().decode(Payload.self, from: JSONSerialization.data(withJSONObject: payload)).tokenUsage
        return try ConversationUsage(latest: wire.last.counts(), session: wire.total.counts(),
                                     contextWindow: wire.modelContextWindow.flatMap { $0 > 0 ? $0 : nil })
    }
}
