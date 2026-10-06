import AppKit
import SwiftUI

/// `CodexTPS --snapshot <out.png> [dark] [hover] [tray] [<range>]` renders the popover to a PNG and exits.
/// `CodexTPS --bench [groups]` prints how long loading stored responses took and exits.
enum Snapshot {
    @MainActor
    static func runIfRequested(stats: Stats, selection: ChartSelection, tray: TraySettings, loginItem: LoginItem) {
        let args = CommandLine.arguments
        if args.contains("--bench") {
            let started = Date()
            Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard stats.loaded else { return }
                    var usage = rusage()
                    getrusage(RUSAGE_SELF, &usage)
                    print("loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)))s, \(stats.samples.count) samples, max RSS \(usage.ru_maxrss >> 20) MB")
                    if let t = ProcessInfo.processInfo.environment["CODEX_TPS_THREAD"] {
                        for x in stats.samples where x.threadId == t {
                            print("thread sample end=\(x.end) out=\(x.outputTokens) dur=\(String(format: "%.3f", x.duration)) ttft=\(x.ttft.map { String(format: "%.3f", $0) } ?? "nil")")
                        }
                    }
                    if args.contains("groups") {
                        for (id, list) in Dictionary(grouping: stats.samples, by: \.key.id).sorted(by: { $0.key < $1.key }) {
                            print(id, list.count, list.reduce(0) { $0 + $1.outputTokens })
                        }
                    }
                    exit(0)
                }
            }
            return
        }
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        let dark = args.contains("dark")
        waitUntilLoaded(stats) {
            if let r = ChartRange.allCases.first(where: { args.contains($0.rawValue) }) { selection.range = r }
            if let b = stats.chartModel(selection.range, speed: tray.speed).points.last?.bucket, args.contains("hover") { selection.bucket = b }
            let view = VStack(alignment: .leading, spacing: 0) {
                if args.contains("tray") {
                    MenuBarLabel(stats: stats, tray: tray)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                }
                StatsView(stats: stats, selection: selection, tray: tray, loginItem: loginItem)
            }
                .frame(width: 520)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if dark { NSApp.appearance = NSAppearance(named: .darkAqua) }
            guard let img = r.nsImage, let tiff = img.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else {
                FileHandle.standardError.write("snapshot: render failed\n".data(using: .utf8)!)
                exit(1)
            }
            do {
                try png.write(to: out)
            } catch {
                FileHandle.standardError.write("snapshot: \(error.localizedDescription)\n".data(using: .utf8)!)
                exit(1)
            }
            exit(0)
        }
    }

    @MainActor
    private static func waitUntilLoaded(_ stats: Stats, then body: @escaping @MainActor () -> Void) {
        guard stats.loaded else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { waitUntilLoaded(stats, then: body) }
            return
        }
        // Let SwiftUI observe the final samples before rendering.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { body() }
    }
}
