import AppKit
import SwiftUI

/// One-line telemetry status with the action that fixes it.
struct SetupStatusRow: View {
    let stats: Stats
    let setup: CodexSetup
    /// Footer form: no "Remove…", which lives in Settings.
    var compact = false

    var body: some View {
        let s = status
        HStack(spacing: 6) {
            Circle().fill(s.color).frame(width: 7, height: 7)
            Text(setup.error ?? s.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let action = s.action, !(compact && action.title == "Remove…") {
                Button(action.title, action: action.run)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
    }

    private struct Status {
        let color: Color
        let text: String
        var action: (title: String, run: () -> Void)?
    }

    private var status: Status {
        if let e = stats.listenerError {
            return Status(color: .red, text: "Port \(TelemetryReceiver.port) unavailable: \(e)")
        }
        switch setup.state {
        case .unreadable(let why):
            return Status(color: .red, text: why, action: ("Show config", setup.revealConfig))
        case .notConfigured:
            return Status(color: .orange, text: "Codex is not sending telemetry", action: ("Set up…", { SetupAlerts.install(setup) }))
        case .other:
            return Status(color: .orange, text: "Codex sends telemetry elsewhere ([otel] in config.toml)", action: ("Show config", setup.revealConfig))
        case .ours:
            if !setup.staleServers.isEmpty {
                return Status(color: .orange, text: "Restart Codex to start sending telemetry", action: ("Restart Codex…", { SetupAlerts.restart(setup) }))
            }
            // A recent response with TTFT can only have come through telemetry, so it counts
            // as connected too (e.g. right after CodexTPS restarts, before Codex sends again).
            let recent = [stats.telemetrySeenAt, stats.lastTelemetryResponse].compactMap { $0 }.max()
            if let seen = recent, stats.now.timeIntervalSince(seen) < 600 {
                let last = stats.lastTelemetryResponse.map { "last response \(ago($0)) ago" } ?? "no responses yet"
                return Status(color: .green, text: "Telemetry connected · \(last)", action: ("Remove…", { SetupAlerts.uninstall(setup) }))
            }
            return Status(color: .gray, text: "Waiting for Codex · restart it if it ran before setup", action: ("Remove…", { SetupAlerts.uninstall(setup) }))
        }
    }

    private func ago(_ date: Date) -> String {
        let s = Int(stats.now.timeIntervalSince(date))
        if s < 60 { return "\(max(s, 0))s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
}

/// Confirmation dialogs for every change CodexTPS makes outside its own data.
@MainActor
enum SetupAlerts {
    private static let suppressKey = "suppressSetupPrompt"

    /// First-launch offer; shown at most once per launch and never after "Don't ask again".
    static func offerIfNeeded(_ setup: CodexSetup) {
        setup.refresh()
        guard setup.state == .notConfigured, !UserDefaults.standard.bool(forKey: suppressKey) else { return }
        let alert = makeInstallAlert(setup)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let response = run(alert)
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: suppressKey) }
        if response == .alertFirstButtonReturn { install(setup, confirmed: true) }
    }

    static func install(_ setup: CodexSetup, confirmed: Bool = false) {
        if !confirmed, run(makeInstallAlert(setup)) != .alertFirstButtonReturn { return }
        setup.install()
        guard setup.error == nil, !setup.staleServers.isEmpty else { return }
        restart(setup)
    }

    static func uninstall(_ setup: CodexSetup) {
        let alert = NSAlert()
        alert.messageText = "Stop Codex telemetry export?"
        alert.informativeText = "CodexTPS will remove its [otel] section from \(path(setup)) (a backup is kept). New responses will not be recorded. Codex picks the change up when it restarts."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if run(alert) == .alertFirstButtonReturn { setup.uninstall() }
    }

    static func restart(_ setup: CodexSetup) {
        let alert = NSAlert()
        alert.messageText = "Restart Codex now?"
        alert.informativeText = "Codex reads config.toml only when it starts. CodexTPS will ask Codex to quit and open it again; if a task is running, Codex may ask you first. Terminal `codex` sessions need to be restarted by hand."
        alert.addButton(withTitle: "Restart Codex")
        alert.addButton(withTitle: "Later")
        if run(alert) == .alertFirstButtonReturn { setup.restartCodex() }
    }

    private static func makeInstallAlert(_ setup: CodexSetup) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Let Codex send telemetry to CodexTPS?"
        alert.informativeText = """
            CodexTPS reads model responses from Codex's OpenTelemetry logs. It will append to \(path(setup)) (a backup is kept):

            \(CodexSetup.section)

            Logs go only to 127.0.0.1. Prompt text is not included. Codex has to be restarted to pick this up.
            """
        alert.addButton(withTitle: "Add to config")
        alert.addButton(withTitle: "Not now")
        return alert
    }

    private static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    private static func path(_ setup: CodexSetup) -> String {
        setup.configURL.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}
