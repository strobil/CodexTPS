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

    var body: some View {
        if let v = stats.trayValue(metric: tray.metric, pinned: tray.pinned, speed: tray.speed) {
            Text("\(v.badge)\(Int(v.tps.rounded())) t/s")
                .monospacedDigit()
        } else {
            Text("— t/s")
        }
    }
}
