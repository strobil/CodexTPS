import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "local.codex-tps", category: "samples")

struct GroupStats: Identifiable {
    let key: GroupKey
    /// Latest response in the whole history, so idle series still show when they last ran.
    let last: Sample
    /// Token-weighted rates over the live window; nil when the series was idle there
    /// (decode also when none of its responses came with telemetry).
    let e2e: Double?
    let decode: Double?
    let ttft: TimeInterval?
    let count: Int

    var id: GroupKey { key }
}

/// Grafana's "Last …" quick ranges up to 90 days.
enum ChartRange: String, CaseIterable, Identifiable {
    case m5, m15, m30, h1, h3, h6, h12, h24, d2, d7, d30, d90

    var id: String { rawValue }

    var title: String {
        switch self {
        case .m5: "5m"
        case .m15: "15m"
        case .m30: "30m"
        case .h1: "1h"
        case .h3: "3h"
        case .h6: "6h"
        case .h12: "12h"
        case .h24: "24h"
        case .d2: "2d"
        case .d7: "7d"
        case .d30: "30d"
        case .d90: "90d"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .m5: 5 * 60
        case .m15: 15 * 60
        case .m30: 30 * 60
        case .h1: 3600
        case .h3: 3 * 3600
        case .h6: 6 * 3600
        case .h12: 12 * 3600
        case .h24: 24 * 3600
        case .d2: 2 * 86400
        case .d7: 7 * 86400
        case .d30: 30 * 86400
        case .d90: 90 * 86400
        }
    }

    /// Width of one chart point; keeps roughly 15–45 points per range.
    var bucket: TimeInterval {
        switch self {
        case .m5: 20
        case .m15: 30
        case .m30: 60
        case .h1: 2 * 60
        case .h3: 5 * 60
        case .h6: 10 * 60
        case .h12: 20 * 60
        case .h24: 30 * 60
        case .d2: 3600
        case .d7: 4 * 3600
        case .d30: 86400
        case .d90: 2 * 86400
        }
    }

    /// X-axis tick spacing in minutes.
    var tickMinutes: Int {
        switch self {
        case .m5: 1
        case .m15: 5
        case .m30: 5
        case .h1: 10
        case .h3: 30
        case .h6: 60
        case .h12: 2 * 60
        case .h24: 4 * 60
        case .d2: 8 * 60
        case .d7: 24 * 60
        case .d30: 5 * 24 * 60
        case .d90: 15 * 24 * 60
        }
    }

    var showsDate: Bool { duration > 86400 }

    /// Tick dates aligned to round local times (multiples of `tickMinutes` since midnight).
    func ticks(until end: Date) -> [Date] {
        let cal = Calendar.current
        let start = end.addingTimeInterval(-duration)
        let step = TimeInterval(tickMinutes * 60)
        let midnight = cal.startOfDay(for: start)
        var t = midnight.addingTimeInterval((start.timeIntervalSince(midnight) / step).rounded(.up) * step)
        var out: [Date] = []
        while t <= end {
            out.append(t)
            t.addTimeInterval(step)
        }
        return out
    }

    func bucketStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / bucket).rounded(.down) * bucket)
    }
}

struct ChartPoint: Identifiable {
    let key: GroupKey
    let bucket: Date
    let tps: Double
    let count: Int
    /// Consecutive run of buckets within the series; lines are not drawn across segments.
    var segment: Int

    var id: String { "\(key.id)|\(bucket.timeIntervalSince1970)" }
}

struct SeriesDistribution: Identifiable {
    let key: GroupKey
    let p10: Double
    let median: Double
    let p90: Double
    /// Median time to first token, when any response has it.
    let ttft: TimeInterval?
    let count: Int

    var id: GroupKey { key }
}

extension Array where Element == Double {
    /// Linear-interpolated quantile of an ascending array.
    func quantile(_ q: Double) -> Double {
        guard count > 1 else { return first ?? 0 }
        let pos = q * Double(count - 1)
        let lo = Int(pos.rounded(.down))
        let hi = Swift.min(lo + 1, count - 1)
        return self[lo] + (self[hi] - self[lo]) * (pos - Double(lo))
    }
}

struct ChartModel {
    let points: [ChartPoint]
    /// Colored series in slot order, then "Other" when series were folded.
    let legend: [GroupKey]
    let palette: [GroupKey: Int]
    /// Series with data in the range.
    let visible: Set<GroupKey>

    func color(_ key: GroupKey) -> Int {
        palette[key] ?? SeriesPalette.count
    }
}

@MainActor
@Observable
final class Stats {
    static let liveWindow: TimeInterval = 60
    static let historyWindow: TimeInterval = ChartRange.d90.duration
    /// Table rows and legend entries cover series seen within this horizon.
    static let seriesWindow: TimeInterval = 24 * 3600

    /// Responses as recorded.
    private var stored: [Sample] = []
    /// Responses as displayed: `stored` with effort dropped from the series key unless split by effort.
    private(set) var samples: [Sample] = []

    /// Whether reasoning effort is part of a series. It barely changes decode speed, so
    /// series default to model × tier; splitting helps when looking at TTFT or `max`.
    var splitByEffort = UserDefaults.standard.bool(forKey: "splitByEffort") {
        didSet {
            UserDefaults.standard.set(splitByEffort, forKey: "splitByEffort")
            regroup()
        }
    }
    private(set) var now = Date()
    /// Set once stored responses have been loaded.
    private(set) var loaded = false
    /// Color slot per series, persisted so a series keeps its color across restarts.
    private(set) var slots: [String: Int] = Stats.loadSlots()

    private var telemetry: TelemetryReceiver?
    /// Last time Codex delivered any telemetry batch.
    private(set) var telemetrySeenAt: Date?
    /// Why the telemetry port could not be opened, if it could not.
    private(set) var listenerError: String?
    /// Newest response that came through telemetry.
    var lastTelemetryResponse: Date? { stored.last { $0.ttft != nil }?.end }
    private let db = MetricsDB()
    private var timer: Timer?

    func start() {
        add(db.load(since: Date().addingTimeInterval(-Self.historyWindow)))
        loaded = true

        let telemetry = TelemetryReceiver { [weak self] new in
            Task { @MainActor in
                self?.db.insert(new)
                self?.add(new)
            }
        }
        telemetry.onBatch = { [weak self] in
            Task { @MainActor in self?.telemetrySeenAt = Date() }
        }
        telemetry.onListenerError = { [weak self] e in
            Task { @MainActor in self?.listenerError = e }
        }
        // Snapshot and bench runs must not compete with the running app for the port.
        if !Snapshot.isRequested { telemetry.start() }
        self.telemetry = telemetry

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
    }

    /// Value for the menu bar: the latest response or a token-weighted average,
    /// over all series or only the pinned one. The window ends at the latest matching
    /// response rather than now, so an idle pause keeps the last value instead of blanking.
    func trayValue(metric: TrayMetric, pinned: String?, speed: SpeedMetric) -> (tps: Double, badge: String)? {
        let series = samples.filter { (pinned == nil || $0.key.id == pinned) && (speed == .e2e || $0.generationTime != nil) }
        guard let last = series.last else { return nil }
        if metric == .last { return [last].rate(speed).map { ($0, last.key.tierBadge) } }
        let cutoff = last.end.addingTimeInterval(-metric.window)
        let pool = series.filter { $0.end >= cutoff }
        let badges = Set(pool.map(\.key.tierBadge))
        return pool.rate(speed).map { ($0, badges.count == 1 ? badges.first! : "") }
    }

    /// One row per series in the history, in color-slot order, so rows neither
    /// appear, vanish nor reorder as series go idle (the popover window does not shrink).
    var groups: [GroupStats] {
        let cutoff = now.addingTimeInterval(-Self.liveWindow)
        let byKey = Dictionary(grouping: samples.filter { $0.end >= now.addingTimeInterval(-Self.seriesWindow) }, by: \.key)
        return allSeries.map { key in
            let list = byKey[key]!
            let live = list.filter { $0.end >= cutoff }
            return GroupStats(
                key: key,
                last: list.last!,
                e2e: live.rate(.e2e),
                decode: live.rate(.decode),
                ttft: live.meanTTFT,
                count: live.count
            )
        }
    }

    /// Series seen in the last 24 hours, in color-slot order.
    var allSeries: [GroupKey] {
        let cutoff = now.addingTimeInterval(-Self.seriesWindow)
        var seen = Set<GroupKey>()
        for s in samples.reversed() {
            guard s.end >= cutoff else { break }
            seen.insert(s.key)
        }
        return seen.sorted { slot(of: $0) < slot(of: $1) }
    }

    /// Series that answered within `window`, most recent first.
    func activeSeries(within window: TimeInterval = 10 * 60) -> [GroupKey] {
        let cutoff = now.addingTimeInterval(-window)
        var seen: [GroupKey] = []
        for s in samples.reversed() {
            guard s.end >= cutoff else { break }
            if !seen.contains(s.key) { seen.append(s.key) }
        }
        return seen
    }

    /// The series the Now tab leads with: the pinned one if it has data, else the latest to answer.
    func heroSeries(pinned: String?) -> GroupKey? {
        if let pinned, let key = samples.last(where: { $0.key.id == pinned })?.key { return key }
        return samples.last?.key
    }

    /// Per-response rate distribution of each series over a range, fastest median first.
    func distributions(_ range: ChartRange, speed: SpeedMetric) -> [SeriesDistribution] {
        let cutoff = now.addingTimeInterval(-range.duration)
        let byKey = Dictionary(grouping: samples.filter { $0.end >= cutoff }, by: \.key)
        return byKey.compactMap { key, list in
            let rates = list.compactMap { speed == .e2e ? $0.tps : $0.decodeTPS }.sorted()
            guard rates.count >= 3 else { return nil }
            let ttfts = list.compactMap(\.ttft).sorted()
            return SeriesDistribution(
                key: key,
                p10: rates.quantile(0.1),
                median: rates.quantile(0.5),
                p90: rates.quantile(0.9),
                ttft: ttfts.isEmpty ? nil : ttfts.quantile(0.5),
                count: rates.count
            )
        }
        .sorted { $0.median > $1.median }
    }

    /// Everything the chart, legend and table colors need for one range. Series are ranked
    /// by how recently they ran; the eight most recent keep distinct colors (their remembered
    /// slot when free) and the rest fold into a single "Other" series.
    func chartModel(_ range: ChartRange, speed: SpeedMetric) -> ChartModel {
        let cutoff = now.addingTimeInterval(-range.duration)
        let seriesCutoff = now.addingTimeInterval(-Self.seriesWindow)
        var lastSeen: [GroupKey: Date] = [:]
        for s in samples.reversed() {
            guard s.end >= min(cutoff, seriesCutoff) else { break }
            if lastSeen[s.key] == nil { lastSeen[s.key] = s.end }
        }
        let ranked = lastSeen.keys.sorted { lastSeen[$0]! > lastSeen[$1]! }

        var palette: [GroupKey: Int] = [:]
        var used = Set<Int>()
        for key in ranked.prefix(SeriesPalette.count) {
            let s = slot(of: key)
            if s < SeriesPalette.count, !used.contains(s) {
                palette[key] = s
                used.insert(s)
            }
        }
        for key in ranked.prefix(SeriesPalette.count) where palette[key] == nil {
            let s = (0..<SeriesPalette.count).first { !used.contains($0) }!
            palette[key] = s
            used.insert(s)
        }
        let folded = ranked.count > SeriesPalette.count
        if folded { palette[GroupKey.other] = SeriesPalette.count }
        let display: (GroupKey) -> GroupKey = { palette[$0] == nil ? GroupKey.other : $0 }

        let measurable = samples.filter { $0.end >= cutoff && (speed == .e2e || $0.generationTime != nil) }
        let buckets = Dictionary(grouping: measurable) { s in
            BucketKey(key: display(s.key), bucket: range.bucketStart(s.end))
        }
        var points = buckets.compactMap { b, list in
            list.rate(speed).map { ChartPoint(key: b.key, bucket: b.bucket, tps: $0, count: list.count, segment: 0) }
        }
        .sorted { $0.bucket < $1.bucket }

        // A new segment starts after a missing bucket so lines do not bridge idle stretches.
        var previous: [GroupKey: (bucket: Date, segment: Int)] = [:]
        for i in points.indices {
            let p = points[i]
            var segment = 0
            if let prev = previous[p.key] {
                segment = p.bucket.timeIntervalSince(prev.bucket) > range.bucket * 1.5 ? prev.segment + 1 : prev.segment
            }
            points[i].segment = segment
            previous[p.key] = (p.bucket, segment)
        }

        let legend = ranked.prefix(SeriesPalette.count).sorted { palette[$0]! < palette[$1]! } + (folded ? [GroupKey.other] : [])
        return ChartModel(points: points, legend: legend, palette: palette, visible: Set(points.map(\.key)))
    }

    func slot(of key: GroupKey) -> Int {
        slots[key.id] ?? Int.max
    }

    /// Keeps a series' remembered slot unless another series in the current history holds it;
    /// otherwise takes the lowest slot free among series currently in history.
    private func assignSlot(_ key: GroupKey) {
        let present = Set(allSeries.map(\.id)).subtracting([key.id])
        let taken = Set(present.compactMap { slots[$0] })
        if let s = slots[key.id], s < SeriesPalette.count, !taken.contains(s) { return }
        slots = slots.filter { present.contains($0.key) || $0.value >= SeriesPalette.count || !taken.contains($0.value) }
        slots[key.id] = (0...).first { !taken.contains($0) }!
        UserDefaults.standard.set(slots, forKey: "seriesSlots")
    }

    /// Slot keys used to end in "|true"/"|false" before the tier was stored verbatim.
    private static func loadSlots() -> [String: Int] {
        let raw = UserDefaults.standard.dictionary(forKey: "seriesSlots") as? [String: Int] ?? [:]
        return Dictionary(raw.map { k, v in
            (k.hasSuffix("|true") ? k.dropLast(5) + "|priority" : k.hasSuffix("|false") ? k.dropLast(6) + "|default" : k, v)
        }, uniquingKeysWith: { a, _ in a })
    }

    private struct BucketKey: Hashable {
        let key: GroupKey
        let bucket: Date
    }

    private func add(_ new: [Sample]) {
        guard !new.isEmpty else { return }
        if new.count < 20 {
            for s in new {
                log.info("\(s.key.model, privacy: .public) \(s.key.effort, privacy: .public) tier=\(s.key.tier, privacy: .public) e2e=\(Int(s.tps)) decode=\(s.decodeTPS.map { String(Int($0)) } ?? "-", privacy: .public) ttft=\(s.ttft ?? -1) out=\(s.outputTokens)")
            }
        }
        stored.append(contentsOf: new)
        stored.sort { $0.end < $1.end }
        prune()
        regroup()
    }

    private func regroup() {
        samples = splitByEffort ? stored : stored.map { s in
            var s = s
            s.key = s.key.withoutEffort
            return s
        }
        for key in allSeries { assignSlot(key) }
    }

    private func prune() {
        now = Date()
        let cutoff = now.addingTimeInterval(-Self.historyWindow)
        stored.removeAll { $0.end < cutoff }
        samples.removeAll { $0.end < cutoff }
    }
}
