import AppKit
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "local.codex-tps", category: "samples")

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

    /// Buckets of an hour or more start on local clock boundaries (days at local midnight), like the ticks.
    func bucketStart(_ date: Date) -> Date {
        let offset = bucket >= 3600 ? TimeInterval(TimeZone.current.secondsFromGMT(for: date)) : 0
        return Date(timeIntervalSince1970: ((date.timeIntervalSince1970 + offset) / bucket).rounded(.down) * bucket - offset)
    }
}

struct ChartPoint: Identifiable {
    let key: GroupKey
    let bucket: Date
    let tps: Double
    let count: Int
    let ttft: TimeInterval?
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
}

@MainActor
@Observable
final class Stats {
    static let liveWindow: TimeInterval = 60
    static let historyWindow: TimeInterval = ChartRange.d90.duration
    /// `allSeries` (for --bench) covers series seen within this horizon.
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
    /// Fixed clock for --snapshot renders, so every view judges ages and pin expiry alike.
    @ObservationIgnored var frozenNow: Date? {
        didSet { now = frozenNow ?? Date() }
    }
    /// Bumped whenever `samples` changes. Per-series values derived from samples are cached
    /// against it, because the menu bar and the popover ask for them on every render.
    private(set) var version = 0
    @ObservationIgnored private var cache: [String: Any] = [:]
    @ObservationIgnored private var cacheVersion = -1
    /// Set once stored responses have been loaded.
    private(set) var loaded = false
    /// Latest response of each series, and latest with decode timing, so lookups need no scan.
    private var latest: [String: Sample] = [:]
    private var latestDecode: [String: Sample] = [:]

    private var telemetry: TelemetryReceiver?
    /// Last time Codex delivered any telemetry batch.
    private(set) var telemetrySeenAt: Date?
    /// Why the telemetry port could not be opened, if it could not.
    private(set) var listenerError: String?
    /// Newest response that came through telemetry.
    var lastTelemetryResponse: Date? { stored.last { $0.ttft != nil }?.end }
    private let db = MetricsDB()
    private var timer: Timer?
    private var clock: Timer?

    /// The popover's window, reported by PopoverView; the clock stops once it is off screen.
    @ObservationIgnored weak var popoverWindow: NSWindow?

    /// The popover is open: tick `now` every second for relative times and the chart's
    /// right edge. Closed, nothing depends on wall time, so the app stays idle.
    func setVisible(_ visible: Bool) {
        guard visible != (clock != nil) else { return }
        clock?.invalidate()
        clock = nil
        guard visible else { return }
        now = frozenNow ?? Date()
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Backstop for a missed hide notification; a reopen restarts the clock on its own.
                guard let window = self.popoverWindow, window.isVisible else {
                    self.setVisible(false)
                    return
                }
                self.now = self.frozenNow ?? Date()
            }
        }
        clock?.tolerance = 0.2
    }

    func start() {
        // Per-series color slots of earlier builds; colors now follow the model family.
        for key in ["seriesSlots", "seriesColors", "seriesShades"] { UserDefaults.standard.removeObject(forKey: key) }
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

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
        timer?.tolerance = 10
    }

    /// Samples that ended at or after `date`, found by binary search (samples are time-ordered).
    private func samples(since date: Date) -> ArraySlice<Sample> {
        var lo = samples.startIndex, hi = samples.endIndex
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].end < date { lo = mid + 1 } else { hi = mid }
        }
        return samples[lo...]
    }

    /// Value for the menu bar: one series' latest response or token-weighted average. The
    /// window ends at its latest response with a value at `speed` rather than now, so an idle
    /// pause keeps the last value instead of blanking.
    func trayValue(metric: TrayMetric, series id: String, speed: SpeedMetric) -> (tps: Double, badge: String, model: String, end: Date)? {
        cached("tray|\(metric.rawValue)|\(id)|\(speed.rawValue)") { computeTrayValue(metric: metric, series: id, speed: speed) }
    }

    private func computeTrayValue(metric: TrayMetric, series id: String, speed: SpeedMetric) -> (tps: Double, badge: String, model: String, end: Date)? {
        guard let last = lastSample(id, speed: speed) else { return nil }
        if metric == .last { return [last].rate(speed).map { ($0, last.key.tierBadge, last.key.model, last.end) } }
        let pool = samples(since: last.end.addingTimeInterval(-metric.window)).filter { $0.key == last.key && $0.measures(speed) }
        return pool.rate(speed).map { ($0, last.key.tierBadge, last.key.model, last.end) }
    }

    /// A series' latest response that has a value at `speed`.
    func lastSample(_ id: String, speed: SpeedMetric) -> Sample? {
        speed == .e2e ? latest[id] : latestDecode[id]
    }

    /// Series seen in the last 24 hours.
    var allSeries: [GroupKey] {
        latest.values.filter { now.timeIntervalSince($0.end) < Self.seriesWindow }.map(\.key)
    }

    /// A series' mean TTFT over the minute before its latest response with a value at `speed`,
    /// the same window as its menu bar value, so it stays put during a pause.
    func recentTTFT(_ key: GroupKey, speed: SpeedMetric) -> TimeInterval? {
        cached("ttft|\(key.id)|\(speed.rawValue)") {
            guard let last = lastSample(key.id, speed: speed) else { return nil }
            return samples(since: last.end.addingTimeInterval(-Self.liveWindow))
                .filter { $0.key == key && $0.end <= last.end }
                .meanTTFT
        }
    }

    /// Distinct Codex threads of a series that answered within `window`.
    func activeThreads(_ key: GroupKey, within window: TimeInterval = 10 * 60) -> Int {
        Set(samples(since: now.addingTimeInterval(-window)).filter { $0.key == key }.map(\.threadId)).count
    }

    /// Series that answered within `window`, most recent first.
    func activeSeries(within window: TimeInterval = 10 * 60) -> [GroupKey] {
        var seen: [GroupKey] = []
        for s in samples(since: now.addingTimeInterval(-window)).reversed() where !seen.contains(s.key) {
            seen.append(s.key)
        }
        return seen
    }

    /// The main series: the one generating the most tokens lately, each response weighted by
    /// its age before the latest response (halving every five minutes), so a brief side
    /// request (e.g. gpt-5.6-luna inside a thread) does not take over during a pause. Only
    /// responses with a value at `speed` count, so under Decode a series of one-chunk answers
    /// cannot take the menu bar and leave it without a value.
    func mainSeries(speed: SpeedMetric) -> GroupKey? {
        cached("main|\(speed.rawValue)") {
            guard let latest = samples.last(where: { $0.measures(speed) }) else { return nil }
            var tokens: [GroupKey: (count: Double, last: Date)] = [:]
            for s in samples(since: latest.end.addingTimeInterval(-3600)) where s.measures(speed) {
                let weight = exp2(-latest.end.timeIntervalSince(s.end) / 300)
                tokens[s.key] = ((tokens[s.key]?.count ?? 0) + Double(s.outputTokens) * weight, s.end)
            }
            // Ties go to the series that answered last, then to the lower id, so the pick never flickers.
            return tokens.max { a, b in
                (a.value.count, a.value.last, b.key.id) < (b.value.count, b.value.last, a.key.id)
            }?.key
        }
    }

    /// A pinned series silent for this long no longer hides series that are working.
    static let pinExpiry: TimeInterval = 60 * 60

    enum Display {
        case pin, main
        /// The pin is set but has been silent for `pinExpiry` while another series answered.
        case pinExpired
        /// The pin is set but its series has no data in the history.
        case pinMissing
    }

    /// The series the menu bar shows and the Live list leads with, and why. Silence is measured
    /// on responses with a value at `speed`, the same ones the menu bar value comes from.
    func displaySeries(pinned: String?, speed: SpeedMetric) -> (key: GroupKey, reason: Display)? {
        let main = mainSeries(speed: speed)
        guard let pinned else { return main.map { ($0, .main) } }
        guard let pin = lastSample(pinned, speed: speed) else { return main.map { ($0, .pinMissing) } }
        if let main, now.timeIntervalSince(pin.end) >= Self.pinExpiry,
           let mainEnd = lastSample(main.id, speed: speed)?.end, mainEnd > pin.end {
            return (main, .pinExpired)
        }
        return (pin.key, .pin)
    }

    /// Per-response rate distribution of each series over a range, fastest median first.
    func distributions(_ range: ChartRange, speed: SpeedMetric) -> [SeriesDistribution] {
        // Minute resolution is enough for the range edge; caching keeps the open Models tab cheap.
        let minute = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60)
        return cached("dist|\(range.rawValue)|\(speed.rawValue)|\(minute.timeIntervalSince1970)") {
            computeDistributions(range, speed: speed, at: minute)
        }
    }

    private func computeDistributions(_ range: ChartRange, speed: SpeedMetric, at end: Date) -> [SeriesDistribution] {
        let byKey = Dictionary(grouping: samples(since: end.addingTimeInterval(-range.duration)), by: \.key)
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
        .sorted { ($0.median, $1.key.id) > ($1.median, $0.key.id) }
    }

    /// Chart points of one range, one line per series.
    func chartModel(_ range: ChartRange, speed: SpeedMetric) -> ChartModel {
        // Recomputed when data changes or the range edge crosses a bucket, not every second;
        // computed for that bucket edge so the cached model matches its key.
        let edge = range.bucketStart(now)
        return cached("chart|\(range.rawValue)|\(speed.rawValue)|\(edge.timeIntervalSince1970)") {
            computeChartModel(range, speed: speed, at: edge.addingTimeInterval(range.bucket))
        }
    }

    private func computeChartModel(_ range: ChartRange, speed: SpeedMetric, at end: Date) -> ChartModel {
        let cutoff = end.addingTimeInterval(-range.duration)
        let measurable = samples(since: cutoff).filter { $0.measures(speed) }
        let buckets = Dictionary(grouping: measurable) { s in
            BucketKey(key: s.key, bucket: range.bucketStart(s.end))
        }
        var points = buckets.compactMap { b, list in
            list.rate(speed).map { ChartPoint(key: b.key, bucket: b.bucket, tps: $0, count: list.count, ttft: list.meanTTFT, segment: 0) }
        }
        // Stable order within a bucket keeps the z-order of overlapping marks from shuffling.
        .sorted { ($0.bucket, $0.key.id) < ($1.bucket, $1.key.id) }

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
        return ChartModel(points: points)
    }

    /// Updates the latest-response lookups; samples may come in any order.
    private func index<S: Sequence<Sample>>(_ list: S) {
        for s in list {
            if latest[s.key.id].map({ $0.end <= s.end }) ?? true { latest[s.key.id] = s }
            if s.generationTime != nil, latestDecode[s.key.id].map({ $0.end <= s.end }) ?? true { latestDecode[s.key.id] = s }
        }
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
        // Telemetry arrives in time order, so the common case is a plain append; a late batch
        // from another Codex process only needs a re-sort.
        let ordered = new.sorted { $0.end < $1.end }
        let added = ordered.map(grouped)
        let late = stored.last.map { ordered[0].end < $0.end } ?? false
        stored.append(contentsOf: ordered)
        samples.append(contentsOf: added)
        if late {
            stored.sort { $0.end < $1.end }
            samples.sort { $0.end < $1.end }
        }
        index(added)
        version += 1
    }

    private func grouped(_ s: Sample) -> Sample {
        guard !splitByEffort else { return s }
        var s = s
        s.key = s.key.withoutEffort
        return s
    }

    private func regroup() {
        samples = stored.map(grouped)
        latest = [:]
        latestDecode = [:]
        index(samples)
        version += 1
    }

    private func prune() {
        now = frozenNow ?? Date()
        let cutoff = now.addingTimeInterval(-Self.historyWindow)
        // Mutating an observed array, even to remove nothing, re-renders every view reading it.
        guard let first = stored.first, first.end < cutoff else { return }
        stored.removeAll { $0.end < cutoff }
        samples.removeAll { $0.end < cutoff }
        latest = latest.filter { $0.value.end >= cutoff }
        latestDecode = latestDecode.filter { $0.value.end >= cutoff }
        version += 1
    }

    /// Memoizes a value derived from `samples` until they change. Reading `version` keeps
    /// SwiftUI's observation of the caller tied to sample changes.
    private func cached<T>(_ key: String, _ make: () -> T) -> T {
        // Time-keyed entries accumulate while the popover stays open without new data.
        if cacheVersion != version || cache.count > 256 {
            cache.removeAll(keepingCapacity: true)
            cacheVersion = version
        }
        if let hit = cache[key] as? Box<T> { return hit.value }
        let value = make()
        cache[key] = Box(value: value)
        return value
    }

    private struct Box<T> {
        let value: T
    }
}
