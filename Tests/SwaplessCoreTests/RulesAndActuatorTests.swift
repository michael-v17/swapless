import Foundation
import Testing
@testable import SwaplessCore

let ext = RestartTarget.wallpaperExtensionPath
let agent = RestartTarget.wallpaperAgentPath
let helperPath = "/repo/.build/out/Products/Debug/swapless-leak-helper"

func wallRule(_ mb: Int = 1024, enabled: Bool = true, consecutive: Int = 2, cooldown: Int = 30,
              maxPerDay: Int = 8, id: String = "wallpaper-leak-guard") -> String {
    "{\"id\":\"\(id)\",\"enabled\":\(enabled),\"target\":\"wallpaper\",\"action\":\"restart\",\"footprintAboveMB\":\(mb),\"consecutiveSamples\":\(consecutive),\"cooldownMinutes\":\(cooldown),\"maxPerDay\":\(maxPerDay)}"
}

func load(_ rules: [String], allowed: Set<String> = ["wallpaper", "rig-helper"]) -> RulesLoad {
    RulesFile.decode(Data("{\"version\":1,\"rules\":[\(rules.joined(separator: ","))]}".utf8), allowedTargets: allowed)
}

/// A snapshot with the wallpaper pair (+ optional extra extension instances).
func wallpaperSnapshot(extMB: [Double] = [1100], extStart: Int64 = 100, agentPid: Int32 = 701,
                       otherEuidExtMB: Double? = nil, t: Double = 1_800_000_000) -> Snapshot {
    var e: [ProcessSample] = []
    for (i, mb) in extMB.enumerated() {
        e.append(proc(Int32(700 + 10 * i), start: extStart + Int64(i), path: ext, coalition: UInt64(29980 + i), footprintMB: mb))
    }
    e.append(proc(agentPid, start: 50, path: agent, coalition: 664, footprintMB: 25))
    if let o = otherEuidExtMB {
        e.append(proc(900, euid: 502, start: 10, path: ext, coalition: 5000, footprintMB: o, readable: false))
        e.append(proc(901, euid: 502, start: 10, path: agent, coalition: 5001, footprintMB: 20, readable: false))
    }
    return snapshot(e, t: t)
}

func ctx(now: Double = 1_800_000_000, actions: [ActionRow] = [], pauses: [String: String] = [:],
         verifying: Set<String> = [], helper: String? = helperPath) -> EvaluationContext {
    EvaluationContext(now: now, ownUid: 501, actions: actions, pauses: pauses, verifying: verifying,
                      rigHelperPath: helper)
}

func row(_ id: Int64, ts: Double, rule: String = "wallpaper-leak-guard", outcome: String = "ok",
         dry: Bool = false) -> ActionRow {
    ActionRow(id: id, ts: ts, ruleId: rule, target: "wallpaper", pids: [], beforeMB: 1100, afterMB: nil,
              outcome: outcome, dryRun: dry, wsBeforeMB: nil, wsAfterMB: nil)
}

@Suite("S4 · rule evaluation order")
struct EvaluatorTests {
    func reasons(_ snaps: [Snapshot], _ rules: RulesLoad, _ c: EvaluationContext = ctx()) -> ([String], [Intent]) {
        var st = EvaluatorState()
        var out: [String] = []
        var intents: [Intent] = []
        for s in snaps {
            let r = RuleEvaluator.evaluate(snapshot: s, rules: rules, ctx: c, state: &st)
            out += r.decisions.map(\.reason)
            intents += r.intents
            if !r.intents.isEmpty { out.append("FIRE") }
        }
        return (out, intents)
    }

    @Test func eightSteps() {
        let s = wallpaperSnapshot()
        // 1. invalid or disabled.
        #expect(reasons([s], load([wallRule(enabled: false)])).0 == ["disabled"])
        #expect(reasons([s], load(["{\"id\":\"x\",\"enabled\":true}"])).0 == ["disabled"])
        // 2. paused.
        #expect(reasons([s], load([wallRule()]), ctx(pauses: ["wallpaper-leak-guard": "agent-missing"])).0 == ["paused"])
        // 3. target absent.
        #expect(reasons([snapshot([])], load([wallRule()])).0 == ["target-absent"])
        // 4. below threshold (strictly above is required).
        #expect(reasons([wallpaperSnapshot(extMB: [1024])], load([wallRule()])).0 == ["below-threshold"])
        // 5. consecutive-pending then 8. fire.
        let (r, intents) = reasons([s, s], load([wallRule()]))
        #expect(r == ["consecutive-pending", "FIRE"])
        #expect(intents.count == 1)
        // 6. cooldown (dry runs and interrupted count).
        for o in ["ok", "dry-run", "interrupted"] {
            let c = ctx(actions: [row(1, ts: 1_800_000_000 - 60, outcome: o, dry: o == "dry-run")])
            #expect(reasons([s, s], load([wallRule()]), c).0 == ["consecutive-pending", "cooldown"])
        }
        // 7. max-per-day (dry runs and interrupted count).
        let base = 1_800_000_000.0
        let day: [ActionRow] = [
            row(0, ts: base - 3600, outcome: "interrupted"),
            row(1, ts: base - 7200, outcome: "dry-run", dry: true),
            row(2, ts: base - 10800, outcome: "dry-run", dry: true),
        ]
        #expect(reasons([s, s], load([wallRule(maxPerDay: 3)]), ctx(actions: day)).0 == ["consecutive-pending", "max-per-day"])
        #expect(reasons([s, s], load([wallRule(maxPerDay: 4)]), ctx(actions: day)).0 == ["consecutive-pending", "FIRE"])
    }

    @Test func decisionsAreTransitionsOnlyAndAFireResets() {
        let s = wallpaperSnapshot()
        var st = EvaluatorState()
        let rules = load([wallRule(consecutive: 1)])
        let below = wallpaperSnapshot(extMB: [500])
        var all: [String] = []
        for snap in [below, below, s, below, below] {
            let r = RuleEvaluator.evaluate(snapshot: snap, rules: rules, ctx: ctx(), state: &st)
            all += r.decisions.map(\.reason) + r.intents.map { _ in "FIRE" }
        }
        // below-threshold once, fire, then below-threshold again (the fire reset the last reason).
        #expect(all == ["below-threshold", "FIRE", "below-threshold"])
    }

    @Test func wallpaperSetChangeRestartsTheCount() {
        let rules = load([wallRule(consecutive: 2)])
        let a = wallpaperSnapshot(extStart: 100)
        let b = wallpaperSnapshot(extStart: 200)  // a respawned extension: new identity
        #expect(reasons([a, b, b], rules).0 == ["consecutive-pending", "FIRE"])
        // An added instance also changes the set.
        let two = wallpaperSnapshot(extMB: [600, 600], extStart: 100)
        #expect(reasons([a, two, two], rules).0 == ["consecutive-pending", "FIRE"])
        let (r, _) = reasons([a, two], rules)
        #expect(!r.contains("FIRE"))
    }

    @Test func multiInstanceWallpaperIsSummedAndAllRestarted() throws {
        let s = wallpaperSnapshot(extMB: [600, 600])  // 1200 > 1024 only as a sum
        let (_, intents) = reasons([s, s], load([wallRule()]))
        let i = try #require(intents.first)
        #expect(i.trigger.count == 2)
        #expect(abs(i.beforeMB - 1200) < 0.001)
        #expect(i.restartSet.map(\.path) == [ext, ext, agent])  // extensions first, then the agent
    }

    @Test func anotherUsersWallpaperIsNeverATrigger() {
        var e = wallpaperSnapshot(extMB: [], otherEuidExtMB: 5000).entries
        e.removeAll { $0.path == agent && $0.euid == 501 }
        let s = snapshot(e)
        #expect(reasons([s, s], load([wallRule()])).0 == ["target-absent"])
    }

    @Test func inFlightVerify() {
        let s = wallpaperSnapshot()
        let rules = load([wallRule()])
        let v = ctx(verifying: ["wallpaper-leak-guard"])
        // Above threshold for consecutiveSamples same-identity ticks → cooldown, no second fire.
        #expect(reasons([s, s, s], rules, v).0 == ["consecutive-pending", "cooldown"])
        // The respawned extension near 110 MB → below-threshold; gone → target-absent.
        #expect(reasons([wallpaperSnapshot(extMB: [110])], rules, v).0 == ["below-threshold"])
        #expect(reasons([snapshot([proc(701, path: agent, coalition: 1, footprintMB: 20)])], rules, v).0 == ["target-absent"])
    }

    @Test func rigHelperEachIdentityKeepsItsOwnCount() throws {
        let rule = "{\"id\":\"h\",\"enabled\":true,\"target\":\"rig-helper\",\"action\":\"restart\",\"footprintAboveMB\":200,\"consecutiveSamples\":2,\"cooldownMinutes\":5,\"maxPerDay\":2}"
        let rules = load([rule])
        let a = proc(10, start: 1, path: helperPath, coalition: 1, footprintMB: 300)
        let b = proc(11, start: 2, path: helperPath, coalition: 1, footprintMB: 100)
        let decoy = proc(12, start: 3, path: "/elsewhere/swapless-leak-helper", coalition: 1, footprintMB: 900)
        let s = snapshot([a, b, decoy])
        let (r, intents) = reasons([s, s], rules)
        #expect(r == ["consecutive-pending", "FIRE"])
        let i = try #require(intents.first)
        #expect(i.restartSet.map(\.pid) == [10])  // only the triggering identity
        // Without SWAPLESS_RIG_HELPER_PATH nothing resolves.
        #expect(reasons([s, s], rules, ctx(helper: nil)).0 == ["target-absent"])
    }

    @Test func maxPerDayPauseHelper() throws {
        let rule = try #require(load([wallRule(maxPerDay: 2)]).validRules.first)
        let now = 1_800_000_000.0
        #expect(!RuleEvaluator.reachesMaxPerDay(rule: rule, actions: [row(1, ts: now)], now: now))
        #expect(RuleEvaluator.reachesMaxPerDay(rule: rule, actions: [row(1, ts: now - 100), row(2, ts: now, outcome: "dry-run", dry: true)], now: now))
        #expect(!RuleEvaluator.reachesMaxPerDay(rule: rule, actions: [row(1, ts: now - 90000), row(2, ts: now)], now: now))
    }
}

/// An in-memory action log.
final class MemoryRecorder: ActionRecorder {
    var rows: [ActionRow] = []
    var failInsert = false

    func insertAction(ts: Double, ruleId: String, target: String, pids: [Int32], beforeMB: Double,
                      outcome: String, dryRun: Bool) -> Int64? {
        if failInsert { return nil }
        let id = Int64(rows.count + 1)
        rows.append(ActionRow(id: id, ts: ts, ruleId: ruleId, target: target, pids: pids, beforeMB: beforeMB,
                              afterMB: nil, outcome: outcome, dryRun: dryRun, wsBeforeMB: nil, wsAfterMB: nil))
        return id
    }

    func updateOutcome(id: Int64, outcome: String, afterMB: Double?, wsBeforeMB: Double?, wsAfterMB: Double?) -> Bool {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return false }
        rows[i].outcome = outcome
        rows[i].afterMB = afterMB
        return true
    }
}

/// Records every call; refuses like the real senders.
final class RecordingSender: SignalSender, @unchecked Sendable {
    var calls: [(pid: Int32, target: RestartTarget)] = []
    func sigterm(pid: Int32, target: RestartTarget) -> SignalResult {
        if let r = SignalGuard.refusal(pid: pid, target: target, ownPid: 99_999, refuseWallpaper: false) {
            return .refused(r)
        }
        calls.append((pid, target))
        return .sent
    }
}

@Suite("S4 · actuator")
struct ActuatorTests {
    func intent(_ s: Snapshot) throws -> Intent {
        var st = EvaluatorState()
        let rules = load([wallRule(consecutive: 1)])
        let r = RuleEvaluator.evaluate(snapshot: s, rules: rules, ctx: ctx(), state: &st)
        return try #require(r.intents.first)
    }

    @Test func identityChangedWritesNoRowAndSendsNothing() throws {
        let s = wallpaperSnapshot()
        var changed = s
        changed.entries[0].startSec += 5  // the extension was replaced in between
        let rec = MemoryRecorder()
        let snd = RecordingSender()
        let a = Actuator(inspector: FixtureProcessInspector(snapshot: changed), sender: snd, ownUid: 501, dryRun: false, sink: nil)
        #expect(a.execute(try intent(s), now: 1, recorder: rec, wsBeforeMB: nil) == .identityChanged)
        #expect(rec.rows.isEmpty)
        #expect(snd.calls.isEmpty)
    }

    @Test func historyOffSendsNothing() throws {
        let s = wallpaperSnapshot()
        let rec = MemoryRecorder()
        rec.failInsert = true
        let snd = RecordingSender()
        let a = Actuator(inspector: FixtureProcessInspector(snapshot: s), sender: snd, ownUid: 501, dryRun: false, sink: nil)
        #expect(a.execute(try intent(s), now: 1, recorder: rec, wsBeforeMB: nil) == .historyOff)
        #expect(a.execute(try intent(s), now: 1, recorder: nil, wsBeforeMB: nil) == .historyOff)
        #expect(snd.calls.isEmpty)
    }

    @Test func dryRunWritesADryRunRowAndSendsNothing() throws {
        let s = wallpaperSnapshot()
        let rec = MemoryRecorder()
        let snd = RecordingSender()
        let a = Actuator(inspector: FixtureProcessInspector(snapshot: s), sender: snd, ownUid: 501, dryRun: true, sink: nil)
        #expect(a.execute(try intent(s), now: 1, recorder: rec, wsBeforeMB: nil) == .dryRun(actionId: 1))
        #expect(rec.rows.first?.outcome == "dry-run")
        #expect(rec.rows.first?.dryRun == true)
        #expect(snd.calls.isEmpty)
    }

    @Test func rowBeforeSignalThenExtensionsThenAgent() throws {
        let s = wallpaperSnapshot(extMB: [600, 600])
        let rec = MemoryRecorder()
        let snd = RecordingSender()
        let a = Actuator(inspector: FixtureProcessInspector(snapshot: s), sender: snd, ownUid: 501, dryRun: false, sink: nil)
        let r = a.execute(try intent(s), now: 1, recorder: rec, wsBeforeMB: 2300)
        guard case .verifying(let plan) = r else {
            Issue.record("expected verifying, got \(r)")
            return
        }
        #expect(rec.rows.count == 1 && rec.rows[0].outcome == "pending")
        #expect(snd.calls.map(\.pid) == [700, 710, 701])
        #expect(plan.preSet.count == 3)
    }

    func verify(_ steps: [(elapsed: Double, procs: [InspectedProcess])], before: Double = 1200) -> VerifyResult? {
        let insp = FixtureProcessInspector([])
        let a = Actuator(inspector: insp, sender: RecordingSender(), ownUid: 501, dryRun: false, sink: nil)
        let old = ProcessIdentity(pid: 700, startSec: 100, startUsec: 0)
        let oldAgent = ProcessIdentity(pid: 701, startSec: 50, startUsec: 0)
        var plan = VerifyPlan(ruleId: "w", actionId: 1, preSet: [old, oldAgent], beforeMB: before, wsBeforeMB: 2300)
        for st in steps {
            insp.set(st.procs)
            if let r = a.poll(&plan, elapsed: st.elapsed, wsNowMB: { 1200 }) { return r }
        }
        return nil
    }

    let newAgent = InspectedProcess(identity: ProcessIdentity(pid: 801, startSec: 900, startUsec: 0), path: agent, euid: 501, footprint: 20 << 20)
    func newExt(_ mb: UInt64) -> InspectedProcess {
        InspectedProcess(identity: ProcessIdentity(pid: 802, startSec: 901, startUsec: 0), path: ext, euid: 501, footprint: mb << 20)
    }

    @Test func verifyOk() {
        let r = verify([(2, []), (4, [newAgent]), (10, [newAgent, newExt(110)]), (70, [newAgent, newExt(111)])])
        #expect(r == VerifyResult(outcome: "ok", afterMB: 111, wsAfterMB: 1200))
    }

    @Test func verifyNoImprovement() {
        let r = verify([(4, [newAgent]), (10, [newAgent, newExt(700)]), (70, [newAgent, newExt(700)])])
        #expect(r?.outcome == "no-improvement")
    }

    @Test func verifyAgentMissing() {
        let r = verify([(2, []), (20, []), (32, [])])
        #expect(r?.outcome == "agent-missing")
    }

    @Test func verifyExtensionMissing() {
        let r = verify([(4, [newAgent]), (60, [newAgent]), (122, [newAgent])])
        #expect(r?.outcome == "extension-missing")
    }

    @Test func oldIdentitiesDontCountAsBack() {
        let oldExt = InspectedProcess(identity: ProcessIdentity(pid: 700, startSec: 100, startUsec: 0), path: ext, euid: 501, footprint: 1 << 30)
        let r = verify([(4, [newAgent, oldExt]), (122, [newAgent, oldExt])])
        #expect(r?.outcome == "extension-missing")
    }
}

@Suite("S4 · signal guard")
struct SignalGuardTests {
    @Test func refusals() {
        for pid: Int32 in [0, -1, 1] {
            #expect(SignalGuard.refusal(pid: pid, target: .wallpaper, ownPid: 50, refuseWallpaper: false) == "pid-out-of-range")
        }
        #expect(SignalGuard.refusal(pid: 50, target: .wallpaper, ownPid: 50, refuseWallpaper: false) == "own-pid")
        #expect(SignalGuard.refusal(pid: 51, target: .wallpaper, ownPid: 50, refuseWallpaper: true) == "debug-build-refuses-wallpaper")
        #expect(SignalGuard.refusal(pid: 51, target: .wallpaper, ownPid: 50, refuseWallpaper: false) == nil)
        #if DEBUG
        for pid: Int32 in [2, 51, 99_999] {
            #expect(SignalGuard.refusal(pid: pid, target: .rigHelper, ownPid: 50, refuseWallpaper: true) == nil)
        }
        #expect(SignalGuard.refusal(pid: 50, target: .rigHelper, ownPid: 50, refuseWallpaper: true) == "own-pid")
        #endif
    }

    @Test func dryRunSenderAppliesTheSamePidRefusals() {
        let s = DryRunSignalSender(ownPid: 50)
        #expect(s.sigterm(pid: 0, target: .wallpaper) == .refused("pid-out-of-range"))
        #expect(s.sigterm(pid: -1, target: .wallpaper) == .refused("pid-out-of-range"))
        #expect(s.sigterm(pid: 1, target: .wallpaper) == .refused("pid-out-of-range"))
        #expect(s.sigterm(pid: 50, target: .wallpaper) == .refused("own-pid"))
        #expect(s.sigterm(pid: 51, target: .wallpaper) == .sent)  // refuseWallpaper: false
        #expect(s.calls.map(\.pid) == [51])
    }
}

@Suite("S4 · seed, refusal, write-back, interrupted")
struct RulesStateTests {
    func fakeDefault() -> URL {
        let root = makeTempDir()
        try! FileManager.default.createDirectory(at: root.appendingPathComponent("Application Support"),
                                                 withIntermediateDirectories: true)
        return root.appendingPathComponent("Application Support/Swapless")
    }

    @Test func seedsOnlyOnTheReleaseAppsOwnMkdir() throws {
        let d = fakeDefault()
        #expect(RulesFile.seedIfFirstLaunch(defaultStateDir: d, flavour: Flavour(isRelease: true, mode: .menuApp), stateDirEnv: nil) == .seeded)
        let r = RulesFile.load(url: RulesFile.url(in: d), allowedTargets: ["wallpaper"])
        #expect(r.status == .ok)
        #expect(r.validRules == [RulesFile.seedRule])
        let text = try String(contentsOf: RulesFile.url(in: d), encoding: .utf8)
        #expect(text.contains("\"footprintAboveMB\" : 1024"))
        // Owner decision 2026-11-05 (DECISIONS.md): maxPerDay 24; threshold and cooldown unchanged.
        #expect(text.contains("\"maxPerDay\" : 24,"))
        #expect(text.contains("\"cooldownMinutes\" : 30,"))
        // A second launch: the dir exists, nothing is rewritten.
        #expect(RulesFile.seedIfFirstLaunch(defaultStateDir: d, flavour: Flavour(isRelease: true, mode: .menuApp), stateDirEnv: nil) == .dirExisted)
    }

    @Test func noSeedForAnExistingEmptyDirTempDirHeadlessOrDebug() throws {
        let d = fakeDefault()
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        #expect(RulesFile.seedIfFirstLaunch(defaultStateDir: d, flavour: Flavour(isRelease: true, mode: .menuApp), stateDirEnv: nil) == .dirExisted)
        #expect(!FileManager.default.fileExists(atPath: RulesFile.url(in: d).path))
        let d2 = fakeDefault()
        #expect(RulesFile.seedIfFirstLaunch(defaultStateDir: d2, flavour: Flavour(isRelease: true, mode: .menuApp), stateDirEnv: "/tmp/x") == .notEligible)
        for mode in [Flavour.Mode.headless, .printMenu, .dumpSnapshot] {
            #expect(RulesFile.seedIfFirstLaunch(defaultStateDir: d2, flavour: Flavour(isRelease: true, mode: mode), stateDirEnv: nil) == .notEligible)
        }
        #expect(RulesFile.seedIfFirstLaunch(defaultStateDir: d2, flavour: Flavour(isRelease: false, mode: .menuApp), stateDirEnv: nil) == .notEligible)
        #expect(!FileManager.default.fileExists(atPath: d2.path))
    }

    @Test func toggleRoundTripDisabledWhileInvalidSkippedWhenChanged() throws {
        let dir = makeTempDir()
        let url = RulesFile.url(in: dir)
        try Data("{\"version\":1,\"rules\":[\(wallRule())]}".utf8).write(to: url)
        var l = RulesFile.load(url: url, allowedTargets: ["wallpaper"])
        #expect(RulesFile.writeEnabled(url: url, load: l, ruleId: "wallpaper-leak-guard", enabled: false) == .written)
        l = RulesFile.load(url: url, allowedTargets: ["wallpaper"])
        #expect(l.validRules.first?.enabled == false)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\n"))  // pretty-printed
        // A hand edit after the load: skipped, never clobbered.
        Thread.sleep(forTimeInterval: 0.01)
        try Data("{\"version\":1,\"rules\":[\(wallRule(2048))]}".utf8).write(to: url)
        #expect(RulesFile.writeEnabled(url: url, load: l, ruleId: "wallpaper-leak-guard", enabled: true) == .skippedChanged)
        #expect(RulesFile.load(url: url, allowedTargets: ["wallpaper"]).validRules.first?.footprintAboveMB == 2048)
        // Disabled while anything is invalid.
        try Data("{\"version\":1,\"rules\":[\(wallRule()),{\"id\":\"x\"}]}".utf8).write(to: url)
        let bad = RulesFile.load(url: url, allowedTargets: ["wallpaper"])
        #expect(RulesFile.writeEnabled(url: url, load: bad, ruleId: "wallpaper-leak-guard", enabled: false) == .notAllowed)
    }

    @Test func restoreOnlyWhenMissing() throws {
        let dir = makeTempDir()
        let url = RulesFile.url(in: dir)
        #expect(RulesFile.restoreDefault(url: url) == .written)
        #expect(RulesFile.load(url: url, allowedTargets: ["wallpaper"]).validRules == [RulesFile.seedRule])
        #expect(RulesFile.restoreDefault(url: url) == .skippedChanged)
    }

    @Test func pendingBecomesInterruptedAtStart() {
        let dir = makeTempDir()
        let h = HistoryStore(stateDir: dir, currentRuleIds: [], now: 1)
        _ = h.insertAction(ts: 1, ruleId: "w", target: "wallpaper", pids: [1], beforeMB: 1, outcome: "pending", dryRun: false)
        _ = h.insertAction(ts: 2, ruleId: "w", target: "wallpaper", pids: [1], beforeMB: 1, outcome: "ok", dryRun: false)
        let changed = h.markPendingInterrupted()
        #expect(changed.map(\.id) == [1])
        #expect(h.actions(since: 0).map(\.outcome) == ["interrupted", "ok"])
        #expect(h.pauses().isEmpty)  // interrupted doesn't pause
    }
}
