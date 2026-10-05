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
    var label: String { "\(model) · \(effort)\(fast ? " · ⚡" : "")" }
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
struct RangePicker: View {
    let selection: ChartSelection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ChartRange.allCases) { r in
                let on = selection.range == r
                Button { selection.range = r } label: {
                    Text(r.title)
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
        let points = stats.chartPoints(range)
        let series = stats.chartSeries(range)
        let start = stats.now.addingTimeInterval(-range.duration)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                RangePicker(selection: selection)
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
                            y: .value("TPS", p.tps)
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
                            .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                tooltip(bucket: b, range: range, points: points.filter { $0.bucket == b })
                            }
                    }
                }
                .chartForegroundStyleScale(
                    domain: series.map(\.label),
                    range: series.map { SeriesPalette.color(slot: stats.slot(of: $0)) }
                )
                .chartXScale(domain: start...stats.now)
                .chartYScale(domain: .automatic(includesZero: true))
                .chartXAxis {
                    AxisMarks(values: range.ticks(until: stats.now)) { value in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                        let edge = stats.now.addingTimeInterval(-range.duration / 15)
                        if let d = value.as(Date.self), d < edge {
                            AxisValueLabel(format: .dateTime.hour().minute())
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                        AxisValueLabel()
                    }
                }
                .chartLegend(series.count > 1 ? .visible : .hidden)
                .chartXSelection(value: Binding(
                    get: { selection.bucket },
                    set: { selection.bucket = $0.map(range.bucketStart) }
                ))
                .frame(height: 140)
            }
        }
    }

    private func tooltip(bucket: Date, range: ChartRange, points: [ChartPoint]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Group {
                if range.bucket <= 60 {
                    Text(bucket, format: .dateTime.hour().minute())
                } else {
                    Text("\(bucket.formatted(.dateTime.hour().minute()))–\(bucket.addingTimeInterval(range.bucket).formatted(.dateTime.hour().minute()))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if points.isEmpty {
                Text("No responses").font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(points) { p in
                HStack(spacing: 6) {
                    Circle()
                        .fill(SeriesPalette.color(slot: stats.slot(of: p.key)))
                        .frame(width: 8, height: 8)
                    Text(p.key.label).font(.caption2)
                    Spacer(minLength: 8)
                    Text("\(Int(p.tps.rounded())) t/s · \(p.count)")
                        .font(.caption2.monospacedDigit())
                        .bold()
                }
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .fixedSize()
    }
}
