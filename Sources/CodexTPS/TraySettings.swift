import Foundation
import Observation

enum TrayMetric: String, CaseIterable, Identifiable {
    case last, avg1m, avg5m

    var id: String { rawValue }

    var title: String {
        switch self {
        case .last: "Last"
        case .avg1m: "1m"
        case .avg5m: "5m"
        }
    }

    var window: TimeInterval {
        switch self {
        case .last, .avg1m: 60
        case .avg5m: 5 * 60
        }
    }
}

/// What a TPS figure measures.
enum SpeedMetric: String, CaseIterable, Identifiable {
    /// Output tokens over request → completion, including time to first token.
    case e2e
    /// Tokens after the first over the time after the first token; needs telemetry.
    case decode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .e2e: "E2E"
        case .decode: "Decode"
        }
    }
}

extension Collection where Element == Sample {
    /// Token-weighted rate; nil when no sample carries the needed timing.
    func rate(_ speed: SpeedMetric) -> Double? {
        switch speed {
        case .e2e:
            let dur = reduce(0) { $0 + $1.duration }
            return dur > 0 ? Double(reduce(0) { $0 + $1.outputTokens }) / dur : nil
        case .decode:
            var tokens = 0
            var time: TimeInterval = 0
            for s in self {
                guard let g = s.generationTime else { continue }
                tokens += s.outputTokens - 1
                time += g
            }
            return time > 0 ? Double(tokens) / time : nil
        }
    }

    /// Mean time to first token of the samples that have it.
    var meanTTFT: TimeInterval? {
        let values = compactMap(\.ttft)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

@MainActor
@Observable
final class TraySettings {
    /// Applies to the chart, its legend and the menu bar.
    var speed: SpeedMetric = SpeedMetric(rawValue: UserDefaults.standard.string(forKey: "speedMetric") ?? "") ?? .e2e {
        didSet { UserDefaults.standard.set(speed.rawValue, forKey: "speedMetric") }
    }

    var metric: TrayMetric = TrayMetric(rawValue: UserDefaults.standard.string(forKey: "trayMetric") ?? "") ?? .avg1m {
        didSet { UserDefaults.standard.set(metric.rawValue, forKey: "trayMetric") }
    }

    /// `GroupKey.id` of the series pinned to the menu bar; nil shows the main series.
    var pinned: String? = UserDefaults.standard.string(forKey: "trayPinned") {
        didSet { UserDefaults.standard.set(pinned, forKey: "trayPinned") }
    }

    func togglePin(_ key: GroupKey) {
        pinned = pinned == key.id ? nil : key.id
    }
}
