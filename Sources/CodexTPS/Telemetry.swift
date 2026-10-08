import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "local.codex-tps", category: "telemetry")

/// Receives Codex OpenTelemetry logs (OTLP/HTTP, JSON) on localhost and turns each
/// model response into a `Sample` with its time to first token.
///
/// Codex must export logs here (`~/.codex/config.toml`):
/// `[otel] exporter = { otlp-http = { endpoint = "http://127.0.0.1:43180/v1/logs", protocol = "json" } }`
final class TelemetryReceiver: @unchecked Sendable {
    static let port: UInt16 = 43180

    private let queue = DispatchQueue(label: "codex-tps.telemetry")
    private let onSamples: @Sendable ([Sample]) -> Void
    /// Called for every batch Codex sends, responses or not.
    var onBatch: (@Sendable () -> Void)?
    /// nil once listening, otherwise why the port could not be opened.
    var onListenerError: (@Sendable (String?) -> Void)?
    private var listener: NWListener?
    private var tracker = ResponseTracker()

    init(onSamples: @escaping @Sendable ([Sample]) -> Void) {
        self.onSamples = onSamples
    }

    func start() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.onListenerError?(nil)
                case .failed(let e):
                    log.error("listener failed: \(e.localizedDescription, privacy: .public)")
                    self?.onListenerError?(e.localizedDescription)
                default:
                    break
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            log.error("listener: \(error.localizedDescription, privacy: .public)")
            onListenerError?(error.localizedDescription)
        }
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        receive(on: c, buffer: Data())
    }

    /// Minimal HTTP/1.1: reads requests with Content-Length bodies on a keep-alive connection.
    private func receive(on c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer + (data ?? Data())
            while let request = HTTPRequest(parsing: &buf) {
                if request.path.hasSuffix("/v1/logs") {
                    self.onBatch?()
                    let samples = self.tracker.consume(otlpLogs: request.body)
                    if !samples.isEmpty { self.onSamples(samples) }
                }
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
                c.send(content: reply.data(using: .utf8), completion: .contentProcessed { _ in })
            }
            if done || error != nil {
                c.cancel()
            } else {
                self.receive(on: c, buffer: buf)
            }
        }
    }
}

private struct HTTPRequest {
    let path: String
    let body: Data

    /// Removes one complete request from the front of `buf`, or returns nil if it is incomplete.
    init?(parsing buf: inout Data) {
        guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[buf.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        var length = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == "content-length" {
                length = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = headerEnd.upperBound
        guard buf.distance(from: bodyStart, to: buf.endIndex) >= length else { return nil }
        let bodyEnd = buf.index(bodyStart, offsetBy: length)
        path = parts.count > 1 ? String(parts[1]) : "/"
        body = Data(buf[bodyStart..<bodyEnd])
        buf = Data(buf[bodyEnd...])
    }
}

/// Pairs a request event (`codex.websocket_request`, or `codex.api_request` to /responses)
/// with the `response.completed` event that carries its usage. Telemetry has no request id,
/// so pairing is deliberately conservative:
/// - Starts wait per conversation and model; a completion takes the latest one its TTFT allows,
///   so a start left by an interrupted request is passed over once a newer one exists.
///   Concurrent side requests (e.g. gpt-5.6-luna memory jobs) each find a start of their own.
/// - A reused websocket logs requests under the model it was opened with, so after a model
///   switch the completion's model has no start; then it takes the latest start of the
///   conversation's only other model with pending starts, if that start is newer than any its
///   own model logged, and leaves it there if the pair is rejected.
/// - A pair is dropped when it contradicts Codex's own TTFT, implies a decode faster than any
///   model, or a generation slower than any real response (a stale start). Answers under 64
///   tokens may arrive in one chunk, so they skip the fast check and record no decode then.
/// Overlapping requests on one conversation and model can still swap starts.
struct ResponseTracker {
    /// Pending request starts per conversation, then per model as logged on the request event.
    private var pending: [String: [String: [Date]]] = [:]
    /// Latest start logged per conversation and model, consumed or not.
    private var lastStart: [String: [String: Date]] = [:]
    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    /// Codex starts its TTFT clock after the request event, so only rounding separates them.
    private static let rounding: TimeInterval = 0.05
    /// Below this many tokens an answer can arrive in one chunk, so decode speed cannot be judged.
    private static let burstTokens = 64.0
    /// Real responses decode at 8 t/s or more; the slack covers server-side pauses such as web search.
    private static let minPlausibleTPS = 5.0
    private static let slowSlack: TimeInterval = 10
    /// Starts that never completed are forgotten after this long, and at most this many are kept.
    private static let pendingLimit: TimeInterval = 30 * 60
    private static let pendingCount = 16

    mutating func consume(otlpLogs body: Data) -> [Sample] {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [] }
        var records: [[String: Any]] = []
        for rl in root["resourceLogs"] as? [[String: Any]] ?? [] {
            for sl in rl["scopeLogs"] as? [[String: Any]] ?? [] {
                for r in sl["logRecords"] as? [[String: Any]] ?? [] {
                    records.append(Self.attributes(r))
                }
            }
        }
        records.sort { ($0["event.timestamp"] as? String ?? "") < ($1["event.timestamp"] as? String ?? "") }

        var out: [Sample] = []
        var latest: Date?
        for a in records {
            guard
                let thread = a["conversation.id"] as? String,
                let tsString = a["event.timestamp"] as? String,
                let ts = try? Self.dateStyle.parse(tsString)
            else { continue }
            latest = max(latest ?? ts, ts)
            let model = a["model"] as? String ?? ""
            // Both request events are logged once the request is written; step back to when it began.
            let sendTime = (Self.number(a["duration_ms"]) ?? 0) / 1000

            switch a["event.name"] as? String {
            case "codex.websocket_request":
                addStart(ts.addingTimeInterval(-sendTime), thread: thread, model: model)
            case "codex.api_request" where a["endpoint"] as? String == "/responses":
                addStart(ts.addingTimeInterval(-sendTime), thread: thread, model: model)
            case "codex.sse_event" where a["event.kind"] as? String == "response.completed":
                // Over HTTP a bare response.completed comes first; the one with usage, or a failure, ends the request.
                guard let tokens = Self.number(a["output_token_count"]) else {
                    if a["error.message"] != nil { _ = takeStart(thread: thread, model: model, before: ts) }
                    continue
                }
                // No TTFT (e.g. the startup prewarm, which generates nothing): the request ended, nothing to measure.
                guard let ttftMs = Self.number(a["ttft_ms"]) else {
                    _ = takeStart(thread: thread, model: model, before: ts)
                    continue
                }
                let latestAllowed = ts.addingTimeInterval(-ttftMs / 1000 + Self.rounding)
                guard let (sent, from) = takeStart(thread: thread, model: model, before: latestAllowed) else { continue }
                guard let sample = Self.sample(a, thread: thread, model: model, tokens: tokens, ttft: ttftMs / 1000, sent: sent, end: ts) else {
                    if from != model { addStart(sent, thread: thread, model: from, logged: false) }
                    continue
                }
                out.append(sample)
            default:
                break
            }
        }
        if let latest {
            let cutoff = latest.addingTimeInterval(-Self.pendingLimit)
            pending = pending.compactMapValues { models in
                let kept = models.compactMapValues { starts in
                    let recent = starts.filter { $0 >= cutoff }
                    return recent.isEmpty ? nil : recent
                }
                return kept.isEmpty ? nil : kept
            }
            lastStart = lastStart.compactMapValues { models in
                let kept = models.filter { $0.value >= cutoff }
                return kept.isEmpty ? nil : kept
            }
        }
        if !out.isEmpty {
            log.info("telemetry: \(out.count) responses")
        }
        return out
    }

    private mutating func addStart(_ date: Date, thread: String, model: String, logged: Bool = true) {
        var starts = pending[thread, default: [:]][model, default: []]
        starts.append(date)
        starts.sort()
        pending[thread, default: [:]][model] = Array(starts.suffix(Self.pendingCount))
        if logged { lastStart[thread, default: [:]][model] = max(lastStart[thread]?[model] ?? date, date) }
    }

    /// The start a completion answers, and the model it was logged under: the latest start of
    /// its own model that its TTFT allows, or else, after a model switch, of the only other model.
    private mutating func takeStart(thread: String, model: String, before limit: Date) -> (sent: Date, model: String)? {
        if let sent = popLatest(thread: thread, model: model, before: limit) { return (sent, model) }
        let others = (pending[thread] ?? [:]).filter { $0.key != model && $0.value.contains { $0 <= limit } }
        guard others.count == 1, let other = others.first?.key,
              let candidate = others.first?.value.last(where: { $0 <= limit }),
              candidate > lastStart[thread]?[model] ?? .distantPast
        else { return nil }
        return popLatest(thread: thread, model: other, before: limit).map { ($0, other) }
    }

    private mutating func popLatest(thread: String, model: String, before limit: Date) -> Date? {
        guard var starts = pending[thread]?[model], let i = starts.lastIndex(where: { $0 <= limit }) else { return nil }
        let sent = starts.remove(at: i)
        pending[thread]?[model] = starts.isEmpty ? nil : starts
        if pending[thread]?.isEmpty == true { pending[thread] = nil }
        return sent
    }

    private static func sample(_ a: [String: Any], thread: String, model: String, tokens: Double, ttft: TimeInterval, sent: Date, end: Date) -> Sample? {
        guard tokens > 0 else { return nil }
        let duration = end.timeIntervalSince(sent)
        let generation = duration - ttft
        guard duration > 0.05, generation >= -rounding, duration <= pendingLimit,
              generation <= slowSlack + tokens / minPlausibleTPS
        else { return nil }
        if tokens >= burstTokens {
            guard generation > 0.05, (tokens - 1) / generation <= Sample.maxPlausibleTPS else { return nil }
        }
        let tier = (a["service_tier"] as? String).map { $0 == "fast" ? "priority" : $0 } ?? "default"
        return Sample(
            threadId: thread,
            key: GroupKey(model: model.isEmpty ? "?" : model, effort: a["model_reasoning_effort"] as? String ?? "?", tier: tier),
            outputTokens: Int(tokens),
            reasoningTokens: Int(number(a["reasoning_token_count"]) ?? 0),
            duration: duration,
            end: end,
            ttft: min(ttft, duration)
        )
    }

    private static func attributes(_ record: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for kv in record["attributes"] as? [[String: Any]] ?? [] {
            guard let k = kv["key"] as? String, let v = kv["value"] as? [String: Any], let first = v.first else { continue }
            out[k] = first.value
        }
        return out
    }

    /// OTLP JSON carries numbers as strings or as int/double values.
    private static func number(_ v: Any?) -> Double? {
        switch v {
        case let s as String: Double(s)
        case let n as NSNumber: n.doubleValue
        default: nil
        }
    }
}
