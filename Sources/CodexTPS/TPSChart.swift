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
    var label: String { self == .other ? "Other" : "\(model) · \(effort)\(tierBadge.isEmpty ? "" : " · \(tierBadge)")" }
}

@MainActor
@Observable
final class ChartSelection {
    var bucket: Date?
    var range: ChartRange = ChartRange(rawValue: UserDefaults.standard.string(forKey: "chartRange") ?? "") ?? .m30 {
        didSet {
            bucket = nil
            UserDefaults.standard.set(range.rawValue, forKey: "chartRange")
        }
    }
}

/// Plain SwiftUI segmented control; unlike `Picker(.segmented)` it also renders in `ImageRenderer` snapshots.
struct Segmented<T: Hashable>: View {
    let options: [T]
    let title: (T) -> String
    let selected: T
    let onSelect: (T) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let on = option == selected
                Button { onSelect(option) } label: {
                    Text(title(option))
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

struct TPSChart: View {
    let stats: Stats
    let selection: ChartSelection

    var body: some View {
        let range = selection.range
        let model = stats.chartModel(range)
        let points = model.points
        let start = stats.now.addingTimeInterval(-range.duration)

        let hovered = selection.bucket.map { b in points.filter { $0.bucket == b } }

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let b = selection.bucket {
                    Text(intervalTitle(b, range: range))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Segmented(options: ChartRange.allCases, title: \.title, selected: selection.range) { selection.range = $0 }
            }

            if points.isEmpty {
                Text("No responses")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                Chart {
                    ForEach(points) { p in
                        LineMark(
                            x: .value("Time", p.bucket),
                            y: .value("TPS", p.tps),
                            series: .value("Segment", "\(p.key.label)#\(p.segment)")
                        )
                        .foregroundStyle(by: .value("Series", p.key.label))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)

                        PointMark(
                            x: .value("Time", p.bucket),
                            y: .value("TPS", p.tps)
                        )
                        .foregroundStyle(by: .value("Series", p.key.label))
                        .symbolSize(18)
                    }

                    if let b = selection.bucket {
                        RuleMark(x: .value("Time", b))
                            .foregroundStyle(Color.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                }
                .chartForegroundStyleScale(
                    domain: model.legend.map(\.label),
                    range: model.legend.map { SeriesPalette.color(slot: model.color($0)) }
                )
                .chartXScale(domain: start...stats.now)
                .chartYScale(domain: .automatic(includesZero: true))
                .chartXAxis {
                    AxisMarks(values: range.ticks(until: stats.now)) { value in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                        let edge = stats.now.addingTimeInterval(-range.duration / 15)
                        if let d = value.as(Date.self), d < edge {
                            if range.showsDate {
                                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            } else {
                                AxisValueLabel(format: .dateTime.hour().minute())
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                        AxisValueLabel()
                    }
                }
                .chartLegend(.hidden)
                .chartXSelection(value: Binding(
                    get: { selection.bucket },
                    set: { selection.bucket = $0.map(range.bucketStart) }
                ))
                .frame(height: 140)
            }

            legend(model, hovered: hovered)
        }
    }

    /// Doubles as the hover readout, so values never cover the plot.
    /// Lists the last day's series plus older ones the range reaches, dimming those absent
    /// from the range, so switching between short ranges keeps the popover height.
    private func legend(_ model: ChartModel, hovered: [ChartPoint]?) -> some View {
        // Always as tall as the largest legend (8 colors + Other in two columns) so the
        // popover keeps its height across ranges; MenuBarExtra does not shrink while open.
        ZStack(alignment: .topLeading) {
            VStack(spacing: 4) {
                ForEach(0..<(SeriesPalette.count + 2) / 2, id: \.self) { _ in
                    Text(" ").font(.caption)
                }
            }
            .hidden()
            legendGrid(model, hovered: hovered)
        }
    }

    private func legendGrid(_ model: ChartModel, hovered: [ChartPoint]?) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 16, alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(model.legend, id: \.self) { key in
                HStack(spacing: 6) {
                    Circle()
                        .fill(SeriesPalette.color(slot: model.color(key)))
                        .frame(width: 8, height: 8)
                    Text(key.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let hovered {
                        if let p = hovered.first(where: { $0.key == key }) {
                            Text("\(Int(p.tps.rounded())) t/s · \(p.count)").bold()
                        } else {
                            Text("—").foregroundStyle(.tertiary)
                        }
                    }
                }
                .font(.caption.monospacedDigit())
                .opacity(model.visible.contains(key) ? 1 : 0.4)
            }
        }
    }

    private func intervalTitle(_ bucket: Date, range: ChartRange) -> String {
        let end = bucket.addingTimeInterval(range.bucket)
        if range.bucket >= 86400 {
            let f = Date.FormatStyle.dateTime.month(.abbreviated).day()
            return range.bucket == 86400 ? bucket.formatted(f) : "\(bucket.formatted(f))–\(end.addingTimeInterval(-1).formatted(f))"
        }
        let f = range.showsDate ? Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute() : .dateTime.hour().minute()
        if range.bucket < 60 { return bucket.formatted(f.second()) }
        if range.bucket == 60 { return bucket.formatted(f) }
        return "\(bucket.formatted(f))–\(end.formatted(.dateTime.hour().minute()))"
    }
}
