import SwiftUI

@main
struct CodexTPSApp: App {
    private let stats: Stats
    private let selection = ChartSelection()
    private let tray = TraySettings()
    private let loginItem = LoginItem()

    init() {
        stats = Stats()
        stats.start()
        Snapshot.runIfRequested(stats: stats, selection: selection, tray: tray, loginItem: loginItem)
    }

    var body: some Scene {
        MenuBarExtra {
            StatsView(stats: stats, selection: selection, tray: tray, loginItem: loginItem)
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

struct StatsView: View {
    let stats: Stats
    let selection: ChartSelection
    let tray: TraySettings
    let loginItem: LoginItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Last minute")
                .font(.headline)

            if stats.groups.isEmpty {
                Text("No responses")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("Model")
                        if stats.splitByEffort { Text("Effort") }
                        Text("Tier")
                        Text("E2E").gridColumnAlignment(.trailing)
                        Text("Decode").gridColumnAlignment(.trailing)
                        Text("TTFT").gridColumnAlignment(.trailing)
                        Text("Count").gridColumnAlignment(.trailing)
                        Text("Ago").gridColumnAlignment(.trailing)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Divider()

                    let model = stats.chartModel(selection.range, speed: tray.speed)
                    ForEach(stats.groups) { g in
                        GridRow {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(SeriesPalette.color(slot: model.color(g.key)))
                                    .frame(width: 8, height: 8)
                                Text(g.key.model)
                                if tray.pinned == g.key.id {
                                    Image(systemName: "pin.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if stats.splitByEffort { Text(g.key.effort) }
                            Text(g.key.tierBadge.isEmpty ? "–" : g.key.tierBadge)
                            cell(g.e2e.map { "\(Int($0.rounded()))" }, bold: tray.speed == .e2e)
                            cell(g.decode.map { "\(Int($0.rounded()))" }, bold: tray.speed == .decode)
                            cell(g.ttft.map { String(format: "%.1fs", $0) })
                            cell(g.count > 0 ? "\(g.count)" : nil)
                            Text(ago(g.last.end)).foregroundStyle(.secondary)
                        }
                        .monospacedDigit()
                        .contentShape(Rectangle())
                        .onTapGesture { tray.togglePin(g.key) }
                        .help("Show only this series in the menu bar")
                    }
                }
            }

            Divider()

            TPSChart(stats: stats, selection: selection, tray: tray)

            Divider()

            HStack(spacing: 8) {
                Text("Speed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)
                Segmented(options: SpeedMetric.allCases, title: \.title, selected: tray.speed) { tray.speed = $0 }
                Text(tray.speed == .decode ? "after first token, telemetry only" : "incl. time to first token")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            HStack(spacing: 8) {
                Text("Menu bar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)
                Segmented(options: TrayMetric.allCases, title: \.title, selected: tray.metric) { tray.metric = $0 }
                Text(pinnedLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Button {
                    stats.splitByEffort.toggle()
                    // A pin made under the other grouping no longer names a series.
                    tray.pinned = nil
                } label: {
                    Label("Split by effort", systemImage: stats.splitByEffort ? "checkmark.square.fill" : "square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Button { loginItem.toggle() } label: {
                    Label("Launch at login", systemImage: loginItem.isOn ? "checkmark.square.fill" : "square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                if loginItem.status == .requiresApproval {
                    Button("Allow in System Settings") { loginItem.openSettings() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.tint)
                } else if let error = loginItem.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 520)
        // Without an ideal height MenuBarExtra sizes its window larger than the content
        // and centers it, leaving empty bands above and below.
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { loginItem.refresh() }
    }

    private var pinnedLabel: String {
        guard let id = tray.pinned else { return "all series" }
        return stats.allSeries.first { $0.id == id }?.label ?? "pinned series idle"
    }

    @ViewBuilder
    private func cell(_ value: String?, bold: Bool = false) -> some View {
        if let value {
            Text(value).fontWeight(bold ? .bold : .regular)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    private func ago(_ date: Date) -> String {
        let s = Int(stats.now.timeIntervalSince(date))
        if s < 60 { return "\(max(s, 0))s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
}
