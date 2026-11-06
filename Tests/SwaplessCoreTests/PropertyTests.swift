import Foundation
import Testing
@testable import SwaplessCore

/// § J property: whatever the snapshot and the rules file, the sender is only ever called with
/// pids whose path is on the code allowlist and whose euid is ours.
@Suite("S4 · property: only allowlisted targets are ever signalled")
struct PropertyTests {
    static let ownUid: UInt32 = 501

    struct Case {
        var snapshot: Snapshot
        var rulesJSON: String
        var helper: String?
    }

    static func pick<T>(_ xs: [T], _ rng: inout SplitMix64) -> T { xs[Int(rng.next() % UInt64(xs.count))] }
    static func chance(_ p: Double, _ rng: inout SplitMix64) -> Bool { rng.uniform(0, 1) < p }

    static func makeCase(seed: UInt64) -> Case {
        var rng = SplitMix64(seed: seed &* 0x2545_F491_4F6C_DD1D &+ 7)
        let helper: String? = chance(0.5, &rng) ? helperPath : nil
        let pool = [ext, agent, helperPath, "/elsewhere/swapless-leak-helper",
                    "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
                    "/Applications/Safari.app/Contents/MacOS/Safari", "/usr/bin/top",
                    "/fake/WallpaperImageExtension", ext + ".bak", agent.uppercased(), "",
                    "/Users/x/.local/share/claude/versions/2.1.318"]
        var entries: [ProcessSample] = []
        var used = Set<Int32>()
        let n = 3 + Int(rng.next() % 30)
        for _ in 0..<n {
            var pid = Int32(Int(rng.next() % 3000)) - 2  // includes -2…1 sometimes
            if chance(0.05, &rng) { pid = 99_999 }  // the "own" pid of the sender
            guard used.insert(pid).inserted else { continue }
            let euid: UInt32 = pick([501, 501, 501, 0, 88, 502], &rng)
            let path = pick(pool, &rng)
            let mb = rng.uniform(0, 3000)
            entries.append(proc(pid, euid: euid, start: Int64(rng.next() % 1000), path: path,
                                coalition: UInt64(rng.next() % 20), footprintMB: mb,
                                readable: euid == ownUid))
        }
        // In ≥ 30 % of cases, a same-euid allowlisted process clearly above the threshold of a
        // valid rule for its target.
        var forcedRule: String?
        if chance(0.45, &rng) {
            var pid: Int32 = 5000 + Int32(rng.next() % 1000)
            while used.contains(pid) { pid += 1 }
            used.insert(pid)
            let path = (helper != nil && chance(0.3, &rng)) ? helperPath : ext
            entries.append(proc(pid, start: 7, path: path, coalition: 77, footprintMB: 2500 + rng.uniform(0, 500)))
            let t = path == ext ? "wallpaper" : "rig-helper"
            forcedRule = "{\"id\":\"forced\",\"enabled\":true,\"target\":\"\(t)\",\"action\":\"restart\",\"footprintAboveMB\":\(pick([1, 100, 500, 1024, 2048], &rng)),\"consecutiveSamples\":\(1 + rng.next() % 3),\"cooldownMinutes\":\(1 + rng.next() % 60),\"maxPerDay\":\(1 + rng.next() % 5)}"
            if path == ext && chance(0.8, &rng) {
                var apid: Int32 = 7000
                while used.contains(apid) { apid += 1 }
                used.insert(apid)
                entries.append(proc(apid, start: 8, path: agent, coalition: 78, footprintMB: 25))
            }
        }
        // Random rules.
        var rules: [String] = []
        let count = Int(rng.next() % 4)
        for k in 0..<count {
            let target = k == 0 && chance(0.75, &rng)
                ? pick(["wallpaper", "rig-helper"], &rng)
                : pick(["wallpaper", "rig-helper", "WindowServer", "Safari", "", "claude"], &rng)
            let action = chance(0.85, &rng) ? "restart" : pick(["quit", "kill", ""], &rng)
            let mbv = pick([1, 100, 500, 1024, 2048, 0, 70_000], &rng)
            var r = "\"id\":\"r\(k)\",\"enabled\":\(chance(0.8, &rng)),\"target\":\"\(target)\",\"action\":\"\(action)\",\"footprintAboveMB\":\(mbv),\"consecutiveSamples\":\(1 + rng.next() % 3),\"cooldownMinutes\":\(1 + rng.next() % 60),\"maxPerDay\":\(1 + rng.next() % 5)"
            if chance(0.05, &rng) { r += ",\"pid\":\(rng.next() % 3000)" }
            if chance(0.05, &rng) { r += ",\"path\":\"/usr/bin/top\"" }
            rules.append("{\(r)}")
        }
        if let f = forcedRule { rules.insert(f, at: 0) }
        var json = "{\"version\":1,\"rules\":[\(rules.joined(separator: ","))]}"
        if chance(0.03, &rng) { json = "{\"version\":1,\"rules\":[" }
        if chance(0.03, &rng) { json = "{\"version\":1,\"rules\":[],\"pids\":[1,2,3]}" }
        return Case(snapshot: snapshot(entries), rulesJSON: json, helper: helper)
    }

    static func allowlisted(_ e: ProcessSample, helper: String?) -> Bool {
        guard e.euid == ownUid else { return false }
        if e.path == ext || e.path == agent { return true }
        if let helper, e.path == helper, ProcessTable.basename(e.path) == RestartTarget.rigHelperBasename { return true }
        return false
    }

    @Test func thousandRandomSnapshotsAndRuleFiles() {
        var casesCalled = 0
        var casesAbove = 0
        var badCalls: [String] = []
        for seed in 0..<1000 {
            let c = Self.makeCase(seed: UInt64(seed))
            var allowed: Set<String> = ["wallpaper"]
            if c.helper != nil { allowed.insert("rig-helper") }
            let rules = RulesFile.decode(Data(c.rulesJSON.utf8), allowedTargets: allowed)
            let s = c.snapshot
            // Is a same-euid allowlisted process above a valid rule's threshold?
            var above = false
            for r in rules.validRules {
                let trig = RuleEvaluator.triggers(r.target, in: s, ctx: ctx(helper: c.helper))
                switch r.target {
                case .wallpaper: above = above || trig.reduce(UInt64(0)) { $0 + $1.footprint } > r.thresholdBytes
                #if DEBUG
                case .rigHelper: above = above || trig.contains { $0.footprint > r.thresholdBytes }
                #endif
                }
            }
            if above { casesAbove += 1 }

            let sender = RecordingSender()
            let rec = MemoryRecorder()
            let a = Actuator(inspector: FixtureProcessInspector(snapshot: s), sender: sender, ownUid: Self.ownUid,
                             dryRun: false, sink: nil)
            var st = EvaluatorState()
            for tick in 0..<3 {
                let cx = EvaluationContext(now: 1_800_000_000 + Double(tick), ownUid: Self.ownUid, actions: rec.rows,
                                           pauses: [:], verifying: [], rigHelperPath: c.helper)
                let r = RuleEvaluator.evaluate(snapshot: s, rules: rules, ctx: cx, state: &st)
                for i in r.intents {
                    _ = a.execute(i, now: cx.now, recorder: rec, wsBeforeMB: nil)
                }
            }
            if !sender.calls.isEmpty { casesCalled += 1 }
            for call in sender.calls {
                guard let e = s.entries.first(where: { $0.pid == call.pid }), Self.allowlisted(e, helper: c.helper) else {
                    badCalls.append("seed \(seed): pid \(call.pid) target \(call.target)")
                    continue
                }
            }
        }
        print("property: \(casesAbove) of 1000 cases above threshold, sender called in \(casesCalled), \(badCalls.count) bad calls")
        #expect(badCalls.isEmpty, "signalled outside the allowlist: \(badCalls.prefix(5))")
        #expect(casesAbove >= 300, "only \(casesAbove) of 1000 cases above threshold")
        #expect(casesCalled >= 100, "the sender was called in only \(casesCalled) cases")
    }
}
