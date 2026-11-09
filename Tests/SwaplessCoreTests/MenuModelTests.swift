import Foundation
import Testing
@testable import SwaplessCore

@Suite("S2/S4/S5 · MenuModel strings")
struct MenuModelTests {
    func state(rules: RulesLoad = .missing) -> EngineState {
        var st = EngineState()
        let s = syntheticMac()
        var sys = SystemSample(freePct: 62, pressure: 1, swapUsedBytes: 1_073_741_824,
                               swapinBytesPerSec: 0, swapinsTotal: 0,
                               compressedBytes: UInt64(2.7 * 1_073_741_824))
        sys.swapinBytesPerSec = 0
        var snap = s
        snap.system = sys
        st.snapshot = snap
        st.groups = grouper().group(snap)
        st.rules = rules
        st.selfReading = SelfReading(cpuSeconds: 1, childCpuSeconds: 0, cpuPercent: 0.5,
                                     footprint: 21 * MB, peakFootprint: 25 * MB, cpuPercentIdle: 0.02)
        return st
    }

    func titles(_ items: [MenuItem]) -> [String] { items.filter { !$0.isSeparator }.map(\.title) }

    @Test func numberFormats() {
        #expect(MenuModel.value(UInt64(1.42 * 1_073_741_824)) == "1.42 GB")
        #expect(MenuModel.value(305 * MB) == "305 MB")
        #expect(MenuModel.value(nil) == "not readable")
        #expect(MenuModel.headerGB(UInt64(2.7 * 1_073_741_824)) == "2.7 GB")
        #expect(MenuModel.threshold(mb: 1024) == "1 GB")
        #expect(MenuModel.threshold(mb: 1500) == "1500 MB")
        #expect(MenuModel.slope(150) == "+150 MB/h")
    }

    @Test func headersAndFooter() {
        let t = titles(MenuModel.build(MenuInput(state: state())))
        #expect(t[0] == "Free 62 % · Pressure normal")
        #expect(t[1] == "Compressed 2.7 GB · Swap 1.0 GB · Swap-in 0.0 MB/s")
        #expect(t.contains("Swapless 0.02 % CPU idle · 21 MB · measuring: full"))
        #expect(t.last == "Quit Swapless")
    }

    @Test func measuringBeforeTheFirstSample() {
        let t = titles(MenuModel.build(MenuInput(state: EngineState())))
        #expect(t.contains("Measuring…"))
        #expect(!t.contains("Growing"))
    }

    @Test func groupAndMemberRows() throws {
        let items = MenuModel.build(MenuInput(state: state(), compressed: [501: 302 * MB, 502: 5 * MB]))
        let safari = try #require(items.first { $0.title.hasPrefix("Safari: ") })
        #expect(safari.title == "Safari: 1.80 GB")
        let rows = try #require(safari.children).map(\.title)
        #expect(rows[0] == "Web Content (pid 501): 1.20 GB (302 MB compressed)")
        #expect(rows.contains("Web Content (pid 502): 400 MB"))  // < 10 MB compressed: no suffix
        let ws = try #require(items.first { $0.title.hasPrefix("WindowServer · system") })
        #expect(ws.children?.first?.title == "+ 2 system processes: 1.16 GB")
        #expect(ws.children?.first?.children?.map(\.title) == ["WindowServer", "MTLCompilerService"])
    }

    @Test func flaggedGroupGetsArrowAndSlope() throws {
        var st = state()
        let wie = st.snapshot!.entries.first { $0.pid == 700 }!
        st.flags = [FlagInfo(seriesKey: wie.identity.seriesKey, pid: 700, label: "WallpaperImageExtension",
                             footprint: UInt64(1.1 * 1_073_741_824), slopeMBPerHour: 150, baselineMB: 160,
                             reason: "slope", coveredByRuleThresholdMB: 1024)]
        let t = titles(MenuModel.build(MenuInput(state: st)))
        #expect(t.contains("↑ WallpaperImageExtension: 1.10 GB (+150 MB/h)"))
        #expect(t.contains("Growing"))
        #expect(t.contains("WallpaperImageExtension: 1.10 GB (+150 MB/h) (guard restarts at 1 GB)"))
    }

    @Test func growingCapsAtFive() {
        var st = state()
        st.flags = (0..<7).map { FlagInfo(seriesKey: "proc:\($0):1.000000", pid: Int32($0), label: "p\($0)",
                                          footprint: 600 * MB, slopeMBPerHour: 120, baselineMB: 100, reason: "slope") }
        let t = titles(MenuModel.build(MenuInput(state: st)))
        #expect(t.filter { $0.hasPrefix("p") && $0.contains("+120 MB/h") }.count == 5)
        #expect(t.contains("and 2 more"))
    }

    @Test func everythingElse() {
        var st = state()
        var s = st.snapshot!
        for i in 0..<5 {
            s.entries.append(proc(Int32(5000 + i), name: "small\(i)", coalition: UInt64(5000 + i), footprintMB: 1))
            s.coalitions[UInt64(5000 + i)] = CoalitionSample(cid: UInt64(5000 + i), footprint: MB, started: 1, exited: 0)
        }
        st.snapshot = s
        st.groups = grouper().group(s)
        #expect(st.groups.count == 15)
        let t = titles(MenuModel.build(MenuInput(state: st)))
        #expect(t.contains("Everything else: 5 MB in 5 groups"))
    }

    func seedLoad() -> RulesLoad {
        var r = RulesFile.decode(Data("""
        {"version":1,"rules":[{"id":"wallpaper-leak-guard","enabled":true,"target":"wallpaper","action":"restart",
        "footprintAboveMB":1024,"consecutiveSamples":2,"cooldownMinutes":30,"maxPerDay":8}]}
        """.utf8), allowedTargets: ["wallpaper"])
        r.mtime = timespec(tv_sec: 1, tv_nsec: 0)
        r.size = 1
        return r
    }

    func rulesTitles(_ st: EngineState, now: Double = 1_800_000_000) -> [String] {
        titles(MenuModel.rulesSection(MenuInput(state: st, now: now, timeZone: TimeZone(identifier: "UTC")!)))
    }

    @Test func statusLinePerOutcome() {
        var st = state(rules: seedLoad())
        let now = 1_800_000_000.0
        func with(_ outcome: String, after: Double? = nil, dry: Bool = false) -> [String] {
            st.ruleDisplays = [RuleDisplay(ruleId: "wallpaper-leak-guard", enabled: true, thresholdMB: 1024,
                                           pausedReason: nil,
                                           lastAction: ActionDisplay(id: 1, ts: now - 60, beforeMB: 1239, afterMB: after,
                                                                     outcome: outcome, dryRun: dry),
                                           triggerFootprint: 412 * MB)]
            return rulesTitles(st, now: now)
        }
        // 1_800_000_000 − 60 s = 07:59 UTC.
        #expect(with("pending")[1] == "Last restart 07:59: 1.21 GB → verifying…")
        #expect(with("ok", after: 110)[1] == "Last restart 07:59: 1.21 GB → 110 MB")
        #expect(with("interrupted")[1] == "Last restart 07:59: 1.21 GB → interrupted")
        #expect(with("no-improvement")[1] == "Last restart 07:59: 1.21 GB → no-improvement")
        // Dry runs never show here.
        #expect(with("dry-run", dry: true)[1] == "Watching: WallpaperImageExtension 412 MB")
        #expect(rulesTitles(st, now: now)[0] == "Wallpaper guard: restarts above 1 GB")
    }

    @Test func pausedNotRunningAndOld() {
        var st = state(rules: seedLoad())
        st.ruleDisplays = [RuleDisplay(ruleId: "wallpaper-leak-guard", enabled: true, thresholdMB: 1024,
                                       pausedReason: "agent-missing", lastAction: nil, triggerFootprint: 412 * MB)]
        #expect(rulesTitles(st) == ["Wallpaper guard: restarts above 1 GB", "Paused: agent-missing", "Resume", "Quit apps when their last window closes", "Never quit"])
        st.ruleDisplays = [RuleDisplay(ruleId: "wallpaper-leak-guard", enabled: true, thresholdMB: 1024,
                                       pausedReason: nil, lastAction: nil, triggerFootprint: nil)]
        #expect(rulesTitles(st) == ["Wallpaper guard: restarts above 1 GB", "Not running", "Quit apps when their last window closes", "Never quit"])
        // An action older than 30 min falls through to Watching.
        st.ruleDisplays = [RuleDisplay(ruleId: "wallpaper-leak-guard", enabled: true, thresholdMB: 1024,
                                       pausedReason: nil,
                                       lastAction: ActionDisplay(id: 1, ts: 1_800_000_000 - 31 * 60, beforeMB: 1239,
                                                                 afterMB: 110, outcome: "ok", dryRun: false),
                                       triggerFootprint: 412 * MB)]
        #expect(rulesTitles(st)[1] == "Watching: WallpaperImageExtension 412 MB")
    }

    @Test func restoreOnlyWhenTheFileIsMissing() {
        let missing = rulesTitles(state(rules: .missing))
        #expect(missing == ["No wallpaper rule", "Quit apps when their last window closes", "Never quit", "Restore default rules"])
        let empty = RulesFile.decode(Data("{\"version\":1,\"rules\":[]}".utf8), allowedTargets: ["wallpaper"])
        let t = rulesTitles(state(rules: empty))
        #expect(t == ["No wallpaper rule", "Quit apps when their last window closes", "Never quit", "Open rules file…"])
        #expect(!t.contains("Restore default rules"))
        let invalid = RulesFile.decode(Data("{nope".utf8), allowedTargets: ["wallpaper"])
        let ti = rulesTitles(state(rules: invalid))
        #expect(ti == ["No wallpaper rule", "Quit apps when their last window closes", "Never quit", "rules.json: not valid JSON", "Open rules file…"])
    }

    @Test func toggleDisabledWhileAnythingIsInvalid() throws {
        let r = RulesFile.decode(Data("""
        {"version":1,"rules":[{"id":"w","enabled":true,"target":"wallpaper","action":"restart","footprintAboveMB":1024,"cooldownMinutes":30,"maxPerDay":8},
        {"id":"x","enabled":true,"target":"WindowServer","action":"restart","footprintAboveMB":1,"cooldownMinutes":1,"maxPerDay":1}]}
        """.utf8), allowedTargets: ["wallpaper"])
        let items = MenuModel.rulesSection(MenuInput(state: state(rules: r)))
        let toggle = try #require(items.first { $0.slot == "rule.wallpaper" })
        #expect(!toggle.enabled)
        #expect(items.contains { $0.title == "rules.json: x: unknown target" })
        #expect(items.contains { $0.title == "Open rules file…" })
    }

    @Test func footerVariants() {
        var st = state()
        st.source = .top
        st.dryRun = true
        st.overBudget = true
        st.historyError = "disk full"
        st.observeOnly = true
        #expect(MenuModel.footer(st) == "Swapless 0.02 % CPU idle · 21 MB · measuring: degraded (top) · dry run · over budget · history off: disk full · another Swapless is acting")
        st = state()
        st.source = .none
        #expect(MenuModel.footer(st) == "Swapless 0.02 % CPU idle · 21 MB · not measuring system processes")
    }

    /// v1-menu-today S1: the footer shows the menu-closed average, labelled idle.
    @Test func footerShowsIdleCPU() {
        var st = state()
        st.selfReading = SelfReading(cpuSeconds: 1, childCpuSeconds: 0, cpuPercent: 0.95,
                                     footprint: 33 * MB, peakFootprint: 40 * MB, cpuPercentIdle: 0.11)
        #expect(MenuModel.footer(st) == "Swapless 0.11 % CPU idle · 33 MB · measuring: full")
        st.selfReading?.cpuPercentIdle = nil
        #expect(MenuModel.footer(st) == "Swapless — % CPU idle · 33 MB · measuring: full")
        st.overBudget = true
        #expect(MenuModel.footer(st) == "Swapless — % CPU idle · 33 MB · measuring: full · over budget")
        st.selfReading = nil
        st.overBudget = false
        #expect(MenuModel.footer(st) == "Swapless · measuring: full")
    }

    // MARK: v1-menu-today S4: the Today row

    func counts(_ n: Int, failed: Int = 0, freed: Double? = nil) -> ActivityCounts {
        ActivityCounts(byKind: n > 0 ? [.restart: n] : [:], failed: failed, freedMB: freed)
    }

    @Test func activityBodies() {
        #expect("Today: " + MenuModel.activityBody(counts(2, freed: 2851.1)) == "Today: 2 restarts · 2.8 GB freed")
        #expect("Today: " + MenuModel.activityBody(counts(1)) == "Today: 1 restart")
        #expect("Today: " + MenuModel.activityBody(counts(3, failed: 1, freed: 2150)) == "Today: 3 restarts (1 failed) · 2.1 GB freed")
        #expect("Today: " + MenuModel.activityBody(counts(0)) == "Today: no restarts or quits")
        #expect("7 days: " + MenuModel.activityBody(counts(7, freed: 9113.6)) == "7 days: 7 restarts · 8.9 GB freed")
        #expect(MenuModel.activityBody(counts(1, freed: -50)) == "1 restart · 0 MB freed")
        #expect(MenuModel.activityBody(counts(1, freed: 512.4)) == "1 restart · 512 MB freed")
    }

    var tz: TimeZone { TimeZone(identifier: "America/Mexico_City")! }

    func summaryState() -> EngineState {
        var st = state()
        let now = localTs(2026, 11, 6, 12, 0, tz: tz)
        let rows = [actionRow(id: 1, ts: localTs(2026, 11, 6, 9, 0, tz: tz), before: 1258, after: 133, wsBefore: 1524, wsAfter: 1139),
                    actionRow(id: 2, ts: localTs(2026, 11, 6, 10, 0, tz: tz), before: 1075.2, after: 148.1, wsBefore: 1495.5, wsAfter: 1081.5)]
        st.activity = .summary(ActivitySummary.summarize(actions: rows, sampleDays: ["2026-11-05", "2026-11-04", "2026-11-02"],
                                                         now: now, timeZone: tz))
        return st
    }

    @Test func todayRowAndSubmenu() throws {
        let items = MenuModel.build(MenuInput(state: summaryState()))
        let today = try #require(items.first { $0.slot == "today" })
        #expect(today.title == "Today: 2 restarts · 2.8 GB freed")
        #expect(today.enabled && today.action == nil)
        let c = try #require(today.children)
        #expect(c.map(\.slot) == ["today.day.0", "today.day.1", "today.day.2", "today.day.3", "today.day.4",
                                  "today.day.5", "today.day.6", "today.sep", "today.total"])
        #expect(c[0].title == "Today: 2 restarts · 2.8 GB freed")
        #expect(c[1].title == "Yesterday: no restarts or quits")
        #expect(c[2].title == "Wed 4 Nov: no restarts or quits")
        #expect(c[3].title == "Tue 3 Nov: not running")
        #expect(c[4].title == "Mon 2 Nov: no restarts or quits")
        #expect(c[6].title == "Sat 31 Oct: not running")
        #expect(c[7].isSeparator)
        #expect(c[8].title == "7 days: 2 restarts · 2.8 GB freed")
        #expect(c.allSatisfy { !$0.enabled })
        // Position: after sep.rules, then sep.today, then the footer.
        let slots = items.map(\.slot)
        let i = try #require(slots.firstIndex(of: "today"))
        #expect(slots[i - 1] == "sep.rules")
        #expect(slots[i + 1] == "sep.today")
        #expect(slots[i + 2] == "footer")
        // --print-menu text indents the 9 children.
        let text = MenuModel.text([today])
        #expect(text.split(separator: "\n").filter { $0.hasPrefix("    ") }.count == 9)
    }

    @Test func notRecordedReasons() {
        for reason in ["history off", "another Swapless is acting", "not read by --print-menu"] {
            let row = MenuModel.todayRow(.notRecorded(reason: reason))
            #expect(row.title == "Today: not recorded (\(reason))")
            #expect(!row.enabled)
            #expect(row.children == nil)
        }
    }
}
