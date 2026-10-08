import Foundation

struct GroupKey: Hashable, Sendable {
    let model: String
    let effort: String
    /// `service_tier` as logged, with "fast" folded into its legacy alias "priority".
    let tier: String

    var id: String { "\(model)|\(effort)|\(tier)" }

    /// The same series with reasoning effort left out of the grouping.
    var withoutEffort: GroupKey { GroupKey(model: model, effort: "", tier: tier) }

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
    /// Even Ultrafast tops out around 750 t/s; a higher rate means the timing is not a
    /// real generation measurement (tokens flushed in one burst, or a mispaired request).
    static let maxPlausibleTPS = 1500.0

    /// Codex thread (OTEL `conversation.id`); with `end` it identifies a response.
    var threadId: String
    var key: GroupKey
    let outputTokens: Int
    let reasoningTokens: Int
    /// Request sent → response completed.
    var duration: TimeInterval
    let end: Date
    /// Request sent → first token, as measured by Codex.
    var ttft: TimeInterval?

    /// End-to-end rate, including time to first token.
    var tps: Double { Double(outputTokens) / duration }

    /// Time spent generating after the first token, when that can be told apart. Nil when it
    /// is too short or implies an implausible rate, e.g. a short answer delivered in one chunk:
    /// its E2E timing still counts, it just says nothing about decode speed.
    var generationTime: TimeInterval? {
        guard let ttft, outputTokens > 1 else { return nil }
        let t = duration - ttft
        guard t > 0.05, Double(outputTokens - 1) / t <= Self.maxPlausibleTPS else { return nil }
        return t
    }

    /// Whether the response has a value at `speed`: decode needs a generation time.
    func measures(_ speed: SpeedMetric) -> Bool {
        speed == .e2e || generationTime != nil
    }

    /// Decode rate: tokens after the first divided by the time after the first.
    var decodeTPS: Double? {
        generationTime.map { Double(outputTokens - 1) / $0 }
    }
}
