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

/// Pairs `codex.websocket_request` (request sent) with the following
/// `codex.sse_event` `response.completed` of the same conversation.
struct ResponseTracker {
    private var requestSent: [String: Date] = [:]
    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

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
        for a in records {
            guard
                let conversation = a["conversation.id"] as? String,
                let tsString = a["event.timestamp"] as? String,
                let ts = try? Self.dateStyle.parse(tsString)
            else { continue }

            switch a["event.name"] as? String {
            case "codex.websocket_request":
                requestSent[conversation] = ts
            case "codex.api_request" where a["endpoint"] as? String == "/responses":
                // HTTP transport: the event is logged when the request finishes, so step back by its duration.
                requestSent[conversation] = ts.addingTimeInterval(-(Self.number(a["duration_ms"]) ?? 0) / 1000)
            case "codex.sse_event" where a["event.kind"] as? String == "response.completed":
                defer { requestSent[conversation] = nil }
                guard
                    let sent = requestSent[conversation],
                    let ttftMs = Self.number(a["ttft_ms"]),
                    let out1 = Self.number(a["output_token_count"]), out1 > 0
                else { continue }
                let duration = ts.timeIntervalSince(sent)
                guard duration > 0.05 else { continue }
                let tier = (a["service_tier"] as? String).map { $0 == "fast" ? "priority" : $0 } ?? "default"
                out.append(Sample(
                    threadId: conversation,
                    key: GroupKey(
                        model: a["model"] as? String ?? "?",
                        effort: a["model_reasoning_effort"] as? String ?? "?",
                        tier: tier
                    ),
                    outputTokens: Int(out1),
                    reasoningTokens: Int(Self.number(a["reasoning_token_count"]) ?? 0),
                    duration: duration,
                    end: ts,
                    ttft: min(ttftMs / 1000, duration)
                ))
            default:
                break
            }
        }
        if !out.isEmpty {
            log.info("telemetry: \(out.count) responses")
        }
        return out
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
