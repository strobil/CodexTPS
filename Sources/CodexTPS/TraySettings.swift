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

@MainActor
@Observable
final class TraySettings {
    var metric: TrayMetric = TrayMetric(rawValue: UserDefaults.standard.string(forKey: "trayMetric") ?? "") ?? .avg1m {
        didSet { UserDefaults.standard.set(metric.rawValue, forKey: "trayMetric") }
    }

    /// `GroupKey.id` of the series shown in the menu bar; nil means all series.
    var pinned: String? = UserDefaults.standard.string(forKey: "trayPinned") {
        didSet { UserDefaults.standard.set(pinned, forKey: "trayPinned") }
    }

    func togglePin(_ key: GroupKey) {
        pinned = pinned == key.id ? nil : key.id
    }
}
