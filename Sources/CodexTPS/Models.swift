import Foundation

struct GroupKey: Hashable, Sendable {
    let model: String
    let effort: String
    /// `service_tier` as logged, with "fast" folded into its legacy alias "priority".
    let tier: String

    var id: String { "\(model)|\(effort)|\(tier)" }

    /// The same series with reasoning effort left out of the grouping.
    var withoutEffort: GroupKey { GroupKey(model: model, effort: "", tier: tier) }

    /// Stand-in for series beyond the palette on long ranges.
    static let other = GroupKey(model: "Other", effort: "", tier: "default")

    var tierBadge: String {
        switch tier {
        case "default": ""
        case "priority": "⚡"
        case "ultrafast": "⚡⚡"
        default: tier
        }
    }
}

struct Sample: Sendable {
    /// Codex thread (OTEL `conversation.id`); with `end` it identifies a response.
    var threadId: String
    var key: GroupKey
    let outputTokens: Int
    let reasoningTokens: Int
    /// Request sent → response completed.
    var duration: TimeInterval
    let end: Date
    /// Request sent → first token; nil for history imported from rollout logs.
    var ttft: TimeInterval?

    /// End-to-end rate, including time to first token.
    var tps: Double { Double(outputTokens) / duration }

    /// Time spent generating after the first token, when that can be told apart.
    var generationTime: TimeInterval? {
        guard let ttft, outputTokens > 1 else { return nil }
        let t = duration - ttft
        return t > 0.05 ? t : nil
    }

    /// Decode rate: tokens after the first divided by the time after the first.
    var decodeTPS: Double? {
        generationTime.map { Double(outputTokens - 1) / $0 }
    }
}
