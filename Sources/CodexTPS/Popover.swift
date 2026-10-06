import Charts
import SwiftUI

/// Fixed-size popover: MenuBarExtra does not shrink its window while open, so tabs,
/// settings and changing series counts must not change the content height.
struct PopoverView: View {
    static let size = CGSize(width: 400, height: 560)

    let stats: Stats
    let selection: ChartSelection
    let tray: TraySettings
    let loginItem: LoginItem
    let setup: CodexSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if selection.showSettings {
                    Text("Settings").font(.headline)
                } else {
                    Segmented(options: [ChartSelection.Tab.now, .compare], title: { $0 == .now ? "Now" : "Compare" }, selected: selection.tab) {
                        selection.tab = $0
                    }
                }
                Spacer()
                Button { selection.showSettings.toggle() } label: {
                    Image(systemName: selection.showSettings ? "xmark" : "gearshape")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(selection.showSettings ? "Close settings" : "Settings")
            }

            Group {
                if selection.showSettings {
                    SettingsPanel(stats: stats, tray: tray, loginItem: loginItem, setup: setup)
                } else if selection.tab == .now {
                    NowTab(stats: stats, selection: selection, tray: tray)
                } else {
                    CompareTab(stats: stats, selection: selection, tray: tray)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            Divider()
            SetupStatusRow(stats: stats, setup: setup, compact: true)
        }
        .padding(14)
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear {
            loginItem.refresh()
            setup.refresh()
        }
    }
}

// MARK: - Now

struct NowTab: View {
    let stats: Stats
    let selection: ChartSelection
    let tray: TraySettings

    var body: some View {
        let model = stats.chartModel(selection.range, speed: tray.speed)
        let active = stats.activeSeries()
        let groups = Dictionary(uniqueKeysWithValues: stats.groups.map { ($0.key, $0) })

        VStack(alignment: .leading, spacing: 12) {
            if let hero = stats.heroSeries(pinned: tray.pinned) {
                HeroBlock(stats: stats, tray: tray, key: hero, live: groups[hero], color: model.color(hero))
            } else {
                Text("No responses yet")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            }

            NowChart(stats: stats, selection: selection, model: model)

            VStack(spacing: 0) {
                ForEach(active, id: \.self) { key in
                    SeriesRow(stats: stats, tray: tray, key: key, live: groups[key], color: model.color(key))
                    Divider().opacity(0.5)
                }
            }

            let idle = stats.allSeries.filter { !active.contains($0) }
            if !idle.isEmpty {
                Text("Idle: " + idle.prefix(4).map { k in
                    "\(k.label) \(ago(groups[k]?.last.end ?? stats.now, now: stats.now))"
                }.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
            }
        }
    }
}

private struct HeroBlock: View {
    let stats: Stats
    let tray: TraySettings
    let key: GroupKey
    let live: GroupStats?
    let color: Int

    var body: some View {
        let value = stats.trayValue(metric: .avg1m, pinned: key.id, speed: tray.speed)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(SeriesPalette.color(slot: color)).frame(width: 8, height: 8)
                Text("\(key.label) · \(tray.speed.title.lowercased()), 1 min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if tray.pinned == key.id {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value.map { "\(Int($0.tps.rounded()))" } ?? "—")
                    .font(.system(size: 46, weight: .medium, design: .rounded))
                    .monospacedDigit()
                Text("t/s").font(.title3).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                stat("E2E", live?.e2e.map { "\(Int($0.rounded()))" })
                stat("Decode", live?.decode.map { "\(Int($0.rounded()))" })
                stat("TTFT", live?.ttft.map { String(format: "%.1fs", $0) })
                stat("Resp/min", (live?.count ?? 0) > 0 ? "\(live!.count)" : nil)
            }
        }
    }

    private func stat(_ label: String, _ value: String?) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value ?? "—").fontWeight(.medium).foregroundStyle(value == nil ? .tertiary : .primary)
        }
        .font(.caption.monospacedDigit())
    }
}

private struct SeriesRow: View {
    let stats: Stats
    let tray: TraySettings
    let key: GroupKey
    let live: GroupStats?
    let color: Int

    var body: some View {
        let value = stats.trayValue(metric: .avg1m, pinned: key.id, speed: tray.speed)
        HStack(spacing: 8) {
            Circle().fill(SeriesPalette.color(slot: color)).frame(width: 8, height: 8)
            Text(key.label).lineLimit(1)
            if tray.pinned == key.id {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(live?.ttft.map { String(format: "%.1fs", $0) } ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(value.map { "\(Int($0.tps.rounded()))" } ?? "—")
                .fontWeight(.medium)
                .monospacedDigit()
                .frame(minWidth: 32, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { tray.togglePin(key) }
        .help("Pin to the menu bar")
    }
}

private struct NowChart: View {
    let stats: Stats
    let selection: ChartSelection
    let model: ChartModel

    var body: some View {
        let range = selection.range
        let hovered = selection.bucket.map { b in model.points.filter { $0.bucket == b } }

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(readout(hovered, range: range))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Segmented(options: ChartSelection.nowRanges, title: \.title, selected: range) { selection.range = $0 }
            }
            Chart {
                ForEach(model.points) { p in
                    LineMark(x: .value("Time", p.bucket), y: .value("TPS", p.tps), series: .value("Segment", "\(p.key.label)#\(p.segment)"))
                        .foregroundStyle(SeriesPalette.color(slot: model.color(p.key)))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Time", p.bucket), y: .value("TPS", p.tps))
                        .foregroundStyle(SeriesPalette.color(slot: model.color(p.key)))
                        .symbolSize(12)
                }
                if let b = selection.bucket {
                    RuleMark(x: .value("Time", b))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartXScale(domain: stats.now.addingTimeInterval(-range.duration)...stats.now)
            .chartYScale(domain: .automatic(includesZero: true))
            .chartXAxis {
                AxisMarks(values: range.ticks(until: stats.now)) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                    if let d = value.as(Date.self), d < stats.now.addingTimeInterval(-range.duration / 12), d > stats.now.addingTimeInterval(-range.duration * 11 / 12) {
                        AxisValueLabel(format: range.showsDate ? .dateTime.month(.abbreviated).day() : .dateTime.hour().minute(), anchor: .top)
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                    AxisValueLabel()
                }
            }
            .chartXSelection(value: Binding(get: { selection.bucket }, set: { selection.bucket = $0.map(range.bucketStart) }))
            .frame(height: 120)
        }
    }

    /// Hovered values, or the range description when not hovering.
    private func readout(_ hovered: [ChartPoint]?, range: ChartRange) -> String {
        guard let hovered, let b = selection.bucket else { return "Last \(range.title)" }
        let time = b.formatted(range.showsDate ? .dateTime.month(.abbreviated).day().hour().minute() : .dateTime.hour().minute())
        let values = hovered.sorted { $0.tps > $1.tps }.map { "\($0.key.label) \(Int($0.tps.rounded()))" }
        return ([time] + (values.isEmpty ? ["no responses"] : values)).joined(separator: " · ")
    }
}

// MARK: - Compare

struct CompareTab: View {
    let stats: Stats
    let selection: ChartSelection
    let tray: TraySettings

    var body: some View {
        let range = selection.compareRange
        let rows = stats.distributions(range, speed: tray.speed)
        let palette = stats.chartModel(range, speed: tray.speed)
        let scale = niceMax(rows.map(\.p90).max() ?? 0)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(tray.speed.title) t/s per response")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Segmented(options: ChartSelection.compareRanges, title: \.title, selected: range) { selection.compareRange = $0 }
            }

            if rows.isEmpty {
                Text(tray.speed == .decode ? "No responses with telemetry in this range" : "No responses in this range")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 20)
            } else {
                HStack {
                    Text("Median, bar p10–p90").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Text("TTFT").font(.caption2).foregroundStyle(.tertiary).frame(width: 40, alignment: .trailing)
                }
                VStack(spacing: 10) {
                    ForEach(rows.prefix(8)) { r in
                        DistributionRow(row: r, scale: scale, color: palette.color(r.key))
                    }
                }
                if rows.count > 8 {
                    Text("+\(rows.count - 8) slower series").font(.caption2).foregroundStyle(.tertiary)
                }
                // Same columns as DistributionRow so ticks sit under the bars.
                HStack(spacing: 8) {
                    Color.clear.frame(width: 112, height: 1)
                    GeometryReader { g in
                        ForEach(Array(stride(from: 0.0, through: scale, by: scale / 4)), id: \.self) { v in
                            Text("\(Int(v))")
                                .fixedSize()
                                .position(x: g.size.width * CGFloat(v / scale), y: g.size.height / 2)
                        }
                    }
                    .frame(height: 12)
                    Color.clear.frame(width: 28, height: 1)
                    Color.clear.frame(width: 40, height: 1)
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        }
    }

    private func niceMax(_ v: Double) -> Double {
        let step = v > 100 ? 40.0 : 20.0
        return Swift.max(step * 2, (v / step).rounded(.up) * step)
    }
}

private struct DistributionRow: View {
    let row: SeriesDistribution
    let scale: Double
    let color: Int

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.key.label).font(.callout).lineLimit(1)
                Text("\(row.count) resp").font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(width: 112, alignment: .leading)

            GeometryReader { g in
                let x = { (v: Double) in g.size.width * CGFloat(min(v / scale, 1)) }
                let c = SeriesPalette.color(slot: color)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12)).frame(height: 3)
                    Capsule().fill(c.opacity(0.35))
                        .frame(width: max(x(row.p90) - x(row.p10), 4), height: 8)
                        .offset(x: x(row.p10))
                    Circle().fill(c).frame(width: 10, height: 10).offset(x: x(row.median) - 5)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 16)

            Text("\(Int(row.median.rounded()))")
                .font(.callout.weight(.medium).monospacedDigit())
                .frame(width: 28, alignment: .trailing)
            Text(row.ttft.map { String(format: "%.1fs", $0) } ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

// MARK: - Settings

struct SettingsPanel: View {
    let stats: Stats
    let tray: TraySettings
    let loginItem: LoginItem
    let setup: CodexSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            setting("Speed", note: tray.speed == .decode ? "Generation after the first token; needs telemetry" : "Request to completion, including time to first token") {
                Segmented(options: SpeedMetric.allCases, title: \.title, selected: tray.speed) { tray.speed = $0 }
            }
            setting("Menu bar", note: tray.pinned.flatMap { id in stats.allSeries.first { $0.id == id }?.label }.map { "Pinned: \($0) · tap a series on Now to change" } ?? "All series · tap a series on Now to pin it") {
                Segmented(options: TrayMetric.allCases, title: \.title, selected: tray.metric) { tray.metric = $0 }
            }
            VStack(alignment: .leading, spacing: 8) {
                checkbox("Split series by reasoning effort", on: stats.splitByEffort) {
                    stats.splitByEffort.toggle()
                    tray.pinned = nil
                }
                checkbox("Launch at login", on: loginItem.isOn) { loginItem.toggle() }
                if loginItem.status == .requiresApproval {
                    Button("Allow in System Settings") { loginItem.openSettings() }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Codex telemetry").font(.caption).foregroundStyle(.secondary)
                SetupStatusRow(stats: stats, setup: setup, compact: false)
            }
            Spacer()
            HStack {
                Text("CodexTPS \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func setting<C: View>(_ title: String, note: String, @ViewBuilder control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                control()
            }
            Text(note).font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func checkbox(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: on ? "checkmark.square.fill" : "square")
                .font(.callout)
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }
}

func ago(_ date: Date, now: Date) -> String {
    let s = Int(now.timeIntervalSince(date))
    if s < 60 { return "\(max(s, 0))s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}
