import Foundation
import SQLite3

/// The macro isn't imported into Swift (spec § D).
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One `actions` row.
public struct ActionRow: Sendable, Equatable {
    public var id: Int64
    public var ts: Double
    public var ruleId: String
    public var target: String
    public var pids: [Int32]
    public var beforeMB: Double
    public var afterMB: Double?
    public var outcome: String
    public var dryRun: Bool
    public var wsBeforeMB: Double?
    public var wsAfterMB: Double?

    public init(id: Int64, ts: Double, ruleId: String, target: String, pids: [Int32], beforeMB: Double,
                afterMB: Double?, outcome: String, dryRun: Bool, wsBeforeMB: Double?, wsAfterMB: Double?) {
        self.id = id
        self.ts = ts
        self.ruleId = ruleId
        self.target = target
        self.pids = pids
        self.beforeMB = beforeMB
        self.afterMB = afterMB
        self.outcome = outcome
        self.dryRun = dryRun
        self.wsBeforeMB = wsBeforeMB
        self.wsAfterMB = wsAfterMB
    }
}

/// One `system_samples` row.
public struct SystemRow: Sendable, Equatable {
    public var t: Double
    public var system: SystemSample
    public var intervalSeconds: Double

    public init(t: Double, system: SystemSample, intervalSeconds: Double) {
        self.t = t
        self.system = system
        self.intervalSeconds = intervalSeconds
    }
}

/// `history.sqlite` (§ C): samples, buckets, actions and rule state. System SQLite, WAL.
/// Batched writes every 5 minutes; action rows, outcomes and rule_state changes are written
/// immediately, each in its own transaction. Any error turns history off.
public final class HistoryStore: @unchecked Sendable {
    public static let fileName = "history.sqlite"
    public static let schemaVersion = "1"
    public static let flushSeconds = 300.0
    public static let systemRetention = 30 * 86400.0
    public static let bucketRetention = 7 * 86400.0

    private var db: OpaquePointer?
    public private(set) var error: String?
    /// Set when an unmigratable file was moved aside at open.
    public private(set) var resetBackup: String?
    private var systemBuffer: [SystemRow] = []
    private var bucketBuffer: [(String, Bucket)] = []
    private var seriesBuffer: [String: SeriesMeta] = [:]
    public private(set) var lastFlush: Double
    private var lastPrune: Double = 0

    public var isOn: Bool { db != nil && error == nil }

    /// Opens (or creates) the store. On a schema it can't migrate: rename to
    /// `history.sqlite.bak-<unix>`, start fresh, and pause every current rule id with
    /// `history-reset`.
    public init(stateDir: URL, currentRuleIds: [String], now: Double = Date().timeIntervalSince1970) {
        lastFlush = now
        let url = stateDir.appendingPathComponent(Self.fileName)
        if let reason = open(url) {
            if reason == "migrate" {
                close()
                let bak = url.path + ".bak-\(Int(now))"
                do {
                    try FileManager.default.moveItem(atPath: url.path, toPath: bak)
                    for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
                    resetBackup = bak
                } catch {
                    self.error = "can't move the old history aside"
                    return
                }
                if let again = open(url) {
                    self.error = again == "migrate" ? "schema mismatch after reset" : again
                    close()
                    return
                }
                for id in currentRuleIds {
                    if !setPause(ruleId: id, reason: "history-reset", at: now) { return }
                }
            } else {
                self.error = reason
                close()
            }
        }
    }

    deinit { close() }

    /// nil on success, "migrate" when the schema is not ours, else an error message.
    private func open(_ url: URL) -> String? {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            return msg
        }
        db = handle
        sqlite3_busy_timeout(handle, 2000)
        // Not a database at all → treat like a schema we can't migrate.
        if exec("PRAGMA journal_mode=WAL") != nil {
            return "migrate"
        }
        _ = exec("PRAGMA cache_size=-256")
        _ = exec("PRAGMA synchronous=NORMAL")
        guard exec("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)") == nil else {
            return "migrate"
        }
        let version = scalarText("SELECT value FROM meta WHERE key='schema_version'")
        if let version, version != Self.schemaVersion { return "migrate" }
        if version == nil {
            // A fresh file, or one without our meta row but with other tables: only fresh is ours.
            let tables = scalarInt("SELECT count(*) FROM sqlite_master WHERE type='table' AND name != 'meta'") ?? 0
            if tables > 0 { return "migrate" }
        }
        let ddl = [
            "CREATE TABLE IF NOT EXISTS system_samples(t REAL NOT NULL, freePct INTEGER, pressure INTEGER, swapUsedBytes INTEGER, swapinBytesPerSec REAL, swapinsTotal INTEGER, compressedBytes INTEGER, intervalSeconds REAL)",
            "CREATE INDEX IF NOT EXISTS system_samples_t ON system_samples(t)",
            "CREATE TABLE IF NOT EXISTS series_buckets(series_key TEXT NOT NULL, bucket_start REAL NOT NULL, min_fp INTEGER NOT NULL, max_fp INTEGER NOT NULL, PRIMARY KEY(series_key, bucket_start))",
            "CREATE INDEX IF NOT EXISTS series_buckets_start ON series_buckets(bucket_start)",
            "CREATE TABLE IF NOT EXISTS series(series_key TEXT PRIMARY KEY, kind TEXT, label TEXT, path TEXT, group_label TEXT, first_seen REAL, last_seen REAL)",
            "CREATE TABLE IF NOT EXISTS actions(id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, rule_id TEXT NOT NULL, target TEXT NOT NULL, pids_json TEXT NOT NULL, before_mb REAL, after_mb REAL, outcome TEXT NOT NULL, dry_run INTEGER NOT NULL, ws_before_mb REAL, ws_after_mb REAL)",
            "CREATE TABLE IF NOT EXISTS rule_state(rule_id TEXT PRIMARY KEY, paused_reason TEXT NOT NULL, paused_at REAL NOT NULL)",
            "INSERT OR IGNORE INTO meta(key, value) VALUES('schema_version', '\(Self.schemaVersion)')",
        ]
        for sql in ddl {
            if let e = exec(sql) { return e }
        }
        return nil
    }

    public func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    private func fail(_ msg: String) {
        if error == nil { error = msg }
        close()
    }

    @discardableResult
    private func exec(_ sql: String) -> String? {
        guard let db else { return error ?? "history is off" }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(err)
            return msg
        }
        return nil
    }

    private func scalarText(_ sql: String) -> String? {
        guard let db else { return nil }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) else { return nil }
        return String(cString: c)
    }

    private func scalarInt(_ sql: String) -> Int? {
        guard let db else { return nil }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(st, 0))
    }

    /// Runs `body` inside one transaction; any failure turns history off.
    @discardableResult
    private func transaction(_ body: () -> String?) -> Bool {
        guard isOn else { return false }
        if let e = exec("BEGIN IMMEDIATE") {
            fail(e)
            return false
        }
        if let e = body() {
            _ = exec("ROLLBACK")
            fail(e)
            return false
        }
        if let e = exec("COMMIT") {
            _ = exec("ROLLBACK")
            fail(e)
            return false
        }
        return true
    }

    /// Prepares, binds, steps once. Binder values: Double, Int64, Int, String, nil (NULL).
    private func run(_ sql: String, _ values: [Any?]) -> String? {
        guard let db else { return "history is off" }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            return String(cString: sqlite3_errmsg(db))
        }
        defer { sqlite3_finalize(st) }
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case nil: sqlite3_bind_null(st, idx)
            case let d as Double: sqlite3_bind_double(st, idx, d)
            case let n as Int64: sqlite3_bind_int64(st, idx, n)
            case let n as Int: sqlite3_bind_int64(st, idx, Int64(n))
            case let n as UInt64: sqlite3_bind_int64(st, idx, Int64(bitPattern: n))
            case let s as String: sqlite3_bind_text(st, idx, s, -1, SQLITE_TRANSIENT)
            default: sqlite3_bind_null(st, idx)
            }
        }
        let rc = sqlite3_step(st)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { return String(cString: sqlite3_errmsg(db)) }
        return nil
    }

    private func query(_ sql: String, _ values: [Any?] = [], row: (OpaquePointer) -> Void) -> Bool {
        guard let db else { return false }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(st) }
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case let d as Double: sqlite3_bind_double(st, idx, d)
            case let s as String: sqlite3_bind_text(st, idx, s, -1, SQLITE_TRANSIENT)
            case let n as Int64: sqlite3_bind_int64(st, idx, n)
            default: sqlite3_bind_null(st, idx)
            }
        }
        while sqlite3_step(st) == SQLITE_ROW { row(st!) }
        return true
    }

    // MARK: - Batched writes

    public func bufferSystem(_ row: SystemRow) {
        guard isOn else { return }
        systemBuffer.append(row)
    }

    public func bufferBucket(key: String, bucket: Bucket, meta: SeriesMeta?) {
        guard isOn else { return }
        bucketBuffer.append((key, bucket))
        if let meta { seriesBuffer[key] = meta }
    }

    public var bufferedCount: Int { systemBuffer.count + bucketBuffer.count + seriesBuffer.count }

    /// One transaction with everything buffered.
    @discardableResult
    public func flush(now: Double = Date().timeIntervalSince1970) -> Bool {
        lastFlush = now
        guard isOn else { return false }
        if systemBuffer.isEmpty && bucketBuffer.isEmpty && seriesBuffer.isEmpty { return true }
        let sys = systemBuffer
        let buckets = bucketBuffer
        let series = seriesBuffer
        systemBuffer.removeAll()
        bucketBuffer.removeAll()
        seriesBuffer.removeAll()
        return transaction {
            for r in sys {
                if let e = run("INSERT INTO system_samples(t, freePct, pressure, swapUsedBytes, swapinBytesPerSec, swapinsTotal, compressedBytes, intervalSeconds) VALUES(?,?,?,?,?,?,?,?)",
                               [r.t, r.system.freePct, r.system.pressure, r.system.swapUsedBytes,
                                r.system.swapinBytesPerSec, r.system.swapinsTotal, r.system.compressedBytes,
                                r.intervalSeconds]) { return e }
            }
            for (k, b) in buckets {
                if let e = run("INSERT OR REPLACE INTO series_buckets(series_key, bucket_start, min_fp, max_fp) VALUES(?,?,?,?)",
                               [k, b.start, b.min, b.max]) { return e }
            }
            for m in series.values {
                if let e = run("""
                    INSERT INTO series(series_key, kind, label, path, group_label, first_seen, last_seen) VALUES(?,?,?,?,?,?,?)
                    ON CONFLICT(series_key) DO UPDATE SET label=excluded.label, group_label=excluded.group_label, last_seen=excluded.last_seen
                    """, [m.key, m.kind, m.label, m.path, m.groupLabel, m.firstSeen, m.lastSeen]) { return e }
            }
            return nil
        }
    }

    /// Retention: system samples 30 days, buckets 7 days, actions forever. Once a day.
    @discardableResult
    public func pruneIfDue(now: Double) -> Bool {
        guard isOn, now - lastPrune >= 86400 else { return false }
        lastPrune = now
        return transaction {
            if let e = run("DELETE FROM system_samples WHERE t < ?", [now - Self.systemRetention]) { return e }
            if let e = run("DELETE FROM series_buckets WHERE bucket_start < ?", [now - Self.bucketRetention]) { return e }
            if let e = run("DELETE FROM series WHERE last_seen < ?", [now - Self.bucketRetention]) { return e }
            return nil
        }
    }

    /// The last 24 h of buckets, so a relaunch keeps the detector's memory.
    public func loadRecent(now: Double, seconds: Double = 86400) -> (meta: [SeriesMeta], buckets: [String: [Bucket]]) {
        var meta: [SeriesMeta] = []
        var buckets: [String: [Bucket]] = [:]
        guard isOn else { return ([], [:]) }
        let from = now - seconds
        _ = query("SELECT series_key, kind, label, path, group_label, first_seen, last_seen FROM series WHERE last_seen >= ?", [from]) { st in
            meta.append(SeriesMeta(key: Self.text(st, 0), kind: Self.text(st, 1), label: Self.text(st, 2),
                                   path: Self.text(st, 3), groupLabel: Self.text(st, 4),
                                   firstSeen: sqlite3_column_double(st, 5), lastSeen: sqlite3_column_double(st, 6)))
        }
        _ = query("SELECT series_key, bucket_start, min_fp, max_fp FROM series_buckets WHERE bucket_start >= ? ORDER BY bucket_start", [from]) { st in
            let b = Bucket(start: sqlite3_column_double(st, 1),
                           min: UInt64(bitPattern: sqlite3_column_int64(st, 2)),
                           max: UInt64(bitPattern: sqlite3_column_int64(st, 3)), count: 1)
            buckets[Self.text(st, 0), default: []].append(b)
        }
        return (meta, buckets)
    }

    static func text(_ st: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(st, i).map { String(cString: $0) } ?? ""
    }

    // MARK: - Immediate writes

    /// Writes an `actions` row in its own transaction; nil when history is off or it failed.
    public func insertAction(ts: Double, ruleId: String, target: String, pids: [Int32], beforeMB: Double,
                             outcome: String, dryRun: Bool) -> Int64? {
        guard isOn, let db else { return nil }
        var id: Int64?
        let pidsJSON = "[" + pids.map(String.init).joined(separator: ",") + "]"
        let ok = transaction {
            if let e = run("INSERT INTO actions(ts, rule_id, target, pids_json, before_mb, outcome, dry_run) VALUES(?,?,?,?,?,?,?)",
                           [ts, ruleId, target, pidsJSON, beforeMB, outcome, dryRun ? 1 : 0]) { return e }
            id = sqlite3_last_insert_rowid(db)
            return nil
        }
        return ok ? id : nil
    }

    @discardableResult
    public func updateOutcome(id: Int64, outcome: String, afterMB: Double?, wsBeforeMB: Double?,
                              wsAfterMB: Double?) -> Bool {
        transaction {
            run("UPDATE actions SET outcome=?, after_mb=?, ws_before_mb=?, ws_after_mb=? WHERE id=?",
                [outcome, afterMB, wsBeforeMB, wsAfterMB, id])
        }
    }

    public func actions(since: Double) -> [ActionRow] {
        var out: [ActionRow] = []
        _ = query("SELECT id, ts, rule_id, target, pids_json, before_mb, after_mb, outcome, dry_run, ws_before_mb, ws_after_mb FROM actions WHERE ts >= ? ORDER BY id", [since]) { st in
            out.append(Self.actionRow(st))
        }
        return out
    }

    public func pendingActions() -> [ActionRow] {
        var out: [ActionRow] = []
        _ = query("SELECT id, ts, rule_id, target, pids_json, before_mb, after_mb, outcome, dry_run, ws_before_mb, ws_after_mb FROM actions WHERE outcome='pending' ORDER BY id") { st in
            out.append(Self.actionRow(st))
        }
        return out
    }

    /// At engine start: every `pending` row becomes `interrupted`. Returns the rows it changed.
    public func markPendingInterrupted() -> [ActionRow] {
        var changed: [ActionRow] = []
        for var row in pendingActions() {
            guard updateOutcome(id: row.id, outcome: "interrupted", afterMB: nil, wsBeforeMB: nil, wsAfterMB: nil) else { break }
            row.outcome = "interrupted"
            changed.append(row)
        }
        return changed
    }

    static func actionRow(_ st: OpaquePointer) -> ActionRow {
        func optDouble(_ i: Int32) -> Double? {
            sqlite3_column_type(st, i) == SQLITE_NULL ? nil : sqlite3_column_double(st, i)
        }
        let pidsText = text(st, 4)
        let pids = pidsText.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: ",").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        return ActionRow(id: sqlite3_column_int64(st, 0), ts: sqlite3_column_double(st, 1),
                         ruleId: text(st, 2), target: text(st, 3), pids: pids,
                         beforeMB: sqlite3_column_double(st, 5), afterMB: optDouble(6),
                         outcome: text(st, 7), dryRun: sqlite3_column_int(st, 8) != 0,
                         wsBeforeMB: optDouble(9), wsAfterMB: optDouble(10))
    }

    /// rule id → (reason, at).
    public func pauses() -> [String: (reason: String, at: Double)] {
        var out: [String: (String, Double)] = [:]
        _ = query("SELECT rule_id, paused_reason, paused_at FROM rule_state") { st in
            out[Self.text(st, 0)] = (Self.text(st, 1), sqlite3_column_double(st, 2))
        }
        return out
    }

    @discardableResult
    public func setPause(ruleId: String, reason: String, at: Double) -> Bool {
        transaction {
            run("INSERT OR REPLACE INTO rule_state(rule_id, paused_reason, paused_at) VALUES(?,?,?)",
                [ruleId, reason, at])
        }
    }

    @discardableResult
    public func clearPause(ruleId: String) -> Bool {
        transaction { run("DELETE FROM rule_state WHERE rule_id=?", [ruleId]) }
    }

    /// Row counts, for tests.
    public func count(_ table: String) -> Int {
        scalarInt("SELECT count(*) FROM \(table)") ?? -1
    }
}
