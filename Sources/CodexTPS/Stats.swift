import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "local.codex-tps", category: "samples")

struct GroupStats: Identifiable {
    let key: GroupKey
    /// Latest response in the whole history, so idle series still show when they last ran.
    let last: Sample
    /// Token-weighted TPS over the live window; nil when the series was idle.
    let avgTPS: Double?
    let count: Int

    var id: GroupKey { key }
}

enum ChartRange: String, CaseIterable, Identifiable {
    case m30, h2, h5, h10

    var id: String { rawValue }

    var title: String {
        switch self {
        case .m30: "30m"
        case .h2: "2h"
        case .h5: "5h"
        case .h10: "10h"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .m30: 30 * 60
        case .h2: 2 * 3600
        case .h5: 5 * 3600
        case .h10: 10 * 3600
        }
    }

    var bucket: TimeInterval {
        switch self {
        case .m30: 60
        case .h2: 5 * 60
        case .h5: 10 * 60
        case .h10: 20 * 60
        }
    }


    /// X-axis tick spacing in minutes.
    var tickMinutes: Int {
        switch self {
        case .m30: 5
        case .h2: 30
        case .h5: 60
        case .h10: 120
        }
    }

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

    var id: String { "\(key.id)|\(bucket.timeIntervalSince1970)" }
}

@MainActor
@Observable
final class Stats {
    static let liveWindow: TimeInterval = 60
    static let historyWindow: TimeInterval = ChartRange.h10.duration

    private(set) var samples: [Sample] = []
    private(set) var now = Date()
    /// Color slot per series, persisted so a series keeps its color across restarts.
    private(set) var slots: [String: Int] = Stats.loadSlots()

    private var watcher: SessionWatcher?
    private var timer: Timer?

    func start() {
        let root = ProcessInfo.processInfo.environment["CODEX_SESSIONS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        let watcher = SessionWatcher(root: root, window: Self.historyWindow) { [weak self] new in
            Task { @MainActor in self?.add(new) }
        }
        watcher.start()
        self.watcher = watcher

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
    }

    /// Value for the menu bar: the latest response or a token-weighted average,
    /// over all series or only the pinned one. The window ends at the latest matching
    /// response rather than now, so an idle pause keeps the last value instead of blanking.
    func trayValue(metric: TrayMetric, pinned: String?) -> (tps: Double, badge: String)? {
        let series = samples.filter { pinned == nil || $0.key.id == pinned }
        guard let last = series.last else { return nil }
        if metric == .last { return (last.tps, last.key.tierBadge) }
        let cutoff = last.end.addingTimeInterval(-metric.window)
        let pool = series.filter { $0.end >= cutoff }
        let out = pool.reduce(0) { $0 + $1.outputTokens }
        let dur = pool.reduce(0) { $0 + $1.duration }
        let badges = Set(pool.map(\.key.tierBadge))
        return (Double(out) / dur, badges.count == 1 ? badges.first! : "")
    }

    /// One row per series in the history, in color-slot order, so rows neither
    /// appear, vanish nor reorder as series go idle (the popover window does not shrink).
    var groups: [GroupStats] {
        let cutoff = now.addingTimeInterval(-Self.liveWindow)
        let byKey = Dictionary(grouping: samples, by: \.key)
        return allSeries.map { key in
            let list = byKey[key]!
            let live = list.filter { $0.end >= cutoff }
            let out = live.reduce(0) { $0 + $1.outputTokens }
            let dur = live.reduce(0) { $0 + $1.duration }
            return GroupStats(
                key: key,
                last: list.last!,
                avgTPS: live.isEmpty ? nil : Double(out) / dur,
                count: live.count
            )
        }
    }

    var allSeries: [GroupKey] {
        Set(samples.map(\.key)).sorted { slot(of: $0) < slot(of: $1) }
    }

    /// Token-weighted TPS per group per time bucket of the range.
    func chartPoints(_ range: ChartRange) -> [ChartPoint] {
        let cutoff = now.addingTimeInterval(-range.duration)
        let buckets = Dictionary(grouping: samples.filter { $0.end >= cutoff }) { s in
            BucketKey(key: s.key, bucket: range.bucketStart(s.end))
        }
        return buckets.map { b, list in
            let out = list.reduce(0) { $0 + $1.outputTokens }
            let dur = list.reduce(0) { $0 + $1.duration }
            return ChartPoint(key: b.key, bucket: b.bucket, tps: Double(out) / dur, count: list.count)
        }
        .sorted { $0.bucket < $1.bucket }
    }

    func chartSeries(_ range: ChartRange) -> [GroupKey] {
        let cutoff = now.addingTimeInterval(-range.duration)
        return Set(samples.filter { $0.end >= cutoff }.map(\.key)).sorted { slot(of: $0) < slot(of: $1) }
    }

    func slot(of key: GroupKey) -> Int {
        slots[key.id] ?? Int.max
    }

    /// Keeps a series' remembered slot unless another series in the current history holds it;
    /// otherwise takes the lowest slot free among series currently in history.
    private func assignSlot(_ key: GroupKey) {
        let present = Set(samples.map(\.key.id)).subtracting([key.id])
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
        for s in new {
            log.info("\(s.key.model, privacy: .public) \(s.key.effort, privacy: .public) tier=\(s.key.tier, privacy: .public) tps=\(Int(s.tps)) out=\(s.outputTokens)")
        }
        samples.append(contentsOf: new)
        samples.sort { $0.end < $1.end }
        prune()
        for key in Set(new.map(\.key)) { assignSlot(key) }
    }

    private func prune() {
        now = Date()
        let cutoff = now.addingTimeInterval(-Self.historyWindow)
        samples.removeAll { $0.end < cutoff }
    }
}
