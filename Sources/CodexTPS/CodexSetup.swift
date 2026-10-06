import AppKit
import Observation
import OSLog

private let log = Logger(subsystem: "local.codex-tps", category: "setup")

/// Checks and edits the `[otel]` section of Codex's config.toml and tells when the
/// running Codex app server predates that change.
@MainActor
@Observable
final class CodexSetup {
    enum ConfigState: Equatable {
        /// No `[otel]` section, so Codex exports nothing.
        case notConfigured
        /// Exports logs to CodexTPS.
        case ours
        /// Exports somewhere else; Codex has a single logs exporter, so this is left alone.
        case other
        case unreadable(String)
    }

    static let endpoint = "http://127.0.0.1:\(TelemetryReceiver.port)/v1/logs"
    static let section = """
        [otel]
        exporter = { otlp-http = { endpoint = "\(endpoint)", protocol = "json" } }
        """

    private(set) var state: ConfigState = .notConfigured
    /// Codex app servers started before our section was written; they must restart to export.
    private(set) var staleServers: [pid_t] = []
    private(set) var error: String?

    let configURL: URL = {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("config.toml")
    }()

    /// When CodexTPS wrote its section; unknown (nil) if the user added it by hand.
    private var configuredAt: Date? {
        get { UserDefaults.standard.object(forKey: "otelConfiguredAt") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "otelConfiguredAt") }
    }

    func refresh() {
        state = Self.state(of: try? String(contentsOf: configURL, encoding: .utf8), exists: FileManager.default.fileExists(atPath: configURL.path))
        if state == .ours, let at = configuredAt {
            staleServers = Self.codexAppServers().filter { $0.started < at }.map(\.pid)
        } else {
            staleServers = []
        }
    }

    static func state(of text: String?, exists: Bool) -> ConfigState {
        guard let text else { return exists ? .unreadable("config.toml is not readable") : .notConfigured }
        if text.contains(endpoint) { return .ours }
        let mentionsOtel = text.split(separator: "\n").contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("[otel") || t.hasPrefix("otel.") || t.hasPrefix("otel =")
        }
        return mentionsOtel ? .other : .notConfigured
    }

    /// Appends the section after a backup, then checks Codex still accepts the file and
    /// restores the backup if it does not.
    func install() {
        error = nil
        do {
            let original = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
            guard Self.state(of: original, exists: true) == .notConfigured else { refresh(); return }
            let backup = try backupConfig()
            let updated = original + (original.hasSuffix("\n") || original.isEmpty ? "" : "\n") + "\n" + Self.section + "\n"
            try write(updated)
            if let problem = validate() {
                if let backup { try? FileManager.default.removeItem(at: configURL); try? FileManager.default.copyItem(at: backup, to: configURL) }
                error = "Codex rejected the config, restored the backup: \(problem)"
            } else {
                configuredAt = Date()
                log.info("otel section added, backup at \(backup?.path ?? "-", privacy: .public)")
            }
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    /// Removes exactly the section CodexTPS writes; anything else needs a manual edit.
    func uninstall() {
        error = nil
        do {
            let text = try String(contentsOf: configURL, encoding: .utf8)
            // install() writes a blank line, the section and a newline after the existing text.
            let forms = [("\n\n" + Self.section + "\n", "\n"), ("\n" + Self.section + "\n", "\n"), (Self.section, "")]
            guard let (range, replacement) = forms.lazy.compactMap({ f, r in text.range(of: f).map { ($0, r) } }).first else {
                error = "The [otel] section was changed by hand; edit config.toml to remove it."
                return
            }
            _ = try backupConfig()
            try write(text.replacingCharacters(in: range, with: replacement))
            configuredAt = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
    }

    /// Asks each app hosting a stale Codex app server to quit (it may ask the user if work
    /// is in progress) and opens it again once it has exited.
    func restartCodex() {
        let hosts = Set(Self.codexAppServers().filter { staleServers.contains($0.pid) }.map(\.parent))
        for pid in hosts {
            guard let app = NSRunningApplication(processIdentifier: pid), let url = app.bundleURL else { continue }
            app.terminate()
            Task { @MainActor in
                for _ in 0..<600 where !app.isTerminated {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard app.isTerminated else { return }
                try? await NSWorkspace.shared.openApplication(at: url, configuration: .init())
                self.refresh()
            }
        }
    }

    private func backupConfig() throws -> URL? {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
        let dir = configURL.deletingLastPathComponent()
        var backup = dir.appendingPathComponent("config.toml.bak-codextps-\(stamp)")
        var n = 1
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = dir.appendingPathComponent("config.toml.bak-codextps-\(stamp)-\(n)")
            n += 1
        }
        try FileManager.default.copyItem(at: configURL, to: backup)
        return backup
    }

    /// Atomic write that keeps the file's permissions (config.toml is 0600).
    private func write(_ text: String) throws {
        let perms = (try? FileManager.default.attributesOfItem(atPath: configURL.path)[.posixPermissions]) ?? 0o600
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: configURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: configURL.path)
    }

    /// Runs a bundled or installed `codex` against the config; nil when it loads.
    private func validate() -> String? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        guard let codex = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: codex)
        p.arguments = ["features", "list"]
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = configURL.deletingLastPathComponent().path
        p.environment = env
        let err = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus != 0 else { return nil }
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return message.split(separator: "\n").first.map(String.init) ?? "exit \(p.terminationStatus)"
    }

    struct Server {
        let pid: pid_t
        let parent: pid_t
        let started: Date
    }

    /// `codex … app-server` processes, which read config.toml only when they start.
    static func codexAppServers() -> [Server] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,etime=,command="]
        let out = Pipe()
        p.standardOutput = out
        do { try p.run() } catch { return [] }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let now = Date()
        return text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count == 4, f[3].contains("/codex"), f[3].contains("app-server"),
                  let pid = pid_t(f[0]), let ppid = pid_t(f[1]), let age = elapsed(String(f[2])) else { return nil }
            return Server(pid: pid, parent: ppid, started: now.addingTimeInterval(-age))
        }
    }

    /// Parses ps `etime`: [[dd-]hh:]mm:ss.
    private static func elapsed(_ s: String) -> TimeInterval? {
        var days = 0.0
        var rest = Substring(s)
        if let dash = rest.firstIndex(of: "-") {
            days = Double(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        let seconds = parts.reversed().enumerated().reduce(0.0) { $0 + $1.element * pow(60, Double($1.offset)) }
        return days * 86400 + seconds
    }
}
