import Foundation

struct GroupKey: Hashable, Sendable {
    let model: String
    let effort: String
    /// `service_tier` as logged, with "fast" folded into its legacy alias "priority".
    let tier: String

    var id: String { "\(model)|\(effort)|\(tier)" }

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
    let key: GroupKey
    let outputTokens: Int
    let reasoningTokens: Int
    let duration: TimeInterval
    let end: Date

    var tps: Double { Double(outputTokens) / duration }
}

/// Tracks one rollout file. A model request is assumed to start at the last
/// event that hands control back to the model (turn start, tool output, user
/// message) and end at its `token_usage_record`, so TPS includes time to first token.
struct RolloutParser {
    private var model = "?"
    private var effort = "?"
    private var tier = "default"
    private var requestStart: Date?

    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    mutating func consume(line: Data) -> Sample? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = obj["type"] as? String,
            let payload = obj["payload"] as? [String: Any],
            let tsString = obj["timestamp"] as? String,
            let ts = try? Self.dateStyle.parse(tsString)
        else { return nil }

        switch type {
        case "turn_context":
            if let m = payload["model"] as? String { model = m }
            if let e = payload["effort"] as? String { effort = e }

        case "event_msg":
            switch payload["type"] as? String {
            case "thread_settings_applied":
                let s = payload["thread_settings"] as? [String: Any] ?? [:]
                if let m = s["model"] as? String { model = m }
                if let e = s["reasoning_effort"] as? String { effort = e }
                if let t = s["service_tier"] as? String { tier = t == "fast" ? "priority" : t }
            case "task_started":
                requestStart = ts
            case "task_complete", "turn_aborted":
                requestStart = nil
            default:
                break
            }

        case "response_item":
            switch payload["type"] as? String {
            case "function_call_output", "custom_tool_call_output":
                requestStart = ts
            case "message" where payload["role"] as? String == "user":
                requestStart = ts
            default:
                break
            }

        case "token_usage_record":
            defer { requestStart = nil }
            guard
                let start = requestStart,
                let usage = payload["usage"] as? [String: Any],
                let out = usage["output_tokens"] as? Int, out > 0
            else { return nil }
            let duration = ts.timeIntervalSince(start)
            guard duration > 0.3 else { return nil }
            return Sample(
                key: GroupKey(model: model, effort: effort, tier: tier),
                outputTokens: out,
                reasoningTokens: usage["reasoning_output_tokens"] as? Int ?? 0,
                duration: duration,
                end: ts
            )

        default:
            break
        }
        return nil
    }
}
