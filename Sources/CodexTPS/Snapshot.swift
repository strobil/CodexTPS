import AppKit
import SwiftUI

/// `CodexTPS --snapshot <out.png> [live|models|settings] [dark] [hover] [tray] [<range>]` renders the popover to a PNG and exits.
/// `CodexTPS --bench [groups]` prints how long loading stored responses took and exits.
enum Snapshot {
    @MainActor
    static var isRequested: Bool {
        CommandLine.arguments.contains { ["--snapshot", "--bench", "--setup-status", "--setup-install", "--setup-uninstall"].contains($0) }
    }

    @MainActor
    static func runIfRequested(stats: Stats, selection: ChartSelection, tray: TraySettings, loginItem: LoginItem, setup: CodexSetup) {
        let args = CommandLine.arguments
        // Headless setup commands (honour CODEX_HOME).
        for (flag, action) in [("--setup-install", setup.install), ("--setup-uninstall", setup.uninstall), ("--setup-status", setup.refresh)]
        where args.contains(flag) {
            action()
            print("config: \(setup.configURL.path)\nstate: \(setup.state)\nstale servers: \(setup.staleServers)\nerror: \(setup.error ?? "-")")
            exit(setup.error == nil ? 0 : 1)
        }
        if args.contains("--bench") {
            let started = Date()
            Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard stats.loaded else { return }
                    var usage = rusage()
                    getrusage(RUSAGE_SELF, &usage)
                    print("loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)))s, \(stats.samples.count) samples, \(stats.allSeries.count) series in 24h, max RSS \(usage.ru_maxrss >> 20) MB")
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
            if let tab = ChartSelection.Tab.allCases.first(where: { args.contains($0.rawValue) }) { selection.tab = tab }
            if let r = ChartRange.allCases.first(where: { args.contains($0.rawValue) }) {
                if ChartSelection.nowRanges.contains(r) { selection.range = r }
                if ChartSelection.compareRanges.contains(r) { selection.compareRange = r }
            }
            if let b = stats.chartModel(selection.range, speed: tray.speed).points.last?.bucket, args.contains("hover") { selection.bucket = b }
            let view = VStack(alignment: .leading, spacing: 0) {
                if args.contains("tray") {
                    MenuBarLabel(stats: stats, tray: tray)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                }
                PopoverView(stats: stats, selection: selection, tray: tray, loginItem: loginItem, setup: setup)
            }
                .frame(width: PopoverView.size.width)
                .environment(\.colorScheme, dark ? .dark : .light)
            // Draw through AppKit in a real (transparent) window on the menu material, like the
            // MenuBarExtra window, rather than ImageRenderer, which skips native controls and materials.
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let background = NSVisualEffectView(frame: host.frame)
            background.material = .menu
            background.blendingMode = .withinWindow
            background.state = .active
            background.addSubview(host)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = background
            window.alphaValue = 0
            window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                background.layoutSubtreeIfNeeded()
                guard let rep = background.bitmapImageRepForCachingDisplay(in: background.bounds) else {
                    FileHandle.standardError.write("snapshot: render failed\n".data(using: .utf8)!)
                    exit(1)
                }
                background.cacheDisplay(in: background.bounds, to: rep)
                let png = rep.representation(using: .png, properties: [:])!
                do {
                    try png.write(to: out)
                } catch {
                    FileHandle.standardError.write("snapshot: \(error.localizedDescription)\n".data(using: .utf8)!)
                    exit(1)
                }
                exit(0)
            }
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
