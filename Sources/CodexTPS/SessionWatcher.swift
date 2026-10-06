import Foundation
import OSLog

private let log = Logger(subsystem: "local.codex-tps", category: "watcher")

/// Tails rollout-*.jsonl files under the sessions directory by polling.
/// FSEvents is not usable here: Codex keeps the rollout open and appends to it
/// without producing file events.
///
/// Files modified within `pollWindow` are checked every second; the whole tree is
/// rescanned every 15 seconds and any file inside the history window that grew is read.
/// Per-file read offsets, parser state and samples are cached on disk, so a restart
/// only reads bytes appended since the last run instead of months of logs.
final class SessionWatcher: @unchecked Sendable {
    private struct FileState: Codable {
        var offset: UInt64 = 0
        var parser = RolloutParser()
        var samples: [Sample] = []
    }

    private struct Cache: Codable {
        static let version = 1
        var version = Cache.version
        var files: [String: FileState]
    }

    private static let pollWindow: TimeInterval = 30 * 60
    private static let rescanEvery = 15
    private static let saveEvery = 60

    private let root: URL
    private let window: TimeInterval
    private let onSamples: @Sendable ([Sample]) -> Void
    /// Called once after the first full scan with the number of files read and the time it took.
    var onFirstScan: (@Sendable (Int, TimeInterval) -> Void)?
    private let queue = DispatchQueue(label: "codex-tps.watcher", qos: .utility)
    private let cacheURL: URL
    private var files: [String: FileState] = [:]
    private var poll: Set<String> = []
    private var ticks = 0
    private var dirty = false
    private var timer: DispatchSourceTimer?

    init(root: URL, window: TimeInterval, onSamples: @escaping @Sendable ([Sample]) -> Void) {
        self.root = root
        self.window = window
        self.onSamples = onSamples
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let name = root.path.replacingOccurrences(of: "/", with: "_")
        cacheURL = caches.appendingPathComponent("local.codex-tps/rollouts\(name).plist")
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        if ticks == 0 { loadCache() }
        if ticks % Self.rescanEvery == 0 {
            rescan()
        } else {
            var batch: [Sample] = []
            for path in poll { batch += read(path: path) }
            if !batch.isEmpty { onSamples(batch) }
        }
        if ticks % Self.saveEvery == Self.saveEvery - 1 { saveCache() }
        ticks += 1
    }

    private func rescan() {
        let now = Date()
        let historyCutoff = now.addingTimeInterval(-window)
        let pollCutoff = now.addingTimeInterval(-Self.pollWindow)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return }

        var live: [(path: String, mtime: Date, size: UInt64)] = []
        for case let url as URL in e where isRollout(url.path) {
            let v = try? url.resourceValues(forKeys: keys)
            let mtime = v?.contentModificationDate ?? .distantPast
            if mtime >= historyCutoff {
                live.append((url.path, mtime, UInt64(v?.fileSize ?? 0)))
            }
        }

        let livePaths = Set(live.map(\.path))
        if files.keys.contains(where: { !livePaths.contains($0) }) {
            files = files.filter { livePaths.contains($0.key) }
            dirty = true
        }
        poll = Set(live.filter { $0.mtime >= pollCutoff }.map(\.path))

        let started = Date()
        var batch: [Sample] = []
        var readCount = 0
        for f in live.sorted(by: { $0.mtime > $1.mtime }) where files[f.path]?.offset != f.size {
            batch += read(path: f.path)
            readCount += 1
            if batch.count >= 2000 {
                onSamples(batch)
                batch = []
            }
        }
        if !batch.isEmpty { onSamples(batch) }
        let elapsed = Date().timeIntervalSince(started)
        if readCount > 1 {
            log.info("rescan read \(readCount) files in \(elapsed, format: .fixed(precision: 1))s")
            saveCache()
        }
        if ticks == 0 { onFirstScan?(readCount, elapsed) }
    }

    private func isRollout(_ path: String) -> Bool {
        path.hasSuffix(".jsonl") && (path as NSString).lastPathComponent.hasPrefix("rollout-")
    }

    private static let chunkSize = 8 << 20

    /// Reads complete lines appended since the last call and returns new samples in the window.
    /// Large files are read in chunks so a months-old multi-megabyte rollout does not sit in memory.
    private func read(path: String) -> [Sample] {
        var state = files[path] ?? FileState()
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }

        let size = (try? fh.seekToEnd()) ?? 0
        if size < state.offset { state = FileState() }
        guard size > state.offset else { return [] }

        let cutoff = Date().addingTimeInterval(-window)
        var new: [Sample] = []
        var carry = Data()
        var position = state.offset
        try? fh.seek(toOffset: position)
        while position < size {
            let progressed: Bool = autoreleasepool {
                let want = Int(min(UInt64(Self.chunkSize), size - position))
                guard let chunk = try? fh.read(upToCount: want), !chunk.isEmpty else { return false }
                position += UInt64(chunk.count)
                let data = carry.isEmpty ? chunk : carry + chunk
                guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
                    carry = data
                    return true
                }
                var start = data.startIndex
                while start <= lastNewline {
                    let nl = data[start...lastNewline].firstIndex(of: UInt8(ascii: "\n"))!
                    if nl > start, let s = state.parser.consume(line: data[start..<nl]), s.end >= cutoff {
                        new.append(s)
                    }
                    start = nl + 1
                }
                state.offset += UInt64(lastNewline - data.startIndex + 1)
                carry = Data(data[(lastNewline + 1)...])
                return true
            }
            if !progressed { break }
        }
        state.samples.removeAll { $0.end < cutoff }
        state.samples += new
        files[path] = state
        dirty = true
        return new
    }

    private func loadCache() {
        guard
            let data = try? Data(contentsOf: cacheURL),
            let cache = try? PropertyListDecoder().decode(Cache.self, from: data),
            cache.version == Cache.version
        else { return }
        let cutoff = Date().addingTimeInterval(-window)
        files = cache.files
        let samples = files.values.flatMap(\.samples).filter { $0.end >= cutoff }
        log.info("cache: \(self.files.count) files, \(samples.count) samples")
        if !samples.isEmpty { onSamples(samples) }
    }

    private func saveCache() {
        guard dirty else { return }
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(Cache(files: files))
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
            dirty = false
        } catch {
            log.error("cache save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
