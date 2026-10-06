import Foundation

struct GroupKey: Hashable, Sendable, Codable {
    let model: String
    let effort: String
    /// `service_tier` as logged, with "fast" folded into its legacy alias "priority".
    let tier: String

    var id: String { "\(model)|\(effort)|\(tier)" }

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

struct Sample: Sendable, Codable {
    /// Codex thread (OTEL `conversation.id`); with `end` it identifies a response across sources.
    var threadId: String
    let key: GroupKey
    let outputTokens: Int
    let reasoningTokens: Int
    /// Request sent → response completed.
    var duration: TimeInterval
    let end: Date
    /// Request sent → first token, known only for responses seen through telemetry.
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

/// Tracks one rollout file. A model request is assumed to start at the last
/// event that hands control back to the model (turn start, tool output, user
/// message) and end at its `token_usage_record`, so TPS includes time to first token.
struct RolloutParser: Codable {
    private var model = "?"
    private var effort = "?"
    private var tier = "default"
    private var requestStart: Date?

    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Most bytes in a rollout are tool output and reasoning lines that only matter for their
    /// timestamp or not at all, so the kind is read from the line head and full JSON parsing
    /// is reserved for the few lines that carry settings or token usage.
    mutating func consume(line: Data) -> Sample? {
        let head = LineHead(line.prefix(320))
        guard let type = head.outerType else { return nil }

        switch (type, head.payloadType) {
        case ("event_msg", "task_started"):
            requestStart = head.timestamp
        case ("event_msg", "task_complete"), ("event_msg", "turn_aborted"):
            requestStart = nil
        case ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"):
            requestStart = head.timestamp
        case ("response_item", "message") where head.contains(#""role":"user""#):
            requestStart = head.timestamp
        case ("turn_context", _), ("event_msg", "thread_settings_applied"), ("token_usage_record", _):
            return consumeJSON(line)
        default:
            break
        }
        return nil
    }

    private mutating func consumeJSON(_ line: Data) -> Sample? {
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
            let s = payload["thread_settings"] as? [String: Any] ?? [:]
            if let m = s["model"] as? String { model = m }
            if let e = s["reasoning_effort"] as? String { effort = e }
            if let t = s["service_tier"] as? String { tier = t == "fast" ? "priority" : t }

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
                threadId: payload["thread_id"] as? String ?? "",
                key: GroupKey(model: model, effort: effort, tier: tier),
                outputTokens: out,
                reasoningTokens: usage["reasoning_output_tokens"] as? Int ?? 0,
                duration: duration,
                end: ts,
                ttft: nil
            )

        default:
            break
        }
        return nil
    }
}

/// Reads `timestamp`, the top-level `type` and `payload.type` from the start of a
/// rollout line, which always looks like
/// `{"timestamp":"…",["ordinal":N,]"type":"…","payload":{["type":"…"]…`.
private struct LineHead {
    private let bytes: [UInt8]

    init(_ data: Data) {
        bytes = Array(data)
    }

    func contains(_ needle: String) -> Bool {
        index(of: needle, from: 0) != nil
    }

    var timestamp: Date? {
        guard let s = string(after: #""timestamp":""#, from: 0) else { return nil }
        return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s)
    }

    var outerType: String? {
        string(after: #""type":""#, from: 0)
    }

    var payloadType: String? {
        let marker = Array(#""payload":{"type":""#.utf8)
        guard let i = index(of: marker, from: 0) else { return nil }
        return string(at: i + marker.count)
    }

    private func string(after needle: String, from start: Int) -> String? {
        let n = Array(needle.utf8)
        guard let i = index(of: n, from: start) else { return nil }
        return string(at: i + n.count)
    }

    private func string(at start: Int) -> String? {
        guard let end = bytes[start...].firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private func index(of needle: String, from start: Int) -> Int? {
        index(of: Array(needle.utf8), from: start)
    }

    private func index(of needle: [UInt8], from start: Int) -> Int? {
        guard needle.count <= bytes.count - start else { return nil }
        var i = start
        while i <= bytes.count - needle.count {
            if bytes[i] == needle[0] && Array(bytes[i..<i + needle.count]) == needle { return i }
            i += 1
        }
        return nil
    }
}
