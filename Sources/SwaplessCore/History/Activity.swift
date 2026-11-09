import Foundation

/// What Swapless did, by kind (v1-menu-today S3, T8; v1-quit-on-close T10). The order is the
/// menu's: restarts, then quits.
public enum ActivityKind: String, CaseIterable, Sendable {
    case restart
    case quit
}

public struct ActivityCounts: Sendable, Equatable {
    /// Only kinds with a count > 0 are stored.
    public var byKind: [ActivityKind: Int]
    /// Outcomes `agent-missing`, `extension-missing`, `no-improvement`.
    public var failed: Int
    /// Signed sum of the rows' freed amounts (T10); nil when no row contributed one.
    public var freedMB: Double?

    public init(byKind: [ActivityKind: Int] = [:], failed: Int = 0, freedMB: Double? = nil) {
        self.byKind = byKind
        self.failed = failed
        self.freedMB = freedMB
    }

    public func count(_ k: ActivityKind) -> Int { byKind[k] ?? 0 }
    public var isEmpty: Bool { byKind.values.allSatisfy { $0 == 0 } }
}

public struct DayActivity: Sendable, Equatable {
    /// Unix time of the local midnight.
    public var dayStart: Double
    /// In the summary's time zone. `weekday` is 1 (Sunday) … 7 (Saturday).
    public var year: Int, month: Int, day: Int, weekday: Int
    public var running: Bool
    public var counts: ActivityCounts

    public init(dayStart: Double, year: Int, month: Int, day: Int, weekday: Int, running: Bool,
                counts: ActivityCounts) {
        self.dayStart = dayStart
        self.year = year
        self.month = month
        self.day = day
        self.weekday = weekday
        self.running = running
        self.counts = counts
    }

    /// `yyyy-MM-dd`, the local date.
    public var key: String { ActivitySummary.dayKey(year: year, month: month, day: day) }
}

public struct ActivitySummary: Sendable, Equatable {
    /// 7 entries, today first.
    public var days: [DayActivity]
    public var total: ActivityCounts

    public static let dayCount = 7
    public static let failedOutcomes: Set<String> = ["agent-missing", "extension-missing", "no-improvement"]
    public static let freedOutcomes: Set<String> = ["ok", "no-improvement"]

    public init(days: [DayActivity], total: ActivityCounts) {
        self.days = days
        self.total = total
    }

    /// v1-quit-on-close T10: the quit rule id first (whatever the target, a bundle id), then
    /// T8: `wallpaper` and the rig's DEBUG stand-in `rig-helper` are restarts; anything else
    /// isn't counted.
    public static func kind(of row: ActionRow) -> ActivityKind? {
        if row.ruleId == QuitDisplay.ruleId { return .quit }
        switch row.target {
        case "wallpaper", "rig-helper": return .restart
        default: return nil
        }
    }

    /// T10: before − after for the extension, plus before − after for WindowServer when both
    /// are known. Signed. nil when nothing was measured.
    public static func freedMB(of row: ActionRow) -> Double? {
        if kind(of: row) == .quit {
            // T10: an `ok` quit frees the app's footprint at quit time.
            return row.outcome == "ok" && row.beforeMB > 0 ? row.beforeMB : nil
        }
        guard freedOutcomes.contains(row.outcome), let after = row.afterMB, row.beforeMB > 0 else { return nil }
        var v = row.beforeMB - after
        if let wb = row.wsBeforeMB, let wa = row.wsAfterMB { v += wb - wa }
        return v
    }

    public static func dayKey(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func calendar(_ tz: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal
    }

    /// The local days `0 ..< count` (0 = today), each `[start, end)`, with its `yyyy-MM-dd`.
    /// DST days are 23 or 25 h.
    public static func dayRanges(now: Double, timeZone: TimeZone, count: Int = dayCount)
        -> [(start: Double, end: Double, key: String, comps: DateComponents)] {
        let cal = calendar(timeZone)
        let today = cal.startOfDay(for: Date(timeIntervalSince1970: now))
        var out: [(Double, Double, String, DateComponents)] = []
        var end = cal.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86400)
        for i in 0..<count {
            let start = cal.date(byAdding: .day, value: -i, to: today) ?? today.addingTimeInterval(-Double(i) * 86400)
            let c = cal.dateComponents([.year, .month, .day, .weekday], from: start)
            out.append((start.timeIntervalSince1970, end.timeIntervalSince1970,
                        dayKey(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0), c))
            end = start
        }
        return out
    }

    /// T10 + T11. `sampleDays`: the `yyyy-MM-dd` of past days with a `system_samples` row.
    public static func summarize(actions: [ActionRow], sampleDays: Set<String>,
                                 now: Double, timeZone: TimeZone) -> ActivitySummary {
        let ranges = dayRanges(now: now, timeZone: timeZone)
        var counts = Array(repeating: ActivityCounts(), count: ranges.count)
        for row in actions where !row.dryRun {
            guard let k = kind(of: row),
                  let i = ranges.firstIndex(where: { row.ts >= $0.start && row.ts < $0.end }) else { continue }
            // T10: a quit counts only when the app did quit (`refused` isn't a failure either).
            if k == .quit && row.outcome != "ok" { continue }
            counts[i].byKind[k, default: 0] += 1
            if failedOutcomes.contains(row.outcome) { counts[i].failed += 1 }
            if let f = freedMB(of: row) { counts[i].freedMB = (counts[i].freedMB ?? 0) + f }
        }
        var days: [DayActivity] = []
        var total = ActivityCounts()
        for (i, r) in ranges.enumerated() {
            let c = counts[i]
            let running = i == 0 || !c.isEmpty || sampleDays.contains(r.key)
            days.append(DayActivity(dayStart: r.start, year: r.comps.year ?? 0, month: r.comps.month ?? 0,
                                    day: r.comps.day ?? 0, weekday: r.comps.weekday ?? 1,
                                    running: running, counts: c))
            for (k, n) in c.byKind where n > 0 { total.byKind[k, default: 0] += n }
            total.failed += c.failed
            if let f = c.freedMB { total.freedMB = (total.freedMB ?? 0) + f }
        }
        return ActivitySummary(days: days, total: total)
    }
}

/// What the Today row shows.
public enum ActivityState: Sendable, Equatable {
    /// "history off" · "another Swapless is acting" · "not read by --print-menu"
    case notRecorded(reason: String)
    case summary(ActivitySummary)

    /// The headless `activity` line's body (everything but `type` and `t`).
    public var jsonFields: [(String, JSON)] {
        func countsJSON(_ c: ActivityCounts) -> [(String, JSON)] {
            [("restarts", .i(c.count(.restart))), ("quits", .i(c.count(.quit))), ("failed", .i(c.failed)),
             ("freedMB", .opt(c.freedMB))]
        }
        switch self {
        case .notRecorded(let reason):
            return [("recorded", .bool(false)), ("reason", .string(reason)), ("days", .array([])), ("total", .null)]
        case .summary(let s):
            let days: [JSON] = s.days.map { d in
                .object([("day", .string(d.key)), ("running", .bool(d.running))] + countsJSON(d.counts))
            }
            return [("recorded", .bool(true)), ("reason", .null), ("days", .array(days)),
                    ("total", .object(countsJSON(s.total)))]
        }
    }
}
