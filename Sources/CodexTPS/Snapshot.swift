import AppKit
import SwiftUI

/// `CodexTPS --snapshot <out.png> [dark] [hover] [tray] [m30|h2|h5|h10]` renders the popover to a PNG and exits.
enum Snapshot {
    @MainActor
    static func runIfRequested(stats: Stats, selection: ChartSelection, tray: TraySettings, loginItem: LoginItem) {
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
}
