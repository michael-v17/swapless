import Darwin
import Foundation

/// One slice-1 rule (§ I): `restart` on a code-allowlisted target.
public struct Rule: Sendable, Equatable {
    public var id: String
    public var note: String?
    public var enabled: Bool
    public var target: RestartTarget
    public var action: String
    public var footprintAboveMB: Int
    public var consecutiveSamples: Int
    public var cooldownMinutes: Int
    public var maxPerDay: Int

    public init(id: String, note: String? = nil, enabled: Bool, target: RestartTarget,
                action: String = "restart", footprintAboveMB: Int, consecutiveSamples: Int = 2,
                cooldownMinutes: Int, maxPerDay: Int) {
        self.id = id
        self.note = note
        self.enabled = enabled
        self.target = target
        self.action = action
        self.footprintAboveMB = footprintAboveMB
        self.consecutiveSamples = consecutiveSamples
        self.cooldownMinutes = cooldownMinutes
        self.maxPerDay = maxPerDay
    }

    public var thresholdBytes: UInt64 { UInt64(footprintAboveMB) * 1024 * 1024 }
}

/// A rule object as found in the file: valid (with `rule`) or not (with `error`).
public struct RuleEntry: Sendable, Equatable {
    public var id: String
    public var rule: Rule?
    public var error: String?
    /// The raw `enabled`, when it was a boolean.
    public var enabled: Bool?

    public var valid: Bool { rule != nil }
}

public enum RulesStatus: String, Sendable {
    case ok, invalid, missing
}

/// The result of loading `rules.json`.
public struct RulesLoad: Sendable, Equatable {
    public var status: RulesStatus
    public var entries: [RuleEntry]
    /// The file-level error, for status `invalid`.
    public var fileError: String?
    public var mtime: timespec?
    public var size: Int64?
    /// The quit-on-last-window section (v1-quit-on-close S1).
    public var quit: QuitSettings

    public init(status: RulesStatus, entries: [RuleEntry], fileError: String?, mtime: timespec?,
                size: Int64?, quit: QuitSettings? = nil) {
        self.status = status
        self.entries = entries
        self.fileError = fileError
        self.mtime = mtime
        self.size = size
        switch status {
        case .ok: self.quit = quit ?? .defaults
        case .invalid: self.quit = quit ?? .invalid(nil)
        case .missing: self.quit = quit ?? .missing
        }
    }

    public static func == (a: RulesLoad, b: RulesLoad) -> Bool {
        a.status == b.status && a.entries == b.entries && a.fileError == b.fileError
            && a.size == b.size && a.mtime?.tv_sec == b.mtime?.tv_sec
            && a.mtime?.tv_nsec == b.mtime?.tv_nsec && a.quit == b.quit
    }

    public static let missing = RulesLoad(status: .missing, entries: [], fileError: nil,
                                          mtime: nil, size: nil)

    /// Only valid rules count; an invalid file means no rules.
    public var validRules: [Rule] { entries.compactMap(\.rule) }

    /// Any write is allowed only when the file parsed, every rule is valid and the quit section
    /// is valid (or a v1 file's defaults). Every write re-encodes the whole model, so an invalid
    /// quit section disables the wallpaper toggle too (intended; `Open rules file…` is the way out).
    public var allValid: Bool { status == .ok && entries.allSatisfy(\.valid) && quit.writable }

    /// The `rules` JSON line (S6).
    public var json: JSON {
        .object([
            ("type", .string("rules")),
            ("status", .string(status.rawValue)),
            ("rules", .array(entries.map { e in
                .object([
                    ("id", .string(e.id)),
                    ("valid", .bool(e.valid)),
                    ("error", .opt(e.error)),
                ])
            })),
            ("quit", quit.json),
        ])
    }

    /// The `.default` log line: the `rules` line's fields plus each rule's `enabled`.
    public var logLine: String {
        var parts = ["rules status=\(status.rawValue)"]
        if let fileError { parts.append("error=\"\(fileError)\"") }
        for e in entries {
            let en = e.enabled.map { String($0) } ?? "null"
            parts.append("rule id=\(e.id) valid=\(e.valid) enabled=\(en) error=\(e.error.map { "\"\($0)\"" } ?? "null")")
        }
        parts.append("quit status=\(quit.status.rawValue) enabled=\(quit.enabled) neverQuit=\(quit.neverQuitIds.count) error=\(quit.error.map { "\"\($0)\"" } ?? "null")")
        return parts.joined(separator: " · ")
    }
}

/// stat(2): (mtime, size), nil when missing.
func statFile(_ path: String) -> (timespec, Int64)? {
    var st = stat()
    guard stat(path, &st) == 0 else { return nil }
    return (st.st_mtimespec, Int64(st.st_size))
}

struct RuleError: Error {
    let m: String
}

/// `rules.json`: strict model, validation, seed, atomic write-back (§ C, § I).
public enum RulesFile {
    public static let fileName = "rules.json"
    public static let topLevelKeys: Set<String> = ["version", "rules"]
    /// Version 2 adds the quit section (v1-quit-on-close T1).
    public static let topLevelKeysV2: Set<String> = ["version", "rules", "quitOnLastWindow", "apps"]
    public static let ruleKeys: Set<String> = [
        "id", "note", "enabled", "target", "action", "footprintAboveMB", "consecutiveSamples",
        "cooldownMinutes", "maxPerDay",
    ]
    public static let requiredRuleKeys: [String] = [
        "id", "enabled", "target", "action", "footprintAboveMB", "cooldownMinutes", "maxPerDay",
    ]

    /// The § I seed, with `maxPerDay` 24 instead of the spec's 8: owner decision 2026-11-05
    /// after acceptance (DECISIONS.md), because the extension regrows at ~1 GB/h with Portal.
    public static let seedRule = Rule(
        id: "wallpaper-leak-guard",
        note: "Owner decision 2026-11-05 (DECISIONS.md): restart macOS's leaking wallpaper quietly.",
        enabled: true, target: .wallpaper, action: "restart", footprintAboveMB: 1024,
        consecutiveSamples: 2, cooldownMinutes: 30, maxPerDay: 24)

    public static func url(in stateDir: URL) -> URL { stateDir.appendingPathComponent(fileName) }

    /// stat(2) of the file: (mtime, size), nil when missing.
    public static func fileStat(_ url: URL) -> (timespec, Int64)? {
        statFile(url.path)
    }

    /// Loads the file at `url`. A missing file means no rules (status `missing`).
    public static func load(url: URL, allowedTargets: Set<String>) -> RulesLoad {
        guard let (mtime, size) = fileStat(url) else { return .missing }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return RulesLoad(status: .invalid, entries: [], fileError: "can't read the file",
                             mtime: mtime, size: size)
        }
        var r = decode(data, allowedTargets: allowedTargets)
        r.mtime = mtime
        r.size = size
        return r
    }

    /// Strict decoding. File-level errors (no parse, unknown top-level key, wrong version)
    /// invalidate the whole file; anything inside a rule object invalidates that rule only.
    public static func decode(_ data: Data, allowedTargets: Set<String>) -> RulesLoad {
        func invalid(_ msg: String) -> RulesLoad {
            RulesLoad(status: .invalid, entries: [], fileError: msg, mtime: nil, size: nil)
        }
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data)
        } catch {
            return invalid("not valid JSON")
        }
        guard let top = obj as? [String: Any] else { return invalid("not a JSON object") }
        if let unknown = top.keys.sorted().first(where: { !topLevelKeysV2.contains($0) }) {
            return invalid("unknown top-level key '\(unknown)'")
        }
        guard let version = JSONRead.int(top["version"]), version == 1 || version == 2 else {
            return invalid("version must be 1 or 2")
        }
        if version == 1, let unknown = top.keys.sorted().first(where: { !topLevelKeys.contains($0) }) {
            return invalid("unknown top-level key '\(unknown)'")
        }
        guard let rawRules = top["rules"] as? [Any] else { return invalid("'rules' must be an array") }

        var entries: [RuleEntry] = []
        var seenIds = Set<String>()
        var seenTargets = Set<String>()
        for raw in rawRules {
            var e = decodeRule(raw, allowedTargets: allowedTargets)
            if let rule = e.rule {
                if seenIds.contains(rule.id) {
                    e.rule = nil
                    e.error = "duplicate id"
                } else if seenTargets.contains(rule.target.rawValue) {
                    e.rule = nil
                    e.error = "duplicate target"
                } else {
                    seenIds.insert(rule.id)
                    seenTargets.insert(rule.target.rawValue)
                }
            }
            entries.append(e)
        }
        let quit: QuitSettings = version == 2 ? QuitSettings.decode(top: top) : .defaults
        return RulesLoad(status: .ok, entries: entries, fileError: nil, mtime: nil, size: nil, quit: quit)
    }

    static func decodeRule(_ raw: Any, allowedTargets: Set<String>) -> RuleEntry {
        guard let d = raw as? [String: Any] else {
            return RuleEntry(id: "", rule: nil, error: "rule is not an object", enabled: nil)
        }
        let id = (d["id"] as? String) ?? ""
        let enabled = JSONRead.bool(d["enabled"])
        func bad(_ msg: String) -> RuleEntry {
            RuleEntry(id: id, rule: nil, error: msg, enabled: enabled)
        }
        if let unknown = d.keys.sorted().first(where: { !ruleKeys.contains($0) }) {
            return bad("unknown key '\(unknown)'")
        }
        if let missing = requiredRuleKeys.first(where: { d[$0] == nil }) {
            return bad("missing key '\(missing)'")
        }
        guard let idStr = d["id"] as? String, !idStr.isEmpty else { return bad("'id' must be a non-empty string") }
        guard let en = enabled else { return bad("'enabled' must be a boolean") }
        guard let targetStr = d["target"] as? String else { return bad("'target' must be a string") }
        guard let actionStr = d["action"] as? String else { return bad("'action' must be a string") }
        if let note = d["note"], !(note is String) { return bad("'note' must be a string") }

        func ranged(_ key: String, _ range: ClosedRange<Int>, default def: Int? = nil) -> Result<Int, RuleError> {
            guard let v = d[key] else {
                if let def { return .success(def) }
                return .failure(RuleError(m: "missing key '\(key)'"))
            }
            guard let i = JSONRead.int(v) else { return .failure(RuleError(m: "'\(key)' must be an integer")) }
            guard range.contains(i) else {
                return .failure(RuleError(m: "'\(key)' out of range \(range.lowerBound)…\(range.upperBound)"))
            }
            return .success(i)
        }
        let fp: Int, cs: Int, cd: Int, mpd: Int
        switch ranged("footprintAboveMB", 1...65536) {
        case .success(let v): fp = v
        case .failure(let m): return bad(m.m)
        }
        switch ranged("consecutiveSamples", 1...20, default: 2) {
        case .success(let v): cs = v
        case .failure(let m): return bad(m.m)
        }
        switch ranged("cooldownMinutes", 1...1440) {
        case .success(let v): cd = v
        case .failure(let m): return bad(m.m)
        }
        switch ranged("maxPerDay", 1...48) {
        case .success(let v): mpd = v
        case .failure(let m): return bad(m.m)
        }
        guard allowedTargets.contains(targetStr), let target = RestartTarget(rawValue: targetStr) else {
            return bad("unknown target")
        }
        guard actionStr == "restart" else { return bad("unknown action") }
        let rule = Rule(id: idStr, note: d["note"] as? String, enabled: en, target: target,
                        action: actionStr, footprintAboveMB: fp, consecutiveSamples: cs,
                        cooldownMinutes: cd, maxPerDay: mpd)
        return RuleEntry(id: idStr, rule: rule, error: nil, enabled: en)
    }
}

// MARK: - Seed and write-back

public enum SeedResult: Sendable, Equatable {
    case seeded
    /// Not the release menu app with SWAPLESS_STATE_DIR unset.
    case notEligible
    /// The default dir already existed: no seed (a missing rules.json means no rules).
    case dirExisted
    case failed(String)
}

public enum WriteResult: Sendable, Equatable {
    case written
    /// The file changed on disk (or appeared) since the last load: reload instead.
    case skippedChanged
    /// The toggle is disabled while anything is invalid.
    case notAllowed
    case failed(String)
}

extension RulesFile {
    /// The only time a rule appears without the owner writing it (§ C): the release menu app,
    /// SWAPLESS_STATE_DIR unset, and its own mkdir of the default state dir succeeded. The
    /// default path and the flavour come in as parameters; this never computes them.
    public static func seedIfFirstLaunch(defaultStateDir: URL, flavour: Flavour,
                                         stateDirEnv: String?) -> SeedResult {
        guard flavour.isRelease, flavour.mode == .menuApp, stateDirEnv == nil else { return .notEligible }
        if mkdir(defaultStateDir.path, 0o700) != 0 {
            let e = errno
            return e == EEXIST ? .dirExisted : .failed(String(cString: strerror(e)))
        }
        switch atomicWrite(encode([seedRule], quit: .seed), to: url(in: defaultStateDir)) {
        case nil: return .seeded
        case let msg?: return .failed(msg)
        }
    }

    /// Pretty-printed, sorted keys, through the model. Always version 2 (S1).
    public static func encode(_ rules: [Rule], quit: QuitSettings) -> Data {
        let arr: [[String: Any]] = rules.map { r in
            var d: [String: Any] = [
                "id": r.id, "enabled": r.enabled, "target": r.target.rawValue, "action": r.action,
                "footprintAboveMB": r.footprintAboveMB, "consecutiveSamples": r.consecutiveSamples,
                "cooldownMinutes": r.cooldownMinutes, "maxPerDay": r.maxPerDay,
            ]
            if let n = r.note { d["note"] = n }
            return d
        }
        let top: [String: Any] = ["version": 2, "rules": arr, "quitOnLastWindow": quit.encodedSection,
                                  "apps": quit.encodedApps]
        let data = (try? JSONSerialization.data(withJSONObject: top, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return data + Data("\n".utf8)
    }

    /// temp file + rename(2). nil on success, else the error.
    static func atomicWrite(_ data: Data, to url: URL) -> String? {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(getpid())")
        do {
            try data.write(to: tmp)
        } catch {
            return error.localizedDescription
        }
        if rename(tmp.path, url.path) != 0 {
            let msg = String(cString: strerror(errno))
            unlink(tmp.path)
            return msg
        }
        return nil
    }

    static func unchanged(_ url: URL, since load: RulesLoad) -> Bool {
        guard let (m, s) = fileStat(url), let old = load.mtime else { return false }
        return m.tv_sec == old.tv_sec && m.tv_nsec == old.tv_nsec && s == load.size
    }

    /// The menu toggle: rewrites `enabled` through the model. Re-checks mtime and size first, so
    /// a hand edit is never clobbered.
    public static func writeEnabled(url: URL, load: RulesLoad, ruleId: String, enabled: Bool) -> WriteResult {
        guard load.allValid else { return .notAllowed }
        guard unchanged(url, since: load) else { return .skippedChanged }
        let rules = load.validRules.map { r -> Rule in
            var r = r
            if r.id == ruleId { r.enabled = enabled }
            return r
        }
        return write(url: url, load: load, rules: rules, quit: load.quit)
    }

    /// The guarded write every menu action shares: whole file valid, unchanged on disk since the
    /// load, then an atomic v2 write through the model.
    static func write(url: URL, load: RulesLoad, rules: [Rule], quit: QuitSettings) -> WriteResult {
        guard load.allValid else { return .notAllowed }
        guard unchanged(url, since: load) else { return .skippedChanged }
        var q = quit
        q.status = .ok
        q.error = nil
        if let e = atomicWrite(encode(rules, quit: q), to: url) { return .failed(e) }
        return .written
    }

    /// The menu's `Quit apps when their last window closes` toggle (S5).
    public static func writeQuitEnabled(url: URL, load: RulesLoad, enabled: Bool) -> WriteResult {
        var q = load.quit
        q.enabled = enabled
        return write(url: url, load: load, rules: load.validRules, quit: q)
    }

    /// `Never quit <Name>` / `Add running app`: adds the entry, or sets `neverQuit` on an
    /// existing one (keeping its name and note).
    public static func addNeverQuit(url: URL, load: RulesLoad, bundleId: String, name: String,
                                    now: Double, timeZone: TimeZone) -> WriteResult {
        var q = load.quit
        if let i = q.apps.firstIndex(where: { $0.bundleId == bundleId }) {
            q.apps[i].neverQuit = true
        } else {
            let c = ActivitySummary.calendar(timeZone).dateComponents([.year, .month, .day],
                                                                     from: Date(timeIntervalSince1970: now))
            let day = ActivitySummary.dayKey(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)
            q.apps.append(AppEntry(bundleId: bundleId, name: name, neverQuit: true, note: "Added from the menu \(day)"))
        }
        return write(url: url, load: load, rules: load.validRules, quit: q)
    }

    /// A click on a `Never quit` row: deletes the entry.
    public static func removeNeverQuit(url: URL, load: RulesLoad, bundleId: String) -> WriteResult {
        var q = load.quit
        q.apps.removeAll { $0.bundleId == bundleId }
        return write(url: url, load: load, rules: load.validRules, quit: q)
    }

    /// `Restore default rules`: only when the file is missing; if it appeared meanwhile, reload.
    public static func restoreDefault(url: URL) -> WriteResult {
        if fileStat(url) != nil { return .skippedChanged }
        if let e = atomicWrite(encode([seedRule], quit: .seed), to: url) { return .failed(e) }
        return .written
    }
}
