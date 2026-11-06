import Darwin
import Foundation
import SwaplessCore

/// `/usr/bin/log show` window used by the "unchanged" exception and the proofs.
func logStamp(_ t: Double) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.string(from: Date(timeIntervalSince1970: t))
}

let installedActionsPredicate = "subsystem == \"com.michaelv.swapless\" AND category == \"actions\" AND processImagePath == \"/Applications/Swapless.app/Contents/MacOS/Swapless\""

extension Rig {
    /// Wallpaper identities unchanged since `before`, or changed only with a matching action
    /// logged by the installed Swapless in that window.
    func wallpaperUnchanged(since before: [ProcessIdentity], windowStart: Double) -> (ok: Bool, note: String) {
        let after = wallpaperIdentities()
        if after == before { return (true, "wallpaper identities unchanged") }
        let r = run("/usr/bin/log", ["show", "--start", logStamp(windowStart - 1), "--predicate", installedActionsPredicate])
        let installedActed = r.out.contains("action id=")
        let desc = "wallpaper identities changed: before \(before.map(\.pid)) after \(after.map(\.pid))"
        if installedActed { return (true, desc + " (the installed Swapless logged an action in this window)") }
        return (false, desc + " with no installed-app action logged")
    }
}

/// Check 3 · no-action-without-rule.
enum Check3 {
    static func run(_ rig: Rig, check2: Check2Run?) -> Outcome {
        var problems: [String] = []
        var notes: [String] = []

        // The check-2 run (empty rules).
        var c2 = check2
        if c2 == nil {
            rig.report.line("  check 3: running check 2's scenario first (its pass criteria are not evaluated)")
            let (o, r) = Check2.run(rig, evaluate: false)
            if case .fail(let why) = o { return .fail("check 2 scenario: \(why)") }
            c2 = r
        }
        if let c2 {
            let actions = c2.engine.events("action").count
            let markers = c2.helpers.filter { FileManager.default.fileExists(atPath: $0.marker) }.map(\.name)
            let notOwn = c2.helpers.filter { !$0.child.exitedOnItsOwn }.map { "\($0.name)(exit \($0.child.exitStatus))" }
            let wp = rig.wallpaperUnchanged(since: c2.wallpaperBefore, windowStart: c2.startedAt)
            notes.append("check-2 run: \(actions) actions, markers \(markers), helpers not exiting on their own \(notOwn); \(wp.note)")
            if actions != 0 { problems.append("check-2 run: \(actions) action events") }
            if !markers.isEmpty { problems.append("check-2 run: markers \(markers)") }
            if !notOwn.isEmpty { problems.append("check-2 run: \(notOwn) did not exit on their own") }
            if !wp.ok { problems.append("check-2 run: \(wp.note)") }
        } else {
            problems.append("no check-2 run to assert on")
        }

        // The 8 s runs.
        let helperPath = rig.helperPath
        let runs: [(name: String, release: Bool, rules: String, env: [String: String], status: String,
                    expect: (Rig.EngineRun) -> String?)] = [
            ("a", false,
             #"{"version":1,"rules":[{"id":"a","enabled":true,"target":"WindowServer","action":"restart","footprintAboveMB":1,"consecutiveSamples":1,"cooldownMinutes":1,"maxPerDay":1}]}"#,
             [:], "ok", { e in ruleInvalid(e, "a", error: nil) }),
            ("b", false,
             #"{"version":1,"rules":[{"id":"b","enabled":true,"target":"wallpaper","action":"quit","footprintAboveMB":1,"consecutiveSamples":1,"cooldownMinutes":1,"maxPerDay":1}]}"#,
             ["SWAPLESS_DRY_RUN": "1"], "ok", { e in ruleInvalid(e, "b", error: nil) }),
            ("c", false, #"{"version":1,"rules":[ this won't parse"#, [:], "invalid", { _ in nil }),
            ("d", false,
             #"{"version":1,"rules":[{"id":"d","enabled":false,"target":"wallpaper","action":"restart","footprintAboveMB":1,"consecutiveSamples":1,"cooldownMinutes":1,"maxPerDay":1}]}"#,
             ["SWAPLESS_DRY_RUN": "1"], "ok", { e in
                 let ds = e.child.events("decision").map(\.obj)
                 return ds.contains { ($0["ruleId"] as? String) == "d" && ($0["reason"] as? String) == "disabled" }
                     ? nil : "no decision 'disabled' for rule d (decisions: \(ds.map { $0["reason"] ?? "?" }))"
             }),
            ("e", true,
             #"{"version":1,"rules":[{"id":"e","enabled":true,"target":"rig-helper","action":"restart","footprintAboveMB":1,"consecutiveSamples":1,"cooldownMinutes":1,"maxPerDay":1}]}"#,
             ["SWAPLESS_RIG_HELPER_PATH": helperPath], "ok", { e in ruleInvalid(e, "e", error: "unknown target") }),
        ]
        for r in runs {
            do {
                let before = rig.wallpaperIdentities()
                let start = now()
                let dir = try rig.tempStateDir(rules: r.rules)
                let marker = "\(dir)/c3-\(r.name).marker"
                let helper = try rig.startHelper(name: "c3-\(r.name)-helper",
                                                 ["--start-mb", "480", "--hold-end", "20", "--marker", marker])
                guard helper.waitLine(timeout: 20, { _, l in l.contains("\"allocatedMB\":480") }) != nil else {
                    if helper.lines().contains(where: { $0.text.contains("\"refused\":true") }) {
                        return .fail("memory-floor: the c3-\(r.name) helper refused to allocate")
                    }
                    throw CheckFailure(why: "c3-\(r.name): helper never reached 480 MB")
                }
                var env = ["SWAPLESS_SAMPLE_INTERVAL": "1"]
                for (k, v) in r.env { env[k] = v }
                let engine = try rig.startEngine(name: "c3-\(r.name)-engine", release: r.release, stateDir: dir,
                                                 env: env, duration: 8 + 30,
                                                 expectDryRun: env["SWAPLESS_DRY_RUN"] == "1",
                                                 expectRulesStatus: r.status)
                Thread.sleep(forTimeInterval: 8)
                engine.child.stop()
                helper.waitExit(timeout: 60)
                let actions = engine.child.events("action").count
                let markerExists = FileManager.default.fileExists(atPath: marker)
                let wp = rig.wallpaperUnchanged(since: before, windowStart: start)
                var why: [String] = []
                if let e = r.expect(engine) { why.append(e) }
                if actions != 0 { why.append("\(actions) action events") }
                if markerExists { why.append("marker written") }
                if !helper.exitedOnItsOwn { why.append("helper did not exit on its own (exit \(helper.exitStatus))") }
                if !wp.ok { why.append(wp.note) }
                let samples = engine.child.events("sample").count
                notes.append("(\(r.name)) \(r.release ? "release" : "debug") · \(samples) samples · \(actions) actions · marker \(markerExists ? "yes" : "no") · helper exit \(helper.exitStatus) · \(wp.note)")
                if !why.isEmpty { problems.append("(\(r.name)) " + why.joined(separator: ", ")) }
            } catch let e as CheckFailure {
                problems.append("(\(r.name)) \(e.why)")
            } catch {
                problems.append("(\(r.name)) \(error)")
            }
            Children.shared.stopAll()
        }
        for n in notes { rig.report.line("  check 3: \(n)") }
        return problems.isEmpty ? .pass("no action without a rule in 6 runs") : .fail(problems.joined(separator: "; "))
    }

    static func ruleInvalid(_ e: Rig.EngineRun, _ id: String, error: String?) -> String? {
        let rules = (e.rules["rules"] as? [[String: Any]]) ?? []
        guard let r = rules.first(where: { ($0["id"] as? String) == id }) else { return "rule \(id) missing from the rules line" }
        if (r["valid"] as? Bool) != false { return "rule \(id) is valid" }
        if let error, (r["error"] as? String) != error {
            return "rule \(id) error '\(r["error"] as? String ?? "nil")', expected '\(error)'"
        }
        return nil
    }
}

/// Check 4 · ruled-action-once.
enum Check4 {
    /// 4b · persistence across a relaunch (v1-menu-today S5): a fresh debug engine on check 4's
    /// state dir, same rules and environment, reads the action back from `history.sqlite`.
    static func check4b(_ rig: Rig, dir: String) -> (note: String, problems: [String]) {
        do {
            let e = try rig.startEngine(name: "c4b-engine", stateDir: dir,
                                        env: ["SWAPLESS_SAMPLE_INTERVAL": "1",
                                              "SWAPLESS_RIG_HELPER_PATH": rig.helperPath],
                                        duration: 4, expectDryRun: false)
            defer { if e.child.isRunning { e.child.stop() } else { e.child.waitExit(timeout: 30) } }
            guard let a = e.child.waitEvent("activity", timeout: 10) else {
                return ("4b: no activity line", ["4b: TIMEOUT: no activity line within 10 s of the relaunch"])
            }
            let o = a.obj
            let total = o["total"] as? [String: Any]
            let days = (o["days"] as? [[String: Any]]) ?? []
            let restarts = JSONRead.int(total?["restarts"])
            let failed = JSONRead.int(total?["failed"])
            let freedNull = total?["freedMB"] is NSNull
            let recorded = (o["recorded"] as? Bool) == true
            let todayRunning = (days.first?["running"] as? Bool) == true
            let note = "4b (relaunch on check 4's state dir): recorded \(recorded), total.restarts \(restarts.map(String.init) ?? "nil"), failed \(failed.map(String.init) ?? "nil"), freedMB \(freedNull ? "null" : "\(total?["freedMB"] ?? "missing")"), \(days.count) days, today running \(todayRunning)"
            var why: [String] = []
            if !recorded { why.append("4b: recorded is not true (reason \(o["reason"] ?? "nil"))") }
            if restarts != 1 { why.append("4b: total.restarts \(restarts.map(String.init) ?? "nil"), expected 1") }
            if failed != 0 { why.append("4b: total.failed \(failed.map(String.init) ?? "nil"), expected 0") }
            if !freedNull { why.append("4b: total.freedMB is not null") }
            if days.count != 7 { why.append("4b: \(days.count) days, expected 7") }
            if !todayRunning { why.append("4b: days[0].running is not true") }
            return (note, why)
        } catch let e as CheckFailure {
            return ("4b: \(e.why)", ["4b: \(e.why)"])
        } catch {
            return ("4b: \(error)", ["4b: \(error)"])
        }
    }

    static func run(_ rig: Rig) -> Outcome {
        var notes: [String] = []
        var problems: [String] = []
        do {
            let dir = try rig.tempStateDir(rules: #"{"version":1,"rules":[{"id":"rig-helper-guard","enabled":true,"target":"rig-helper","action":"restart","footprintAboveMB":200,"consecutiveSamples":2,"cooldownMinutes":5,"maxPerDay":2}]}"#)
            let engine = try rig.startEngine(name: "c4-engine", stateDir: dir,
                                             env: ["SWAPLESS_SAMPLE_INTERVAL": "1",
                                                   "SWAPLESS_RIG_HELPER_PATH": rig.helperPath],
                                             duration: 150 + 30, expectDryRun: false)
            guard engine.child.waitEvent("sample", timeout: 60) != nil else { throw CheckFailure(why: "no first sample") }
            let aMarker = "\(dir)/a.marker"
            let bMarker = "\(dir)/b.marker"
            let a = try rig.startHelper(name: "c4-A", ["--start-mb", "32", "--hold-start", "2", "--grow-mb-per-s", "16",
                                                       "--max-mb", "300", "--hold-end", "60", "--marker", aMarker])
            // A is ended by the engine's SIGTERM (exit 143 with its marker).
            a.waitExit(timeout: 90)
            var markerSeen = false
            for _ in 0..<50 {
                if FileManager.default.fileExists(atPath: aMarker) {
                    markerSeen = true
                    break
                }
                usleep(100_000)
            }
            if !markerSeen { problems.append("a.marker never appeared (A exit \(a.exitStatus))") }
            let b = try rig.startHelper(name: "c4-B", ["--start-mb", "32", "--hold-start", "2", "--grow-mb-per-s", "16",
                                                       "--max-mb", "300", "--hold-end", "20", "--marker", bMarker])
            b.waitExit(timeout: 90)
            engine.child.stop()

            let actions = engine.child.events("action").map(\.obj)
            let outcomes = engine.child.events("actionOutcome").map(\.obj)
            notes.append("\(actions.count) action(s), \(outcomes.count) outcome(s); A exit \(a.exitStatus), B exit \(b.exitStatus)")
            if actions.count != 1 {
                problems.append("\(actions.count) action lines, expected exactly 1")
            }
            if let act = actions.first {
                let pids = (act["pids"] as? [Any])?.compactMap { JSONRead.int($0) } ?? []
                let id = JSONRead.int(act["actionId"])
                let t = JSONRead.double(act["t"]) ?? 0
                if pids != [Int(a.pid)] { problems.append("action pids \(pids), expected A's [\(a.pid)]") }
                if (act["outcome"] as? String) != "pending" { problems.append("action outcome \(act["outcome"] ?? "nil")") }
                let mine = outcomes.filter { JSONRead.int($0["actionId"]) == id }
                if mine.count != 1 || outcomes.count != 1 {
                    problems.append("\(mine.count) outcome lines for action \(id ?? -1) (\(outcomes.count) total)")
                }
                if let o = mine.first {
                    if (o["outcome"] as? String) != "signalled" { problems.append("outcome \(o["outcome"] ?? "nil"), expected signalled") }
                    for k in ["afterMB", "wsBeforeMB", "wsAfterMB"] where !(o[k] is NSNull) {
                        problems.append("\(k) is not null")
                    }
                }
                if let attrs = try? FileManager.default.attributesOfItem(atPath: aMarker),
                   let m = attrs[.modificationDate] as? Date {
                    let d = m.timeIntervalSince1970 - t
                    notes.append(String(format: "a.marker %.2f s after the action", d))
                    if d > 3 { problems.append(String(format: "a.marker %.2f s after the action (> 3 s)", d)) }
                }
            }
            // A decision `cooldown` no earlier than B's second sample above 200 MB.
            let samples = engine.child.events("sample").map(\.obj)
            let bAbove = samples.filter { s in
                (SampleView.footprint(SampleView.member(s, pid: b.pid)) ?? 0) > 200 * 1_048_576
            }.map(SampleView.t)
            let cooldowns = engine.child.events("decision").map(\.obj)
                .filter { ($0["reason"] as? String) == "cooldown" }.compactMap { JSONRead.double($0["t"]) }
            if bAbove.count < 2 {
                problems.append("B was above 200 MB in \(bAbove.count) samples")
            } else if !cooldowns.contains(where: { $0 >= bAbove[1] }) {
                problems.append("no decision cooldown at or after B's second sample above 200 MB")
            } else {
                notes.append("decision cooldown after B's second sample above 200 MB")
            }
            if FileManager.default.fileExists(atPath: bMarker) { problems.append("b.marker exists") }
            if !b.exitedOnItsOwn { problems.append("B did not exit 0 (exit \(b.exitStatus))") }

            // v1-menu-today: the engine's own last activity line, then 4b.
            if let last = engine.child.events("activity").last?.obj {
                let total = last["total"] as? [String: Any]
                let r = JSONRead.int(total?["restarts"])
                notes.append("check-4 engine's last activity line: total.restarts \(r.map(String.init) ?? "nil")")
                if r != 1 { problems.append("check-4 engine's last activity line: total.restarts \(r.map(String.init) ?? "nil"), expected 1") }
            } else {
                problems.append("the check-4 engine printed no activity line")
            }
            if engine.child.isRunning {
                problems.append("4b: the check-4 engine is still running; 4b not run")
            } else {
                let (note, why) = check4b(rig, dir: dir)
                notes.append(note)
                problems += why
            }
        } catch let e as CheckFailure {
            problems.append(e.why)
        } catch {
            problems.append("\(error)")
        }
        Children.shared.stopAll()

        // The dry run against the real wallpaper.
        let ext = rig.processes(atPath: RestartTarget.wallpaperExtensionPath)
        let agents = rig.processes(atPath: RestartTarget.wallpaperAgentPath)
        if ext.isEmpty {
            notes.append("wallpaper dry run: SKIP (WallpaperImageExtension not running)")
        } else {
            do {
                let before = rig.wallpaperIdentities()
                let expected = Set((ext + agents).map(\.pid))
                let dir = try rig.tempStateDir(rules: #"{"version":1,"rules":[{"id":"wallpaper-dry","enabled":true,"target":"wallpaper","action":"restart","footprintAboveMB":1,"consecutiveSamples":2,"cooldownMinutes":30,"maxPerDay":8}]}"#)
                let engine = try rig.startEngine(name: "c4-dry-engine", stateDir: dir,
                                                 env: ["SWAPLESS_SAMPLE_INTERVAL": "1", "SWAPLESS_DRY_RUN": "1"],
                                                 duration: 8 + 30, expectDryRun: true)
                Thread.sleep(forTimeInterval: 8)
                engine.child.stop()
                Thread.sleep(forTimeInterval: 5)
                let after = rig.wallpaperIdentities()
                let acts = engine.child.events("action").map(\.obj)
                let outs = engine.child.events("actionOutcome").count
                let pids = Set((acts.first?["pids"] as? [Any])?.compactMap { JSONRead.int($0) }.map(Int32.init) ?? [])
                notes.append("wallpaper dry run: \(acts.count) action(s), dryRun=\(acts.first?["dryRun"] ?? "nil"), outcome=\(acts.first?["outcome"] ?? "nil"), pids \(pids.sorted()) vs restart set \(expected.sorted()), \(outs) outcome line(s), identities \(before == after ? "unchanged" : "CHANGED") 5 s later")
                if acts.count != 1 { problems.append("dry run: \(acts.count) actions, expected 1") }
                if (acts.first?["dryRun"] as? Bool) != true || (acts.first?["outcome"] as? String) != "dry-run" {
                    problems.append("dry run: the action is not dryRun/dry-run")
                }
                if outs != 0 { problems.append("dry run: \(outs) actionOutcome lines") }
                if pids != expected { problems.append("dry run: pids \(pids.sorted()) ≠ restart set \(expected.sorted())") }
                if before != after { problems.append("dry run: wallpaper identities changed") }
            } catch let e as CheckFailure {
                problems.append("dry run: \(e.why)")
            } catch {
                problems.append("dry run: \(error)")
            }
        }
        for n in notes { rig.report.line("  check 4: \(n)") }
        return problems.isEmpty ? .pass(notes.joined(separator: " · ")) : .fail(problems.joined(separator: "; "))
    }
}
