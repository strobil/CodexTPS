import Foundation

/// Tails rollout-*.jsonl files under the sessions directory by polling.
/// FSEvents is not usable here: Codex keeps the rollout open and appends to it
/// without producing file events. Recently modified files form a hot set whose
/// sizes are checked every second (hot = modified within `window` plus a margin); the directory is rescanned every 15 seconds.
/// A file seen for the first time is parsed from the beginning so that the
/// model/effort/tier state is known, but only samples inside `window` are reported.
final class SessionWatcher: @unchecked Sendable {
    private struct FileState {
        var offset: UInt64 = 0
        var pending = Data()
        var parser = RolloutParser()
    }

    private let hotWindow: TimeInterval
    private static let rescanEvery = 15

    private let root: URL
    private let window: TimeInterval
    private let onSamples: @Sendable ([Sample]) -> Void
    private let queue = DispatchQueue(label: "codex-tps.watcher")
    private var files: [String: FileState] = [:]
    private var hot: Set<String> = []
    private var ticks = 0
    private var timer: DispatchSourceTimer?

    init(root: URL, window: TimeInterval, onSamples: @escaping @Sendable ([Sample]) -> Void) {
        self.root = root
        self.window = window
        self.hotWindow = window + 5 * 60
        self.onSamples = onSamples
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        if ticks % Self.rescanEvery == 0 { rescan() }
        ticks += 1
        for path in hot { read(path: path) }
    }

    private func rescan() {
        let cutoff = Date().addingTimeInterval(-hotWindow)
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return }
        var found: Set<String> = []
        for case let url as URL in e where isRollout(url.path) {
            let mtime = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            if mtime >= cutoff { found.insert(url.path) }
        }
        hot = found
        files = files.filter { found.contains($0.key) }
    }

    private func isRollout(_ path: String) -> Bool {
        path.hasSuffix(".jsonl") && (path as NSString).lastPathComponent.hasPrefix("rollout-")
    }

    private func read(path: String) {
        var state = files[path] ?? FileState()
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }

        let size = (try? fh.seekToEnd()) ?? 0
        if size < state.offset { state = FileState() }
        guard size > state.offset else { files[path] = state; return }
        try? fh.seek(toOffset: state.offset)
        let chunk = (try? fh.read(upToCount: Int(size - state.offset))) ?? Data()
        state.offset += UInt64(chunk.count)

        var buffer = state.pending + chunk
        var samples: [Sample] = []
        let cutoff = Date().addingTimeInterval(-window)
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<nl]
            buffer = buffer[(nl + 1)...]
            if !line.isEmpty, let s = state.parser.consume(line: Data(line)), s.end >= cutoff {
                samples.append(s)
            }
        }
        state.pending = Data(buffer)
        files[path] = state

        if !samples.isEmpty { onSamples(samples) }
    }
}
