import AppKit
import Charts
import Observation
import SwiftUI

enum SeriesPalette {
    private static let light: [UInt32] = [0x2a78d6, 0xeb6834, 0x1baf7a, 0xeda100, 0xe87ba4, 0x008300, 0x4a3aa7, 0xe34948]
    private static let dark: [UInt32] = [0x3987e5, 0xd95926, 0x199e70, 0xc98500, 0xd55181, 0x008300, 0x9085e9, 0xe66767]
    private static let other = Color(nsColor: .tertiaryLabelColor)

    static var count: Int { light.count }

    static func color(slot: Int) -> Color {
        guard slot < light.count else { return other }
        let l = light[slot], d = dark[slot]
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
        if self == .other { return "Other" }
        return ([model, effort, tierBadge].filter { !$0.isEmpty }).joined(separator: " · ")
    }
}

@MainActor
@Observable
final class ChartSelection {
    enum Tab: String { case now, compare }

    static let nowRanges: [ChartRange] = [.m30, .h3, .h24, .d7]
    static let compareRanges: [ChartRange] = [.h1, .h24, .d7, .d30]

    var tab = Tab(rawValue: UserDefaults.standard.string(forKey: "tab") ?? "") ?? .now {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "tab") }
    }
    var showSettings = false
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
