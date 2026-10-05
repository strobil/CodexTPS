import AppKit
import SwiftUI

/// `CodexTPS --snapshot <out.png> [dark] [hover] [tray] [m30|h2|h5|h10]` renders the popover to a PNG and exits.
enum Snapshot {
    @MainActor
    static func runIfRequested(stats: Stats, selection: ChartSelection, tray: TraySettings) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        let dark = args.contains("dark")
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if let r = ChartRange.allCases.first(where: { args.contains($0.rawValue) }) { selection.range = r }
            if let b = stats.chartPoints(selection.range).last?.bucket, args.contains("hover") { selection.bucket = b }
            let view = VStack(alignment: .leading, spacing: 0) {
                if args.contains("tray") {
                    MenuBarLabel(stats: stats, tray: tray)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                }
                StatsView(stats: stats, selection: selection, tray: tray)
            }
                .frame(width: 520)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if dark { NSApp.appearance = NSAppearance(named: .darkAqua) }
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: out)
            }
            exit(0)
        }
    }
}
