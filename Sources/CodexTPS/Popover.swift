import Charts
import SwiftUI

/// Fixed-size popover: MenuBarExtra does not shrink its window while open, so tabs,
/// settings and changing series counts must not change the content height.
struct PopoverView: View {
    static let size = CGSize(width: 400, height: 400)

    let stats: Stats
    let selection: ChartSelection
    let tray: TraySettings
    let loginItem: LoginItem
    let setup: CodexSetup

    var body: some View {
        let status = SetupStatusRow(stats: stats, setup: setup, compact: true)
        VStack(spacing: 0) {
            Group {
                switch selection.tab {
                case .live: NowTab(stats: stats, selection: selection, tray: tray)
                case .models: CompareTab(stats: stats, selection: selection, tray: tray)
                case .settings: SettingsPanel(stats: stats, tray: tray, loginItem: loginItem, setup: setup)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding([.horizontal, .top], 14)
            .padding(.bottom, 10)

            // Telemetry state is shown here only when it needs attention; Settings always has it.
            if !status.isHealthy, selection.tab != .settings {
                status
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            Divider()
            TabBar(selection: selection, settingsBadge: status.isHealthy ? nil : status.indicatorColor)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // Drives the per-second clock: onAppear/onDisappear are unreliable for MenuBarExtra.
        .background(WindowVisibility { window, left, visible in
            // A probe leaving a window that is no longer the popover must not stop the clock. A window
            // being deallocated already reads as nil; if it was the popover, the tick stops the clock.
            if window == nil, left == nil || stats.popoverWindow !== left { return }
            stats.popoverWindow = window
            stats.setVisible(visible)
        })
        .onAppear {
            loginItem.refresh()
            setup.refresh()
            // Extra trigger: a quick close and reopen can coalesce into no occlusion change.
            stats.setVisible(true)
        }
    }
}

private struct TabBar: View {
    let selection: ChartSelection
    /// Dot on the Settings tab when telemetry needs attention.
    let settingsBadge: Color?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ChartSelection.Tab.allCases, id: \.self) { tab in
                let on = selection.tab == tab
                Button { selection.tab = tab } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 15, weight: on ? .semibold : .regular))
                            .frame(height: 18)
                            .overlay(alignment: .topTrailing) {
                                if tab == .settings, let badge = settingsBadge {
                                    Circle().fill(badge).frame(width: 7, height: 7).offset(x: 4, y: -2)
                                }
                            }
                        Text(tab.title).font(.caption2.weight(on ? .semibold : .regular))
                    }
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Reports whether the hosting window is on screen. MenuBarExtra does not reliably send
/// onAppear/onDisappear for every open and close, but the window's occlusion state changes.
private struct WindowVisibility: NSViewRepresentable {
    /// (current window or nil, window just left or nil, visible)
    let onChange: @MainActor (NSWindow?, NSWindow?, Bool) -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onChange = onChange
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.onChange = onChange
    }

    final class Probe: NSView {
        var onChange: (@MainActor (NSWindow?, NSWindow?, Bool) -> Void)?
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
        private weak var current: NSWindow?

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            let left = current
            current = window
            guard let window else {
                onChange?(nil, left, false)
                return
            }
            // Occlusion covers open and close; becoming key also catches a reopen that the
            // window server folded into no occlusion change.
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            report()
        }

        private func report() {
            onChange?(window, nil, window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false)
        }
    }
}

// MARK: - Live

struct NowTab: View {
    let stats: Stats
    let selection: ChartSelection
    let tray: TraySettings

    var body: some View {
        let model = stats.chartModel(selection.range, speed: tray.speed)
        let active = stats.activeSeries()
        let shown = stats.displaySeries(pinned: tray.pinned, speed: tray.speed)?.key
        // The list doubles as the chart's legend: the series the menu bar shows, the ones
        // answering now, then the rest of the range by how much of the chart they make up.
        let weight = Dictionary(grouping: model.points, by: \.key).mapValues { $0.reduce(0) { $0 + $1.count } }
        var listed: [GroupKey] = []
        for key in [shown].compactMap({ $0 }) + active.filter({ weight[$0] != nil || model.points.isEmpty })
            + weight.keys.filter({ !active.contains($0) }).sorted(by: { (weight[$0]!, $1.id) > (weight[$1]!, $0.id) })
            where !listed.contains(key) {
            listed.append(key)
        }
        // nil when not hovering; .some(nil) when the series has no point at the hovered time.
        let hoveredPoint = { (key: GroupKey) in selection.bucket.map { b in model.points.first { $0.key == key && $0.bucket == b } } }
        let slots = min(4, listed.count)
        // While hovering, the rows are the series with a point at that time, in list order.
        let rows = selection.bucket == nil ? Array(listed.prefix(slots))
            : Array(listed.filter { (hoveredPoint($0) ?? nil) != nil }.prefix(slots))
        // Whether the menu bar shows a value now rather than only its icon.
        let inMenuBar = shown.flatMap { stats.trayValue(metric: tray.metric, series: $0.id, speed: tray.speed) }
            .map { stats.now.timeIntervalSince($0.end) < MenuBarLabel.hideAfter } ?? false

        return VStack(alignment: .leading, spacing: 12) {
            // Takes whatever height the series list leaves, so a quiet moment shows a bigger chart.
            NowChart(stats: stats, selection: selection, model: model, shown: shown, speed: tray.speed)
                .frame(maxHeight: .infinity)

            if listed.isEmpty {
                Text("No responses yet").font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(rows, id: \.self) { key in
                    SeriesRow(stats: stats, tray: tray, key: key, ttft: stats.recentTTFT(key, speed: tray.speed), active: active.contains(key),
                              inMenuBar: inMenuBar && key == shown, hovered: hoveredPoint(key))
                    Divider().opacity(0.5)
                }
                // Blank rows keep the list's height while hovering, so the chart does not jump.
                ForEach(rows.count..<slots, id: \.self) { _ in
                    SeriesRow(stats: stats, tray: tray, key: listed[0], ttft: nil, active: false).hidden()
                    Divider().hidden()
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct SeriesRow: View {
    let stats: Stats
    let tray: TraySettings
    let key: GroupKey
    /// Mean TTFT over the minute before the latest response.
    let ttft: TimeInterval?
    /// Answered within the last few minutes; idle rows are dimmed and show when they last ran.
    let active: Bool
    /// The series the menu bar shows.
    var inMenuBar = false
    /// While the chart is hovered: this series' point in the hovered bucket, if it has one.
    var hovered: ChartPoint?? = nil

    var body: some View {
        let current = stats.trayValue(metric: .avg1m, series: key.id, speed: tray.speed)?.tps
        let value = hovered.map { $0?.tps } ?? current
        let lit = hovered.map { $0 != nil } ?? active
        HStack(spacing: 8) {
            SeriesMark(key: key, size: 13)
            Text(key.label).lineLimit(1)
            // Codex threads, subagents included, that fed this series in the last ten minutes.
            let threads = stats.activeThreads(key)
            if threads > 1 {
                Text("\(threads) threads").font(.caption).foregroundStyle(.tertiary)
                    .help("Codex threads with recorded responses in the last 10 minutes, subagents included")
            }
            if tray.pinned == key.id {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tertiary)
            } else if inMenuBar {
                Image(systemName: "menubar.rectangle").font(.caption2).foregroundStyle(.tertiary)
                    .help("Shown in the menu bar")
            }
            Spacer()
            Text(detail)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(value.map { "\(Int($0.rounded()))" } ?? "—")
                .fontWeight(.medium)
                .monospacedDigit()
                .frame(minWidth: 32, alignment: .trailing)
        }
        .font(.callout)
        .opacity(lit ? 1 : 0.55)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { tray.togglePin(key) }
        .help("Pin to the menu bar")
    }

    /// TTFT of the hovered point or of the last minute, or how long ago an idle series ran.
    private var detail: String {
        let ttft = { (t: TimeInterval?) in t.map { String(format: "%.1fs", $0) } ?? "" }
        if let hovered { return ttft(hovered?.ttft) }
        if active { return ttft(self.ttft) }
        return stats.lastSample(key.id, speed: .e2e).map { "\(ago($0.end, now: stats.now)) ago" } ?? ""
    }
}

private struct NowChart: View {
    let stats: Stats
    let selection: ChartSelection
    let model: ChartModel
    /// The menu bar series, drawn with a fill under its line.
    let shown: GroupKey?
    let speed: SpeedMetric

    var body: some View {
        let range = selection.range
        let top = yTop()

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                Segmented(options: ChartSelection.ranges, title: \.title, selected: range) { selection.range = $0 }
            }
            Chart {
                ForEach(model.points) { p in
                    // Points above the axis sit on its top edge as triangles; hovering shows their value.
                    let above = p.tps > top
                    let y = min(p.tps, top)
                    if p.key == shown {
                        let c = SeriesPalette.color(p.key.family)
                        AreaMark(x: .value("Time", p.bucket), y: .value("TPS", y), series: .value("Segment", "\(p.key.label)#\(p.segment)"), stacking: .unstacked)
                            .foregroundStyle(LinearGradient(colors: [c.opacity(0.28), c.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                    }
                    LineMark(x: .value("Time", p.bucket), y: .value("TPS", y), series: .value("Segment", "\(p.key.label)#\(p.segment)"))
                        .foregroundStyle(SeriesPalette.color(p.key.family))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Time", p.bucket), y: .value("TPS", y))
                        .foregroundStyle(SeriesPalette.color(p.key.family))
                        .symbol(above ? .triangle : .circle)
                        .symbolSize(above ? 36 : 12)
                }
                if let b = selection.bucket {
                    RuleMark(x: .value("Time", b))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .trailing, alignment: .top, spacing: 3, overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                            Text(b.formatted(range.bucket >= 86400 ? .dateTime.month(.abbreviated).day()
                                : range.showsDate ? .dateTime.month(.abbreviated).day().hour().minute() : .dateTime.hour().minute()))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 3)
                                .background(.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                        }
                }
            }
            .chartXScale(domain: stats.now.addingTimeInterval(-range.duration)...stats.now)
            .chartYScale(domain: 0...top)
            .chartXAxis {
                AxisMarks(values: range.ticks(until: stats.now)) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                    if let d = value.as(Date.self), d < stats.now.addingTimeInterval(-range.duration / 12), d > stats.now.addingTimeInterval(-range.duration * 11 / 12) {
                        AxisValueLabel(format: range.showsDate ? .dateTime.month(.abbreviated).day() : .dateTime.hour().minute(), anchor: .top)
                    }
                }
            }
            .chartYAxisLabel(position: .top, alignment: .leading, spacing: 4) {
                Text("\(speed.title) t/s").font(.caption2).foregroundStyle(.tertiary)
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                    AxisValueLabel()
                }
            }
            .chartXSelection(value: Binding(get: { selection.bucket }, set: { selection.bucket = $0.map(range.bucketStart) }))
            .frame(minHeight: 96, maxHeight: .infinity)
        }
    }

    /// Top of the y axis. A few points far above the rest (e.g. short side requests on a fast
    /// model) would flatten every line, so the axis covers the others and the menu bar series;
    /// when more than a quarter of the points are that high, they are no outliers and all fit.
    private func yTop() -> Double {
        let values = model.points.map(\.tps).sorted()
        guard let highest = values.last else { return 10 }
        guard values.count >= 4 else { return niceCeiling(highest) }
        let q1 = values.quantile(0.25), q3 = values.quantile(0.75)
        let fence = q3 + 3 * max(q3 - q1, q3 * 0.25)
        let outliers = model.points.filter { $0.tps > fence && $0.key != shown }.count
        guard outliers > 0, outliers * 4 <= values.count else { return niceCeiling(highest) }
        let kept = model.points.filter { $0.tps <= fence || $0.key == shown }.map(\.tps).max() ?? fence
        return niceCeiling(kept * 1.1)
    }

    /// The smallest round number (1, 1.5, 2, 2.5, 3, 4, 5, 6 or 8 times a power of ten) at or above `v`.
    private func niceCeiling(_ v: Double) -> Double {
        let magnitude = pow(10, (log10(max(v, 1))).rounded(.down))
        return [1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10].map { $0 * magnitude }.first { $0 >= v } ?? v
    }
}

// MARK: - Models

struct CompareTab: View {
    let stats: Stats
    let selection: ChartSelection
    let tray: TraySettings

    var body: some View {
        let range = selection.compareRange
        let rows = stats.distributions(range, speed: tray.speed)
        let scale = niceMax(rows.map(\.p90).max() ?? 0)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(tray.speed.title) t/s per response")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Segmented(options: ChartSelection.ranges, title: \.title, selected: range) { selection.compareRange = $0 }
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
                    ForEach(rows.prefix(6)) { r in
                        DistributionRow(row: r, scale: scale)
                    }
                }
                if rows.count > 6 {
                    Text("+\(rows.count - 6) slower series").font(.caption2).foregroundStyle(.tertiary)
                }
                // Same columns as DistributionRow so ticks sit under the bars.
                HStack(spacing: 8) {
                    Color.clear.frame(width: 17, height: 1)
                    Color.clear.frame(width: 128, height: 1)
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

    var body: some View {
        HStack(spacing: 8) {
            SeriesMark(key: row.key, size: 13)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.key.label).font(.callout).lineLimit(1).minimumScaleFactor(0.8)
                Text("\(row.count) resp").font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(width: 128, alignment: .leading)

            GeometryReader { g in
                let x = { (v: Double) in g.size.width * CGFloat(min(v / scale, 1)) }
                let c = SeriesPalette.color(row.key.family)
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
            Text("Settings").font(.headline)
            setting("Speed", note: tray.speed == .decode ? "Generation after the first token; needs telemetry" : "Request to completion, including time to first token") {
                Segmented(options: SpeedMetric.allCases, title: \.title, selected: tray.speed) { tray.speed = $0 }
            }
            setting("Menu bar", note: menuBarNote) {
                if tray.pinned != nil {
                    // A pin can outlive its row on Live, so it can always be cleared here.
                    Button("Unpin") { tray.pinned = nil }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                }
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

    private var menuBarNote: String {
        guard let id = tray.pinned else { return "Main series (most tokens lately) · tap a series on Live to pin it" }
        let label = stats.lastSample(id, speed: .e2e)?.key.label ?? id.split(separator: "|").first.map(String.init) ?? id
        switch stats.displaySeries(pinned: id, speed: tray.speed)?.reason {
        case .pinExpired: return "Pinned: \(label), silent for over an hour, so the main series is shown"
        case .pinMissing: return "Pinned: \(label), which has no \(tray.speed == .decode ? "decode " : "")data, so the main series is shown"
        default: return "Pinned: \(label) · tap a series on Live to change"
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
