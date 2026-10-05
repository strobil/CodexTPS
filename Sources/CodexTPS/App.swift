import SwiftUI

@main
struct CodexTPSApp: App {
    private let stats: Stats
    private let selection = ChartSelection()

    init() {
        stats = Stats()
        stats.start()
        Snapshot.runIfRequested(stats: stats, selection: selection)
    }

    var body: some Scene {
        MenuBarExtra {
            StatsView(stats: stats, selection: selection)
        } label: {
            MenuBarLabel(stats: stats)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let stats: Stats

    var body: some View {
        if let s = stats.latest {
            Text("\(s.key.tierBadge)\(Int(s.tps.rounded())) t/s")
                .monospacedDigit()
        } else {
            Text("— t/s")
        }
    }
}

struct StatsView: View {
    let stats: Stats
    let selection: ChartSelection

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
                        Text("Effort")
                        Text("Tier")
                        Text("Last").gridColumnAlignment(.trailing)
                        Text("Avg").gridColumnAlignment(.trailing)
                        Text("Count").gridColumnAlignment(.trailing)
                        Text("Ago").gridColumnAlignment(.trailing)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Divider()

                    ForEach(stats.groups) { g in
                        GridRow {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(SeriesPalette.color(slot: stats.slot(of: g.key)))
                                    .frame(width: 8, height: 8)
                                Text(g.key.model)
                            }
                            Text(g.key.effort)
                            Text(g.key.tierBadge.isEmpty ? "–" : g.key.tierBadge)
                            Text("\(Int(g.last.tps.rounded()))")
                            if let avg = g.avgTPS {
                                Text("\(Int(avg.rounded()))").bold()
                                Text("\(g.count)")
                            } else {
                                Text("—").foregroundStyle(.tertiary)
                                Text("—").foregroundStyle(.tertiary)
                            }
                            Text(ago(g.last.end)).foregroundStyle(.secondary)
                        }
                        .monospacedDigit()
                    }
                }
            }

            Divider()

            TPSChart(stats: stats, selection: selection)

            Divider()

            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(minWidth: 460)
        // Without an ideal height MenuBarExtra sizes its window larger than the content
        // and centers it, leaving empty bands above and below.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func ago(_ date: Date) -> String {
        let s = Int(stats.now.timeIntervalSince(date))
        if s < 60 { return "\(max(s, 0))s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
}
