import Foundation
import SQLite3
import Testing
@testable import SwaplessCore

@Suite("S3 · history store")
struct HistoryStoreTests {
    let now = 1_800_000_000.0

    func sys(_ t: Double) -> SystemRow {
        SystemRow(t: t, system: SystemSample(freePct: 50, pressure: 1, swapUsedBytes: 1, swapinBytesPerSec: nil,
                                             swapinsTotal: 9, compressedBytes: 2), intervalSeconds: 30)
    }

    @Test func roundTrip() {
        let dir = makeTempDir()
        let h = HistoryStore(stateDir: dir, currentRuleIds: ["a"], now: now)
        #expect(h.isOn)
        h.bufferSystem(sys(now))
        let meta = SeriesMeta(key: "proc:1:2.000000", kind: "process", label: "x", path: "/x", groupLabel: "g",
                              firstSeen: now - 600, lastSeen: now)
        h.bufferBucket(key: meta.key, bucket: Bucket(start: now - 300, min: 10, max: 20, count: 10), meta: meta)
        #expect(h.flush(now: now))
        #expect(h.count("system_samples") == 1)
        let id = h.insertAction(ts: now, ruleId: "a", target: "wallpaper", pids: [5, 6], beforeMB: 1200,
                                outcome: "pending", dryRun: false)
        #expect(id != nil)
        #expect(h.pendingActions().map(\.pids) == [[5, 6]])
        #expect(h.updateOutcome(id: id!, outcome: "ok", afterMB: 110, wsBeforeMB: 2300, wsAfterMB: 1200))
        #expect(h.pendingActions().isEmpty)
        #expect(h.actions(since: 0).first?.afterMB == 110)
        #expect(h.setPause(ruleId: "a", reason: "agent-missing", at: now))
        #expect(h.pauses()["a"]?.reason == "agent-missing")
        #expect(h.clearPause(ruleId: "a"))
        #expect(h.pauses().isEmpty)
        h.close()

        // Reopen: the detector's last 24 h come back.
        let h2 = HistoryStore(stateDir: dir, currentRuleIds: ["a"], now: now)
        let (m, b) = h2.loadRecent(now: now)
        #expect(m == [meta])
        #expect(b[meta.key] == [Bucket(start: now - 300, min: 10, max: 20, count: 1)])
        #expect(h2.actions(since: 0).count == 1)
    }

    @Test func retentionPrune() {
        let dir = makeTempDir()
        let h = HistoryStore(stateDir: dir, currentRuleIds: [], now: now)
        h.bufferSystem(sys(now - 31 * 86400))
        h.bufferSystem(sys(now - 29 * 86400))
        let old = SeriesMeta(key: "old", kind: "process", label: "", path: "", groupLabel: "",
                             firstSeen: now - 9 * 86400, lastSeen: now - 8 * 86400)
        h.bufferBucket(key: "old", bucket: Bucket(start: now - 8 * 86400, min: 1, max: 1, count: 1), meta: old)
        h.bufferBucket(key: "new", bucket: Bucket(start: now - 6 * 86400, min: 1, max: 1, count: 1), meta: nil)
        _ = h.insertAction(ts: now - 400 * 86400, ruleId: "a", target: "wallpaper", pids: [], beforeMB: 1,
                           outcome: "ok", dryRun: false)
        h.flush(now: now)
        #expect(h.pruneIfDue(now: now))
        #expect(h.count("system_samples") == 1)
        #expect(h.count("series_buckets") == 1)
        #expect(h.count("series") == 0)
        #expect(h.count("actions") == 1)  // actions are kept forever
        #expect(!h.pruneIfDue(now: now + 3600))  // once a day
    }

    @Test func schemaMismatchBacksUpStartsFreshAndPausesEveryRule() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent(HistoryStore.fileName)
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT); INSERT INTO meta VALUES('schema_version','99'); CREATE TABLE junk(x)", nil, nil, nil)
        sqlite3_close(db)
        let h = HistoryStore(stateDir: dir, currentRuleIds: ["wallpaper-leak-guard", "other"], now: now)
        #expect(h.isOn)
        let bak = try #require(h.resetBackup)
        #expect(bak.hasSuffix(".bak-\(Int(now))"))
        #expect(FileManager.default.fileExists(atPath: bak))
        let p = h.pauses()
        #expect(p["wallpaper-leak-guard"]?.reason == "history-reset")
        #expect(p["other"]?.reason == "history-reset")
        #expect(h.count("junk") == -1)
    }

    @Test func notADatabaseIsResetToo() throws {
        let dir = makeTempDir()
        try Data("garbage, not sqlite at all, garbage garbage garbage".utf8)
            .write(to: dir.appendingPathComponent(HistoryStore.fileName))
        let h = HistoryStore(stateDir: dir, currentRuleIds: ["r"], now: now)
        #expect(h.isOn)
        #expect(h.resetBackup != nil)
        #expect(h.pauses()["r"]?.reason == "history-reset")
    }

    @Test func unwritableDirTurnsHistoryOff() {
        let h = HistoryStore(stateDir: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"), currentRuleIds: [], now: now)
        #expect(!h.isOn)
        #expect(h.error != nil)
        #expect(h.insertAction(ts: now, ruleId: "a", target: "wallpaper", pids: [], beforeMB: 1, outcome: "pending",
                               dryRun: false) == nil)
    }
}
