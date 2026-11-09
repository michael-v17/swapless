import Foundation

/// What a menu row does when clicked.
public enum MenuAction: Sendable, Equatable {
    case toggleRule(String)
    case resumeRule(String)
    case restoreRules
    case openRules
    case toggleLogin
    case quit
    /// v1-quit-on-close S5.
    case toggleQuitOnClose
    case addNeverQuit(String, String)
    case removeNeverQuit(String)
    case openAccessibilitySettings
}

/// A running Dock app the `Add running app` submenu can offer (S5).
public struct RunningApp: Sendable, Equatable {
    public var bundleId: String
    public var name: String

    public init(bundleId: String, name: String) {
        self.bundleId = bundleId
        self.name = name
    }
}

/// One row of the pure text model. `slot` is a stable id so the app can update rows in place.
public struct MenuItem: Sendable, Equatable {
    public var slot: String
    public var title: String
    public var enabled: Bool
    public var checked: Bool
    public var isSeparator: Bool
    public var action: MenuAction?
    public var keyEquivalent: String?
    /// Submenu rows; nil = no submenu.
    public var children: [MenuItem]?
    /// For group rows: the group key (the app reads compressed values for its members on open).
    public var groupKey: String?

    public init(slot: String, title: String, enabled: Bool = false, checked: Bool = false,
                isSeparator: Bool = false, action: MenuAction? = nil, keyEquivalent: String? = nil,
                children: [MenuItem]? = nil, groupKey: String? = nil) {
        self.slot = slot
        self.title = title
        self.enabled = enabled
        self.checked = checked
        self.isSeparator = isSeparator
        self.action = action
        self.keyEquivalent = keyEquivalent
        self.children = children
        self.groupKey = groupKey
    }

    public static func separator(_ slot: String) -> MenuItem {
        MenuItem(slot: slot, title: "", isSeparator: true)
    }
}

/// A flagged series, as the menu needs it (§ H, S5 item 5).
public struct FlagInfo: Sendable, Equatable {
    public var seriesKey: String
    public var pid: Int32?
    public var label: String
    public var footprint: UInt64
    public var slopeMBPerHour: Double?
    public var baselineMB: Double?
    public var reason: String
    /// Covered by an enabled rule (the guard handles it, so it isn't actionable).
    public var coveredByRuleThresholdMB: Int?

    public init(seriesKey: String, pid: Int32?, label: String, footprint: UInt64,
                slopeMBPerHour: Double?, baselineMB: Double?, reason: String,
                coveredByRuleThresholdMB: Int? = nil) {
        self.seriesKey = seriesKey
        self.pid = pid
        self.label = label
        self.footprint = footprint
        self.slopeMBPerHour = slopeMBPerHour
        self.baselineMB = baselineMB
        self.reason = reason
        self.coveredByRuleThresholdMB = coveredByRuleThresholdMB
    }
}

/// The last action row of a rule, for the S4 status line.
public struct ActionDisplay: Sendable, Equatable {
    public var id: Int64
    public var ts: Double
    public var beforeMB: Double
    public var afterMB: Double?
    public var outcome: String
    public var dryRun: Bool

    public init(id: Int64, ts: Double, beforeMB: Double, afterMB: Double?, outcome: String, dryRun: Bool) {
        self.id = id
        self.ts = ts
        self.beforeMB = beforeMB
        self.afterMB = afterMB
        self.outcome = outcome
        self.dryRun = dryRun
    }
}

/// The wallpaper rule's live status (S4).
public struct RuleDisplay: Sendable, Equatable {
    public var ruleId: String
    public var enabled: Bool
    public var thresholdMB: Int
    public var pausedReason: String?
    /// The latest non-dry-run action, if any.
    public var lastAction: ActionDisplay?
    /// The trigger's current footprint (nil = not running).
    public var triggerFootprint: UInt64?

    public init(ruleId: String, enabled: Bool, thresholdMB: Int, pausedReason: String?,
                lastAction: ActionDisplay?, triggerFootprint: UInt64?) {
        self.ruleId = ruleId
        self.enabled = enabled
        self.thresholdMB = thresholdMB
        self.pausedReason = pausedReason
        self.lastAction = lastAction
        self.triggerFootprint = triggerFootprint
    }
}

/// Everything the menu shows, as plain values.
public struct MenuInput: Sendable {
    public var state: EngineState
    /// pid → compressed bytes, read only for the submenu being opened.
    public var compressed: [Int32: UInt64]
    public var loginEnabled: Bool
    public var now: Double
    public var timeZone: TimeZone
    /// Running Dock apps (bundle id, `localizedName`), read when the menu opens (S5).
    public var runningApps: [RunningApp]

    public init(state: EngineState, compressed: [Int32: UInt64] = [:], loginEnabled: Bool = false,
                now: Double = Date().timeIntervalSince1970, timeZone: TimeZone = .current,
                runningApps: [RunningApp] = []) {
        self.state = state
        self.compressed = compressed
        self.loginEnabled = loginEnabled
        self.now = now
        self.timeZone = timeZone
        self.runningApps = runningApps
    }
}

/// The pure text model of the menu (S2, S4, S5). Used by the app and by `--print-menu`.
public enum MenuModel {
    public static let topGroups = 10
    public static let topMembers = 15
    public static let growingRows = 5
    static let gib = 1_073_741_824.0
    static let mib = 1_048_576.0

    // MARK: number formats (S2)

    /// Group and member values: ≥ 1 GB with two decimals, smaller ones whole MB.
    public static func value(_ bytes: UInt64?) -> String {
        guard let bytes else { return "not readable" }
        let b = Double(bytes)
        if b >= gib { return String(format: "%.2f GB", b / gib) }
        return "\(Int((b / mib).rounded())) MB"
    }

    public static func valueMB(_ mbValue: Double) -> String {
        value(UInt64(max(0, mbValue) * mib))
    }

    /// Header values: one decimal.
    public static func headerGB(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / gib)
    }

    /// Rule thresholds: `1 GB` when divisible by 1024, otherwise MB.
    public static func threshold(mb: Int) -> String {
        mb % 1024 == 0 ? "\(mb / 1024) GB" : "\(mb) MB"
    }

    public static func slope(_ mbPerHour: Double) -> String {
        let v = Int(mbPerHour.rounded())
        return v >= 0 ? "+\(v) MB/h" : "\(v) MB/h"
    }

    // MARK: build

    public static func build(_ input: MenuInput) -> [MenuItem] {
        let st = input.state
        var items: [MenuItem] = []
        if let s = st.snapshot {
            let sys = s.system
            items.append(MenuItem(slot: "header.1",
                                  title: "Free \(sys.freePct) % · Pressure \(SystemMemory.pressureName(sys.pressure))"))
            let swapin = sys.swapinBytesPerSec.map { String(format: "%.1f MB/s", $0 / mib) } ?? "—"
            items.append(MenuItem(slot: "header.2",
                                  title: "Compressed \(headerGB(sys.compressedBytes)) · Swap \(headerGB(sys.swapUsedBytes)) · Swap-in \(swapin)"))
        } else {
            items.append(MenuItem(slot: "header.1", title: "Free — · Pressure —"))
            items.append(MenuItem(slot: "header.2", title: "Compressed — · Swap — · Swap-in —"))
        }
        items.append(.separator("sep.groups.top"))
        items += groupRows(input)
        items.append(.separator("sep.groups.bottom"))
        let growing = growingRows(input)
        if !growing.isEmpty {
            items += growing
            items.append(.separator("sep.growing"))
        }
        items += rulesSection(input)
        items.append(.separator("sep.rules"))
        items.append(todayRow(st.activity))
        items.append(.separator("sep.today"))
        items.append(MenuItem(slot: "footer", title: footer(st)))
        items.append(MenuItem(slot: "login", title: "Open at login", enabled: true,
                              checked: input.loginEnabled, action: .toggleLogin))
        items.append(MenuItem(slot: "quit", title: "Quit Swapless", enabled: true, action: .quit,
                              keyEquivalent: "q"))
        return items
    }

    static func groupRows(_ input: MenuInput) -> [MenuItem] {
        let st = input.state
        guard let s = st.snapshot else {
            return [MenuItem(slot: "measuring", title: "Measuring…")]
        }
        let flagged = Dictionary(st.flags.map { ($0.seriesKey, $0) }, uniquingKeysWith: { a, _ in a })
        var rows: [MenuItem] = []
        for (n, g) in st.groups.prefix(topGroups).enumerated() {
            // A group with a flagged series: its coalition key or any member's process key.
            var flag: FlagInfo? = flagged[g.key]
            if flag == nil {
                for i in g.members {
                    if let f = flagged[s.entries[i].identity.seriesKey] {
                        flag = f
                        break
                    }
                }
            }
            var title = "\(flag != nil ? "↑ " : "")\(g.label): \(value(g.footprint))"
            if let sl = flag?.slopeMBPerHour { title += " (\(slope(sl)))" }
            rows.append(MenuItem(slot: "group.\(n)", title: title, enabled: true,
                                 children: memberRows(g, in: s, compressed: input.compressed),
                                 groupKey: g.key))
        }
        let rest = st.groups.dropFirst(topGroups)
        if !rest.isEmpty {
            let sum = rest.reduce(UInt64(0)) { $0 + ($1.footprint ?? 0) }
            rows.append(MenuItem(slot: "everything-else",
                                 title: "Everything else: \(value(sum)) in \(rest.count) groups"))
        }
        return rows
    }

    /// Member rows: top 15 numbered members, `+ N smaller processes`, then `+ N system
    /// processes: X MB` (their names under it).
    public static func memberRows(_ g: ProcessGroup, in s: Snapshot,
                                  compressed: [Int32: UInt64]) -> [MenuItem] {
        let numbered = g.members.filter { s.entries[$0].footprint != nil }
        let unnumbered = g.members.filter { s.entries[$0].footprint == nil }
        var rows: [MenuItem] = []
        for (n, i) in numbered.prefix(topMembers).enumerated() {
            let e = s.entries[i]
            var title = "\(Labeler.memberName(e)): \(value(e.footprint))"
            if e.readable, let c = compressed[e.pid], Double(c) >= 10 * mib {
                title += " (\(value(c)) compressed)"
            }
            rows.append(MenuItem(slot: "member.\(n)", title: title))
        }
        let smaller = numbered.dropFirst(topMembers)
        if !smaller.isEmpty {
            let sum = smaller.reduce(UInt64(0)) { $0 + (s.entries[$1].footprint ?? 0) }
            rows.append(MenuItem(slot: "member.smaller",
                                 title: "+ \(smaller.count) smaller processes: \(value(sum))"))
        }
        if !unnumbered.isEmpty {
            let names = unnumbered.map { MenuItem(slot: "member.system.\(s.entries[$0].pid)",
                                                  title: Labeler.memberName(s.entries[$0])) }
            rows.append(MenuItem(slot: "member.system",
                                 title: "+ \(unnumbered.count) system processes: \(value(g.unreadableBytes))",
                                 enabled: true, children: names))
        }
        return rows
    }

    static func growingRows(_ input: MenuInput) -> [MenuItem] {
        let flags = input.state.flags
        guard !flags.isEmpty else { return [] }
        var rows = [MenuItem(slot: "growing.title", title: "Growing")]
        for (n, f) in flags.prefix(growingRows).enumerated() {
            var title = "\(f.label): \(value(f.footprint))"
            if let sl = f.slopeMBPerHour { title += " (\(slope(sl)))" } else if f.reason == "fast" {
                title += " (fast)"
            }
            if let t = f.coveredByRuleThresholdMB { title += " (guard restarts at \(threshold(mb: t)))" }
            rows.append(MenuItem(slot: "growing.\(n)", title: title))
        }
        if flags.count > growingRows {
            rows.append(MenuItem(slot: "growing.more", title: "and \(flags.count - growingRows) more"))
        }
        return rows
    }

    static func hhmm(_ ts: Double, _ tz: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: ts))
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func rulesSection(_ input: MenuInput) -> [MenuItem] {
        let st = input.state
        let rules = st.rules
        var rows: [MenuItem] = []
        let fileExists = rules.status != .missing
        let wallpaper = rules.validRules.first { $0.target == .wallpaper }
        if let rule = wallpaper {
            rows.append(MenuItem(slot: "rule.wallpaper",
                                 title: "Wallpaper guard: restarts above \(threshold(mb: rule.footprintAboveMB))",
                                 enabled: rules.allValid && !st.observeOnly, checked: rule.enabled,
                                 action: .toggleRule(rule.id)))
            let d = st.ruleDisplays.first { $0.ruleId == rule.id }
            if let reason = d?.pausedReason {
                rows.append(MenuItem(slot: "rule.status", title: "Paused: \(reason)"))
                rows.append(MenuItem(slot: "rule.resume", title: "Resume", enabled: !st.observeOnly,
                                     action: .resumeRule(rule.id)))
            } else if let a = d?.lastAction, !a.dryRun, input.now - a.ts <= 30 * 60 {
                let head = "Last restart \(hhmm(a.ts, input.timeZone)): \(valueMB(a.beforeMB)) → "
                let tail: String
                switch a.outcome {
                case "pending": tail = "verifying…"
                case "ok": tail = a.afterMB.map(valueMB) ?? "ok"
                default: tail = a.outcome
                }
                rows.append(MenuItem(slot: "rule.status", title: head + tail))
            } else if let fp = d?.triggerFootprint {
                rows.append(MenuItem(slot: "rule.status", title: "Watching: WallpaperImageExtension \(value(fp))"))
            } else {
                rows.append(MenuItem(slot: "rule.status", title: "Not running"))
            }
        } else {
            rows.append(MenuItem(slot: "rule.none", title: "No wallpaper rule"))
        }
        rows += quitRows(input)
        if rules.status == .invalid {
            rows.append(MenuItem(slot: "rule.error.file", title: "rules.json: \(rules.fileError ?? "invalid")"))
        }
        for (n, e) in rules.entries.enumerated() where !e.valid {
            let id = e.id.isEmpty ? "rule \(n + 1)" : e.id
            rows.append(MenuItem(slot: "rule.error.\(n)", title: "rules.json: \(id): \(e.error ?? "invalid")"))
        }
        if !fileExists {
            rows.append(MenuItem(slot: "rule.restore", title: "Restore default rules",
                                 enabled: !st.observeOnly, action: .restoreRules))
        } else if wallpaper == nil || !rules.allValid {
            rows.append(MenuItem(slot: "rule.open", title: "Open rules file…", enabled: true,
                                 action: .openRules))
        }
        return rows
    }

    // MARK: quit on last window close (v1-quit-on-close S5)

    public static let quitToggleTitle = "Quit apps when their last window closes"

    static func quitRows(_ input: MenuInput) -> [MenuItem] {
        let st = input.state
        let q = st.quit
        let s = q.settings
        let writable = st.rules.allValid && !st.observeOnly
        let invalid = s.status == .invalid
        var rows: [MenuItem] = [.separator("sep.quit")]
        rows.append(MenuItem(slot: "quit.toggle", title: quitToggleTitle, enabled: writable, checked: s.enabled,
                             action: .toggleQuitOnClose))
        let protected = s.neverQuitIds.union([QuitSettings.finderBundleId])
        if s.enabled || invalid {
            if let p = q.paused {
                rows.append(MenuItem(slot: "quit.status", title: "Paused: \(p)"))
                if p == "needs Accessibility" {
                    rows.append(MenuItem(slot: "quit.accessibility", title: "Open Accessibility settings…", enabled: true,
                                         action: .openAccessibilitySettings))
                }
            } else if let l = q.lastQuit, ["pending", "ok", "refused", "not-sent"].contains(l.outcome) {
                let at = hhmm(l.ts, input.timeZone)
                let title: String
                switch l.outcome {
                case "pending": title = "Quitting \(l.name)…"
                case "ok": title = "Last quit \(at): \(l.name) · \(valueMB(l.beforeMB))"
                case "refused": title = "\(at): \(l.name) didn't quit · left open"
                default: title = "\(at): \(l.name) couldn't be asked to quit"
                }
                rows.append(MenuItem(slot: "quit.status", title: title))
                if (l.outcome == "ok" || l.outcome == "refused") && !protected.contains(l.bundleId) {
                    rows.append(MenuItem(slot: "quit.never.offer", title: "Never quit \(l.name)", enabled: writable,
                                         action: .addNeverQuit(l.bundleId, l.name)))
                }
            } else {
                rows.append(MenuItem(slot: "quit.status", title: "Watching \(q.watching) app\(q.watching == 1 ? "" : "s")"))
            }
        }
        if invalid, let e = s.error {
            rows.append(MenuItem(slot: "quit.error", title: "rules.json: \(e)"))
        }
        var kids = [MenuItem(slot: "quit.never.finder", title: "Finder (always)", enabled: false, checked: true)]
        for a in s.apps where a.neverQuit {
            kids.append(MenuItem(slot: "quit.never.app.\(a.bundleId)", title: a.name, enabled: writable, checked: true,
                                 action: .removeNeverQuit(a.bundleId)))
        }
        kids.append(.separator("quit.never.sep"))
        let candidates = input.runningApps.filter { !protected.contains($0.bundleId) }
            .sorted { a, b in
                let c = a.name.localizedCaseInsensitiveCompare(b.name)
                return c == .orderedSame ? a.bundleId < b.bundleId : c == .orderedAscending
            }
        let addKids: [MenuItem] = candidates.isEmpty
            ? [MenuItem(slot: "quit.add.none", title: "No other apps running")]
            : candidates.map { MenuItem(slot: "quit.add.app.\($0.bundleId)", title: $0.name, enabled: writable,
                                        action: .addNeverQuit($0.bundleId, $0.name)) }
        kids.append(MenuItem(slot: "quit.add", title: "Add running app", enabled: true, children: addKids))
        rows.append(MenuItem(slot: "quit.never", title: "Never quit", enabled: true, children: kids))
        return rows
    }

    // MARK: the Today row (v1-menu-today S4)

    static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    public static func todayRow(_ a: ActivityState) -> MenuItem {
        switch a {
        case .notRecorded(let reason):
            return MenuItem(slot: "today", title: "Today: not recorded (\(reason))")
        case .summary(let s):
            var rows: [MenuItem] = []
            for (i, d) in s.days.enumerated() {
                rows.append(MenuItem(slot: "today.day.\(i)", title: "\(dayLabel(d, index: i)): \(dayBody(d))"))
            }
            rows.append(.separator("today.sep"))
            rows.append(MenuItem(slot: "today.total", title: "7 days: \(activityBody(s.total))"))
            let first = s.days.first.map { activityBody($0.counts) } ?? activityBody(ActivityCounts())
            return MenuItem(slot: "today", title: "Today: \(first)", enabled: true, children: rows)
        }
    }

    /// `Today`, `Yesterday`, then `Tue 3 Nov` from the day's own components (no DateFormatter,
    /// so it is always in the summary's time zone).
    static func dayLabel(_ d: DayActivity, index: Int) -> String {
        switch index {
        case 0: return "Today"
        case 1: return "Yesterday"
        default:
            let wd = weekdayNames[max(0, min(6, d.weekday - 1))]
            let mo = monthNames[max(0, min(11, d.month - 1))]
            return "\(wd) \(d.day) \(mo)"
        }
    }

    static func dayBody(_ d: DayActivity) -> String {
        d.running ? activityBody(d.counts) : "not running"
    }

    /// `2 restarts (1 failed) · 3 quits · 4.1 GB freed`, or `no restarts or quits`
    /// (v1-quit-on-close S4: the failed suffix attaches to the restarts part).
    public static func activityBody(_ c: ActivityCounts) -> String {
        let parts = ActivityKind.allCases.compactMap { k -> String? in
            let n = c.count(k)
            guard n > 0 else { return nil }
            var p = "\(n) \(k.rawValue)\(n == 1 ? "" : "s")"
            if k == .restart && c.failed > 0 { p += " (\(c.failed) failed)" }
            return p
        }
        guard !parts.isEmpty else { return "no restarts or quits" }
        var s = parts.joined(separator: " · ")
        if let f = c.freedMB { s += " · \(freed(f)) freed" }
        return s
    }

    /// Floored at 0: ≥ 1024 MB as `%.1f GB`, else whole MB.
    static func freed(_ mbValue: Double) -> String {
        let m = max(0, mbValue)
        return m >= 1024 ? String(format: "%.1f GB", m / 1024) : "\(Int(m.rounded())) MB"
    }

    public static func footer(_ st: EngineState) -> String {
        var s = "Swapless"
        if let r = st.selfReading {
            // The menu-closed 10-min average (owner call 1): the same quantity "over budget" uses.
            let cpu = r.cpuPercentIdle.map { String(format: "%.2f", $0) } ?? "—"
            s += " \(cpu) % CPU idle · \(Int((Double(r.footprint) / mib).rounded())) MB"
        }
        switch st.source {
        case .coalition: s += " · measuring: full"
        case .top: s += " · measuring: degraded (top)"
        case .none: s += " · not measuring system processes"
        }
        if st.dryRun { s += " · dry run" }
        if st.overBudget { s += " · over budget" }
        if let h = st.historyError { s += " · history off: \(h)" }
        if st.observeOnly { s += " · another Swapless is acting" }
        return s
    }

    /// `--print-menu` text: one row per line, submenus indented.
    public static func text(_ items: [MenuItem], indent: String = "") -> String {
        var out = ""
        for i in items {
            if i.isSeparator {
                out += indent + "────────\n"
                continue
            }
            var line = indent
            if i.checked { line += "✓ " }
            line += i.title
            if !i.enabled && i.action == nil && i.children == nil { line += "" }
            if i.keyEquivalent == "q" { line += "  ⌘Q" }
            out += line + "\n"
            if let c = i.children { out += text(c, indent: indent + "    ") }
        }
        return out
    }
}
