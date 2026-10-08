import SwiftUI

@main
struct CodexTPSApp: App {
    private let stats: Stats
    private let selection = ChartSelection()
    private let tray = TraySettings()
    private let loginItem = LoginItem()
    private let setup = CodexSetup()

    init() {
        stats = Stats()
        stats.start()
        Snapshot.runIfRequested(stats: stats, selection: selection, tray: tray, loginItem: loginItem, setup: setup)
        let setup = setup
        setup.refresh()
        if !Snapshot.isRequested {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { SetupAlerts.offerIfNeeded(setup) }
        }
        let refresh = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { setup.refresh() }
        }
        refresh.tolerance = 10
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(stats: stats, selection: selection, tray: tray, loginItem: loginItem, setup: setup)
        } label: {
            MenuBarLabel(stats: stats, tray: tray)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let stats: Stats
    let tray: TraySettings
    static let staleAfter: TimeInterval = 2 * 60
    static let hideAfter: TimeInterval = Stats.pinExpiry

    var body: some View {
        // Stats.now advances every minute (every second while the popover is open), which is
        // enough for minute-precision ages. TimelineView here sent MenuBarExtra into a layout loop.
        label(at: stats.now)
    }

    @ViewBuilder
    private func label(at date: Date) -> some View {
        // Same series as the first row of the Live list (Stats.displaySeries), so the two never disagree.
        let series = stats.displaySeries(pinned: tray.pinned, speed: tray.speed)
        let v = series.flatMap { stats.trayValue(metric: tray.metric, series: $0.key.id, speed: tray.speed) }
        let silence = v.map { date.timeIntervalSince($0.end) } ?? .infinity
        if let v, silence < Self.hideAfter {
            let model = v.model.hasPrefix("gpt-") ? String(v.model.dropFirst(4)) : v.model
            if silence < Self.staleAfter {
                Text("\(v.badge)\(v.badge.isEmpty ? "" : " ")\(model) \(Int(v.tps.rounded())) t/s")
                    .monospacedDigit()
            } else {
                Text("\(model) \(Int(v.tps.rounded())) t/s · \(ago(v.end, now: date))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } else {
            Image(systemName: "gauge.with.dots.needle.33percent")
        }
    }
}
