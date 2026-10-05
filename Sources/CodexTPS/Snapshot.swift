import AppKit
import SwiftUI

/// `CodexTPS --snapshot <out.png> [dark] [hover] [m30|h2|h5|h10]` renders the popover to a PNG and exits.
enum Snapshot {
    @MainActor
    static func runIfRequested(stats: Stats, selection: ChartSelection) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        let dark = args.contains("dark")
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if let r = ChartRange.allCases.first(where: { args.contains($0.rawValue) }) { selection.range = r }
            if let b = stats.chartPoints(selection.range).last?.bucket, args.contains("hover") { selection.bucket = b }
            let view = StatsView(stats: stats, selection: selection)
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
