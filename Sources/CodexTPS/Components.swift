import AppKit
import Charts
import Observation
import SwiftUI

/// One color per model family, so every Sol series is orange and every Luna series blue,
/// whatever the version or tier.
enum SeriesPalette {
    enum Family: Int, CaseIterable {
        case astra, sol, terra, luna, other

        init(model: String) {
            let words = Set(model.lowercased().split { !$0.isLetter }.map(String.init))
            self = words.contains("astra") ? .astra : words.contains("sol") ? .sol : words.contains("terra") ? .terra : words.contains("luna") ? .luna : .other
        }

        var symbol: String {
            switch self {
            case .astra: "sparkle"
            case .sol: "sun.max.fill"
            case .terra: "globe.europe.africa.fill"
            case .luna: "moon.fill"
            case .other: "circle.fill"
            }
        }
    }

    // In Family order: astra violet, sol orange, terra green, luna blue, other models teal.
    private static let light: [UInt32] = [0xab5ade, 0xe8590c, 0x2f9e44, 0x1c7ed6, 0x0c9aa0]
    private static let dark: [UInt32] = [0xca7cfe, 0xff922b, 0x51cf66, 0x62a7fd, 0x22b8c4]
    static func color(_ family: Family) -> Color {
        let l = light[family.rawValue], d = dark[family.rawValue]
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? d : l)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }
}

extension GroupKey {
    var label: String {
        ([model, effort, tierBadge].filter { !$0.isEmpty }).joined(separator: " · ")
    }

    var family: SeriesPalette.Family { SeriesPalette.Family(model: model) }
}

@MainActor
@Observable
final class ChartSelection {
    enum Tab: String, CaseIterable {
        case live, models, settings

        var title: String {
            switch self {
            case .live: "Live"
            case .models: "Models"
            case .settings: "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .live: "waveform.path.ecg"
            case .models: "chart.bar.xaxis"
            case .settings: "gearshape"
            }
        }
    }

    static let nowRanges: [ChartRange] = [.m30, .h3, .h24, .d7]
    static let compareRanges: [ChartRange] = [.h1, .h24, .d7, .d30]

    /// Settings is not remembered, so the popover reopens on data.
    var tab = Tab(rawValue: UserDefaults.standard.string(forKey: "tab") ?? "").flatMap { $0 == .settings ? nil : $0 } ?? .live {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "tab") }
    }
    /// Hovered chart bucket on the Now tab.
    var bucket: Date?
    var range: ChartRange = ChartSelection.stored("chartRange", in: nowRanges, default: .m30) {
        didSet {
            bucket = nil
            UserDefaults.standard.set(range.rawValue, forKey: "chartRange")
        }
    }
    var compareRange: ChartRange = ChartSelection.stored("compareRange", in: compareRanges, default: .h24) {
        didSet { UserDefaults.standard.set(compareRange.rawValue, forKey: "compareRange") }
    }

    private static func stored(_ key: String, in allowed: [ChartRange], default d: ChartRange) -> ChartRange {
        ChartRange(rawValue: UserDefaults.standard.string(forKey: key) ?? "").flatMap { allowed.contains($0) ? $0 : nil } ?? d
    }
}

/// Plain SwiftUI segmented control; unlike `Picker(.segmented)` it also renders in `ImageRenderer` snapshots.
struct Segmented<T: Hashable>: View {
    let options: [T]
    let title: (T) -> String
    let selected: T
    /// Stretch segments to share the full width.
    var fill = false
    let onSelect: (T) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let on = option == selected
                Button { onSelect(option) } label: {
                    Text(title(option))
                        .lineLimit(1)
                        .fixedSize()
                        .frame(maxWidth: fill ? .infinity : nil)
                        .font(.caption.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? .primary : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
    }
}
