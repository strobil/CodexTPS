import Foundation
import OSLog
import SQLite3

private let log = Logger(subsystem: "local.codex-tps", category: "db")

/// Responses received through telemetry, kept in SQLite so their time to first token
/// survives restarts. Rollout logs remain the source for history and for responses
/// that happened while the app was not running.
final class MetricsDB: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "codex-tps.db")

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexTPS/metrics.sqlite")
    }

    init(url: URL = MetricsDB.defaultURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            log.error("open failed: \(String(cString: sqlite3_errmsg(self.db)), privacy: .public)")
            return
        }
        exec("PRAGMA journal_mode=WAL")
        exec("""
            CREATE TABLE IF NOT EXISTS responses (
                thread_id TEXT NOT NULL,
                end_at REAL NOT NULL,
                model TEXT NOT NULL,
                effort TEXT NOT NULL,
                tier TEXT NOT NULL,
                output_tokens INTEGER NOT NULL,
                reasoning_tokens INTEGER NOT NULL,
                duration REAL NOT NULL,
                ttft REAL,
                PRIMARY KEY (thread_id, end_at)
            )
            """)
        exec("CREATE INDEX IF NOT EXISTS responses_end ON responses(end_at)")
    }

    func insert(_ samples: [Sample]) {
        queue.async { [self] in
            exec("BEGIN")
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, """
                INSERT OR REPLACE INTO responses
                (thread_id, end_at, model, effort, tier, output_tokens, reasoning_tokens, duration, ttft)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, -1, &stmt, nil)
            for s in samples {
                bind(stmt, 1, s.threadId)
                sqlite3_bind_double(stmt, 2, s.end.timeIntervalSince1970)
                bind(stmt, 3, s.key.model)
                bind(stmt, 4, s.key.effort)
                bind(stmt, 5, s.key.tier)
                sqlite3_bind_int64(stmt, 6, Int64(s.outputTokens))
                sqlite3_bind_int64(stmt, 7, Int64(s.reasoningTokens))
                sqlite3_bind_double(stmt, 8, s.duration)
                if let t = s.ttft { sqlite3_bind_double(stmt, 9, t) } else { sqlite3_bind_null(stmt, 9) }
                if sqlite3_step(stmt) != SQLITE_DONE {
                    log.error("insert: \(String(cString: sqlite3_errmsg(self.db)), privacy: .public)")
                }
                sqlite3_reset(stmt)
            }
            sqlite3_finalize(stmt)
            exec("COMMIT")
        }
    }

    func load(since: Date) -> [Sample] {
        queue.sync {
            var out: [Sample] = []
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, """
                SELECT thread_id, end_at, model, effort, tier, output_tokens, reasoning_tokens, duration, ttft
                FROM responses WHERE end_at >= ? ORDER BY end_at
                """, -1, &stmt, nil)
            sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(Sample(
                    threadId: text(stmt, 0),
                    key: GroupKey(model: text(stmt, 2), effort: text(stmt, 3), tier: text(stmt, 4)),
                    outputTokens: Int(sqlite3_column_int64(stmt, 5)),
                    reasoningTokens: Int(sqlite3_column_int64(stmt, 6)),
                    duration: sqlite3_column_double(stmt, 7),
                    end: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    ttft: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 8)
                ))
            }
            sqlite3_finalize(stmt)
            return out
        }
    }

    private func exec(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            log.error("\(sql.prefix(40), privacy: .public): \(String(cString: sqlite3_errmsg(self.db)), privacy: .public)")
        }
    }

    private func bind(_ stmt: OpaquePointer?, _ i: Int32, _ s: String) {
        sqlite3_bind_text(stmt, i, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func text(_ stmt: OpaquePointer?, _ i: Int32) -> String {
        sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
    }
}
