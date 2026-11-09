import AppKit
import ApplicationServices
import Darwin
import Foundation
import SwaplessCore

/// Check 9 · quit on last window close (spec v1-quit-on-close S6). The rig launches its own
/// LSUIElement test apps, every window off every display, and drives them through AX (the red-X
/// path) and their control FIFO (the ⌘W path). Engines run with the rig prefix seam, so nothing
/// of the owner's can be quit. Check 8 stays the on-screen menu walk; this is check 9.
enum Check9 {
    static let livePrefix = "com.michaelv.swapless.rig.window.live."
    static let dryPrefix = "com.michaelv.swapless.rig.window.dry."
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    /// No `NSPanel` scenario (owner, 2026-11-06): `panel-left` and `dialog-left` were dropped
    /// after a floating panel landed on a display; unit fixtures cover their subrole logic.
    static let liveScenarios = ["close-ax", "close-menu", "hide-on-close", "helpers", "two-windows", "swap",
                                "tabs", "refuse", "never-quit", "young", "windowless", "option-off"]
    /// Scenarios expected to end with an `ok` quit.
    static let okScenarios: Set<String> = ["close-ax", "close-menu", "hide-on-close", "helpers", "two-windows", "tabs"]

    // MARK: - Walls (preflight)

    /// No `forceTerminate` anywhere in Sources/, and exactly one `.terminate()` across
    /// Sources/Swapless and Sources/SwaplessCore, in QuitSender.swift. Comments are dropped first.
    static func walls(repoRoot: String) -> [String] {
        var problems: [String] = []
        var terminates: [String] = []
        // Built from parts so this file doesn't trip its own wall.
        let force = "force" + "Terminate"
        let fm = FileManager.default
        let root = repoRoot + "/Sources"
        guard let e = fm.enumerator(atPath: root) else { return ["can't read Sources/"] }
        for case let rel as String in e where rel.hasSuffix(".swift") {
            guard let text = try? String(contentsOfFile: root + "/" + rel, encoding: .utf8) else {
                problems.append("can't read Sources/\(rel)")
                continue
            }
            let code = stripComments(text)
            if code.contains(force) { problems.append("\(force) in Sources/\(rel)") }
            if rel.hasPrefix("Swapless/") || rel.hasPrefix("SwaplessCore/") {
                for (i, line) in code.components(separatedBy: "\n").enumerated() where line.contains(".terminate()") {
                    terminates.append("Sources/\(rel):\(i + 1)")
                }
            }
        }
        if terminates.count != 1 || !(terminates.first?.hasPrefix("Sources/Swapless/QuitSender.swift:") ?? false) {
            problems.append("expected exactly one .terminate() in Sources/Swapless/QuitSender.swift, found \(terminates)")
        }
        return problems
    }

    /// Drops `//` comments and `/* … */` blocks (string contents with `//` are rare enough here;
    /// a URL in a string would only drop code text, never add a match).
    static func stripComments(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        var inBlock = false
        var inLine = false
        while i < s.endIndex {
            let c = s[i]
            let next = s.index(after: i)
            let n: Character? = next < s.endIndex ? s[next] : nil
            if inBlock {
                if c == "*" && n == "/" { inBlock = false; i = s.index(after: next); continue }
                if c == "\n" { out.append(c) }
            } else if inLine {
                if c == "\n" { inLine = false; out.append(c) }
            } else if c == "/" && n == "/" {
                inLine = true
            } else if c == "/" && n == "*" {
                inBlock = true
                i = s.index(after: next)
                continue
            } else {
                out.append(c)
            }
            i = next
        }
        return out
    }

    // MARK: - Run

    static func run(_ rig: Rig) -> Outcome {
        let wallProblems = walls(repoRoot: rig.repoRoot)
        if !wallProblems.isEmpty { return .fail("walls: " + wallProblems.joined(separator: "; ")) }
        rig.report.line("  check 9: walls ok (no force quit anywhere; one .terminate() in QuitSender.swift)")
        let appsDir = rig.rigDir + "/window-apps"
        var apps: [String: TestApp] = [:]
        defer { cleanup(Array(apps.values), appsDir: appsDir, rig: rig) }
        do {
            return try runScenarios(rig, appsDir: appsDir, apps: &apps)
        } catch let e as CheckFailure {
            return .fail(e.why)
        } catch {
            return .fail("\(error)")
        }
    }

    static func runScenarios(_ rig: Rig, appsDir: String, apps: inout [String: TestApp]) throws -> Outcome {
        let binary = rig.releaseBin + "/swapless-window-app"
        guard FileManager.default.isExecutableFile(atPath: binary) else { throw CheckFailure(why: "no \(binary)") }
        try? FileManager.default.removeItem(atPath: appsDir)
        try FileManager.default.createDirectory(atPath: appsDir, withIntermediateDirectories: true)

        // State dirs: no restart rule at all (a release engine with the wallpaper seed could
        // restart the owner's real WallpaperAgent), the switch on.
        let liveRules = #"{"version":2,"rules":[],"quitOnLastWindow":{"enabled":true},"apps":[{"bundleId":"\#(livePrefix)never-quit","name":"rig never-quit","neverQuit":true}]}"#
        let dryRules = #"{"version":2,"rules":[],"quitOnLastWindow":{"enabled":true},"apps":[]}"#
        let liveDir = try rig.tempStateDir(rules: liveRules)
        let dryDir = try rig.tempStateDir(rules: dryRules)

        let live = try rig.startEngine(name: "c9-live", release: true, stateDir: liveDir,
                                       env: ["SWAPLESS_SAMPLE_INTERVAL": "2", "SWAPLESS_RIG_QUIT_BUNDLE_PREFIX": livePrefix],
                                       duration: 900, expectDryRun: false)
        let dry = try rig.startEngine(name: "c9-dry", release: true, stateDir: dryDir,
                                      env: ["SWAPLESS_SAMPLE_INTERVAL": "2", "SWAPLESS_RIG_QUIT_BUNDLE_PREFIX": dryPrefix,
                                            "SWAPLESS_DRY_RUN": "1"],
                                      duration: 900, expectDryRun: true)
        for e in [live, dry] {
            guard let st = e.child.waitEvent("quitStatus", timeout: 30, { ($0["tracked"] as? Int ?? 0) >= 1 }) else {
                let last = e.child.events("quitStatus").last?.obj
                if let last, (last["trusted"] as? Bool) == false {
                    throw CheckFailure(why: "\(e.child.name): trusted false: the terminal lacks Accessibility (the owner's step)")
                }
                throw CheckFailure(why: "\(e.child.name): no quitStatus with tracked ≥ 1 in 30 s (last: \(String(describing: last)))")
            }
            if (st.obj["trusted"] as? Bool) != true || (st.obj["available"] as? Bool) != true {
                throw CheckFailure(why: "\(e.child.name): quitStatus \(st.obj) (trusted and available must be true)")
            }
        }
        rig.report.line("  check 9: engines up, trusted and available (live tracks \(live.child.events("quitStatus").last?.obj["tracked"] ?? "?") apps, read-only)")

        // Bundles and launches.
        for s in liveScenarios {
            apps[s] = try TestApp.make(scenario: s, bundleId: livePrefix + s, binary: binary, dir: appsDir)
        }
        apps["dry-run"] = try TestApp.make(scenario: "dry-run", mode: "close-ax", bundleId: dryPrefix + "close-ax",
                                           binary: binary, dir: appsDir)
        for a in apps.values.sorted(by: { $0.scenario < $1.scenario }) { try a.launch() }
        for a in apps.values {
            guard spin(20, { a.event("ready") != nil }) else {
                Timeouts.shared.record("check 9: \(a.scenario) never wrote ready")
                throw CheckFailure(why: "\(a.scenario): not ready in 20 s")
            }
        }

        // Visibility gate.
        var seenWindows = Set<String>()
        func visibilityProblems() -> [String] {
            var out: [String] = []
            for a in apps.values {
                // The test app's own self-guard tripped (it already ordered its windows out).
                if let g = a.event("guard") { out.append("\(a.scenario): self-guard \(g["hits"] ?? "?")") }
                guard !a.terminated else { continue }
                for h in RigWindows.onScreen(pid: a.pid) { out.append("\(a.scenario): \(h)") }
                for e in a.events("windowOpened") { seenWindows.insert("\(a.scenario):\(e["id"] ?? "?")") }
            }
            return out
        }
        let onScreen = visibilityProblems()
        if !onScreen.isEmpty { throw CheckFailure(why: "test window on a display: \(onScreen)") }
        let visible = RigWindows.visibleSpaces()
        for a in apps.values where a.scenario != "windowless" {
            // A just-launched app may not be AX-ready yet (a half-built element with id 0 on a
            // loaded Mac): read again for up to 10 s. If it never settles, relaunch that app
            // once (owner, 2026-11-06); a second failure FAILs.
            var ids = (a.event("ready")?["windows"] as? [Int] ?? []).map(UInt32.init)
            var ax = RigWindows.axWindows(pid: a.pid)
            func settled() -> Bool {
                spin(10, {
                    ax = RigWindows.axWindows(pid: a.pid)
                    return ax.contains { ids.contains($0.id) && $0.subrole == "AXStandardWindow" }
                })
            }
            if !settled() {
                rig.report.line("  check 9: \(a.scenario) (pid \(a.pid)) AX list unreadable for 10 s (\(ax.map { "\($0.id) \($0.subrole ?? "-")" })); relaunching it once")
                try a.relaunch()
                if !visibilityProblems().isEmpty { throw CheckFailure(why: "test window on a display: \(visibilityProblems())") }
                ids = (a.event("ready")?["windows"] as? [Int] ?? []).map(UInt32.init)
                if !settled() { Timeouts.shared.record("check 9: \(a.scenario) AX list not ready in 10 s after a relaunch") }
            }
            let counted = ax.filter { ids.contains($0.id) && $0.subrole == "AXStandardWindow" }
            guard let w = counted.first else {
                throw CheckFailure(why: "\(a.scenario): no AXStandardWindow of \(ids) in its AX list (\(ax.map { "\($0.id) \($0.subrole ?? "-")" }))")
            }
            let sp = RigWindows.spaces(w.id)
            if sp.isEmpty || visible.isDisjoint(with: sp) {
                throw CheckFailure(why: "\(a.scenario): window \(w.id) not on a visible Space (spaces \(sp), visible \(visible.sorted()))")
            }
        }
        rig.report.line("  check 9: visibility gate ok (\(apps.count) apps, every window off every display, on visible Space \(visible.sorted()))")

        // Every app at least 11 s old (the young guard is 10 s) before anything is driven.
        let oldest = apps.values.map(\.launchedAt).max() ?? now()
        _ = spin(max(0, oldest + 11 - now()) + 0.5, { false }, recordTimeout: false)

        var results: [String: String] = [:]
        var problems: [String] = []
        func fail(_ s: String, _ why: String) {
            results[s] = "FAIL " + why
            problems.append("\(s): \(why)")
        }
        func pass(_ s: String, _ why: String) { results[s] = "PASS " + why }

        // Drive the first closes.
        var tClose: [String: Double] = [:]
        var fpBefore: [String: Double] = [:]
        for s in ["close-ax", "hide-on-close", "helpers", "two-windows", "swap", "tabs", "refuse", "never-quit",
                  "dry-run"] {
            guard let a = apps[s] else { continue }
            fpBefore[s] = RigWindows.footprintMB(pid: a.pid)
            let target: UInt32? = s == "tabs" ? RigWindows.axWindows(pid: a.pid).first { $0.subrole == "AXStandardWindow" }?.id
                : (a.event("ready")?["windows"] as? [Int])?.first.map(UInt32.init)
            if let err = RigWindows.pressClose(pid: a.pid, windowId: target) { fail(s, "AX close: \(err)") }
            tClose[s] = now()
        }
        if let a = apps["close-menu"] {
            fpBefore["close-menu"] = RigWindows.footprintMB(pid: a.pid)
            a.send("close 0")
            tClose["close-menu"] = now()
        }

        // 8 s later: the first close of two-windows and tabs left a window; then the second.
        _ = spin(8, { !visibilityProblems().isEmpty }, recordTimeout: false)
        if !visibilityProblems().isEmpty { throw CheckFailure(why: "test window on a display: \(visibilityProblems())") }
        for s in ["two-windows", "tabs"] {
            guard let a = apps[s] else { continue }
            if !actions(live, a.bundleId).isEmpty { fail(s, "quit after the first close (wrongful quit)") }
            let target: UInt32? = s == "tabs" ? RigWindows.axWindows(pid: a.pid).first { $0.subrole == "AXStandardWindow" }?.id
                : (a.event("ready")?["windows"] as? [Int]).flatMap { $0.count > 1 ? UInt32($0[1]) : nil }
            if let err = RigWindows.pressClose(pid: a.pid, windowId: target) { fail(s, "second AX close: \(err)") }
            tClose[s] = now()
        }

        // Outcomes of the ok scenarios (deadline 60 s each from their last close).
        for s in okScenarios.sorted() where results[s] == nil {
            guard let a = apps[s], let tc = tClose[s] else { continue }
            let got = spin(max(1, tc + 60 - now()), {
                guard let act = actions(live, a.bundleId).first else { return false }
                return outcome(live, act) != nil && a.terminated
            })
            guard got, let act = actions(live, a.bundleId).first else {
                Timeouts.shared.record("check 9: \(s) no ok quit within 60 s")
                let appEvents = a.events().compactMap { $0["event"] as? String }
                fail(s, "no quit within 60 s (decisions: \(decisions(live, a.pid).map { $0["reason"] ?? "?" }); app events \(appEvents); pid \(a.pid) terminated \(a.terminated))")
                continue
            }
            let out = outcome(live, act) ?? "none"
            let t = act["t"] as? Double ?? 0
            let delay = t - tc
            let before = act["beforeMB"] as? Double ?? 0
            var why: [String] = []
            if out != "ok" { why.append("outcome \(out)") }
            if s == "close-ax" || s == "close-menu" {
                if !(5.0...7.5).contains(delay) { why.append(String(format: "terminate %.2f s after the close (5.0–7.5)", delay)) }
                if let fp = fpBefore[s], fp > 0, abs(before - fp) > 0.15 * fp {
                    why.append(String(format: "before_mb %.1f vs footprint %.1f (±15 %%)", before, fp))
                }
                if before < 60 { why.append(String(format: "before_mb %.1f < 60", before)) }
            }
            let quits = actions(live, a.bundleId).count
            if quits != 1 { why.append("\(quits) quits") }
            if why.isEmpty {
                pass(s, String(format: "quit %.2f s after the close, outcome ok, before_mb %.1f (footprint %.1f)",
                               delay, before, fpBefore[s] ?? 0))
            } else {
                fail(s, why.joined(separator: ", "))
            }
        }

        // Scenarios that must not quit.
        func noQuit(_ s: String, reasons: Set<String>?, wait: Double) {
            guard let a = apps[s] else { return }
            let tc = tClose[s] ?? now()
            _ = spin(max(0, tc + wait - now()), { false }, recordTimeout: false)
            let acts = actions(live, a.bundleId)
            let ds = decisions(live, a.pid).compactMap { $0["reason"] as? String }
            if !acts.isEmpty { fail(s, "quit (wrongful): \(acts.count) action(s)"); return }
            if a.terminated { fail(s, "the app terminated"); return }
            if let reasons {
                if ds.isEmpty && !reasons.contains("") { fail(s, "no decision (expected \(reasons.sorted()))"); return }
                if let bad = ds.first(where: { !reasons.contains($0) }) { fail(s, "reason \(bad), expected \(reasons.sorted())"); return }
            } else if !ds.isEmpty {
                fail(s, "decisions \(ds), expected none")
                return
            }
            pass(s, "no quit; decisions \(ds)")
        }
        noQuit("swap", reasons: ["cancelled-window", "alive"], wait: 12)
        noQuit("never-quit", reasons: ["never-quit"], wait: 12)
        if let y = apps["young"] { tClose["young"] = y.launchedAt + 3 }
        noQuit("young", reasons: ["young"], wait: 20)
        if let w = apps["windowless"] { tClose["windowless"] = w.launchedAt }
        noQuit("windowless", reasons: nil, wait: 20)

        // Dry run (second engine).
        if let a = apps["dry-run"], let tc = tClose["dry-run"] {
            _ = spin(max(0, tc + 12 - now()), { false }, recordTimeout: false)
            let ds = decisions(dry, a.pid)
            let acts = actions(dry, a.bundleId)
            let liveActs = actions(live, a.bundleId)
            var why: [String] = []
            if a.terminated { why.append("the app terminated") }
            if !ds.contains(where: { ($0["verdict"] as? String) == "dry-run" && ($0["reason"] as? String) == "dry-run" }) {
                why.append("no dry-run decision (\(ds.map { $0["reason"] ?? "?" }))")
            }
            if acts.count != 1 || (acts.first?["dryRun"] as? Bool) != true { why.append("dry engine actions \(acts.count) (one dryRun row expected)") }
            if !liveActs.isEmpty { why.append("the live engine acted on the dry app") }
            let dq = (dry.child.events("activity").last?.obj["days"] as? [[String: Any]])?.first?["quits"] as? Int
            if dq != 0 { why.append("dry engine today quits \(dq.map(String.init) ?? "nil")") }
            if why.isEmpty { pass("dry-run", "no terminate, a dry-run row, Today quits 0") } else { fail("dry-run", why.joined(separator: ", ")) }
        }

        // Refuse: one terminate, refused at 30 s, left alone 15 s, re-armed by a new window.
        if let a = apps["refuse"], let tc = tClose["refuse"] {
            var why: [String] = []
            let firstDone = spin(max(1, tc + 50 - now()), {
                guard let act = actions(live, a.bundleId).first else { return false }
                return outcome(live, act) != nil
            })
            let first = actions(live, a.bundleId).first
            let out1 = first.flatMap { outcome(live, $0) }
            if !firstDone || first == nil { why.append("no first quit attempt with an outcome in 50 s") }
            if out1 != nil && out1 != "refused" { why.append("first outcome \(out1!)") }
            if a.terminated { why.append("the app terminated") }
            if why.isEmpty {
                _ = spin(15, { false }, recordTimeout: false)
                if actions(live, a.bundleId).count != 1 { why.append("a second terminate without a new window") }
                let opened = a.events("windowOpened").count
                a.send("open")
                if !spin(5, { a.events("windowOpened").count > opened }) { why.append("no window after open") }
                if !visibilityProblems().isEmpty { throw CheckFailure(why: "test window on a display: \(visibilityProblems())") }
                _ = spin(2, { false }, recordTimeout: false)
                let newId = (a.events("windowOpened").last?["id"] as? Int).map(UInt32.init)
                if let err = RigWindows.pressClose(pid: a.pid, windowId: newId) { why.append("AX close of the new window: \(err)") }
                let t2 = now()
                if !spin(12, { actions(live, a.bundleId).count >= 2 }) { why.append("no second terminate after the new window closed") }
                // Let its outcome land before the engine stops.
                if let second = actions(live, a.bundleId).dropFirst().first {
                    _ = spin(max(1, t2 + 45 - now()), { outcome(live, second) != nil })
                }
            }
            if why.isEmpty { pass("refuse", "refused at 30 s, left alone 15 s, re-armed by a new window (2 terminates)") } else { fail("refuse", why.joined(separator: ", ")) }
        }

        // Option off, last and alone: the rig rewrites its own rules.json.
        if let a = apps["option-off"] {
            let path = liveDir + "/rules.json"
            let off = liveRules.replacingOccurrences(of: #""enabled":true"#, with: #""enabled":false"#)
            try off.write(toFile: path + ".tmp", atomically: false, encoding: .utf8)
            rename(path + ".tmp", path)
            let from = live.child.lines().count
            if live.child.waitEvent("quitStatus", from: from, timeout: 10, { ($0["enabled"] as? Bool) == false }) == nil {
                Timeouts.shared.record("check 9: no quitStatus with enabled false within 10 s")
                fail("option-off", "no quitStatus enabled false")
            } else {
                let target = (a.event("ready")?["windows"] as? [Int])?.first.map(UInt32.init)
                if let err = RigWindows.pressClose(pid: a.pid, windowId: target) { fail("option-off", "AX close: \(err)") }
                tClose["option-off"] = now()
                noQuit("option-off", reasons: ["option-off", ""], wait: 15)
            }
        }

        // The table.
        for s in (liveScenarios + ["dry-run"]) {
            rig.report.line("  check 9 · \(s): \(results[s] ?? "not run")")
        }
        for s in liveScenarios + ["dry-run"] where results[s] == nil { problems.append("\(s): not run") }

        // Activity: today's quits and freed.
        let okActs = okScenarios.compactMap { apps[$0] }.flatMap { a in actions(live, a.bundleId).filter { outcome(live, $0) == "ok" } }
        let sumBefore = okActs.reduce(0.0) { $0 + ($1["beforeMB"] as? Double ?? 0) }
        _ = spin(6, { false }, recordTimeout: false)  // the next tick's activity line
        let today = (live.child.events("activity").last?.obj["days"] as? [[String: Any]])?.first
        let quitsToday = today?["quits"] as? Int ?? -1
        let freed = today?["freedMB"] as? Double ?? 0
        rig.report.line(String(format: "  check 9: activity today quits %d (ok quits %d), freedMB %.1f (sum before_mb %.1f)",
                               quitsToday, okActs.count, freed, sumBefore))
        if quitsToday != okActs.count { problems.append("activity: today quits \(quitsToday), expected \(okActs.count)") }
        if freed + 0.01 < sumBefore { problems.append(String(format: "activity: freedMB %.1f < %.1f", freed, sumBefore)) }

        // Scope: nothing outside the rig's own apps, in either engine.
        var scope: [String] = []
        for (e, prefix) in [(live, livePrefix), (dry, dryPrefix)] {
            for d in e.child.events("quitDecision").map(\.obj) where (d["verdict"] as? String) == "quit" {
                let b = d["bundleId"] as? String ?? ""
                if !b.hasPrefix(prefix) { scope.append("\(e.child.name) quit decision for \(b)") }
            }
            for act in e.child.events("action").map(\.obj) {
                let b = act["target"] as? String ?? ""
                if !b.hasPrefix(prefix) { scope.append("\(e.child.name) action on \(b)") }
            }
        }
        if !scope.isEmpty {
            problems.append("SCOPE (mandatory DECISIONS.md trigger: Swapless acted outside the rig's apps): \(scope)")
        }

        // cpuMs per decision.
        let cpus = (live.child.events("quitDecision") + dry.child.events("quitDecision"))
            .compactMap { $0.obj["cpuMs"] as? Double }.sorted()
        if !cpus.isEmpty {
            let p50 = cpus[cpus.count / 2]
            let p95 = cpus[min(cpus.count - 1, Int(Double(cpus.count) * 0.95))]
            let mx = cpus.last ?? 0
            rig.report.line(String(format: "  check 9: cpuMs over %d decisions: p50 %.1f · p95 %.1f · max %.1f (limit 150)", cpus.count, p50, p95, mx))
            if mx > 150 { problems.append(String(format: "cpuMs max %.1f > 150", mx)) }
        }

        // Stop the engines once no quit is pending, then a relaunch reads the quits back.
        _ = spin(40, {
            let open = live.child.events("action").filter { ($0.obj["dryRun"] as? Bool) == false }
                .filter { outcome(live, $0.obj) == nil }
            return open.isEmpty
        })
        live.child.stop(timeout: 50)
        dry.child.stop(timeout: 50)
        let relaunch = try rig.startEngine(name: "c9-relaunch", release: true, stateDir: liveDir,
                                           env: ["SWAPLESS_SAMPLE_INTERVAL": "2", "SWAPLESS_RIG_QUIT_BUNDLE_PREFIX": livePrefix],
                                           duration: 30, expectDryRun: false)
        if let act = relaunch.child.waitEvent("activity", timeout: 20) {
            let q = ((act.obj["days"] as? [[String: Any]])?.first?["quits"] as? Int) ?? -1
            rig.report.line("  check 9: relaunch reads today quits \(q)")
            if q != okActs.count { problems.append("relaunch: today quits \(q), expected \(okActs.count)") }
        } else {
            Timeouts.shared.record("check 9: relaunch gave no activity line in 20 s")
            problems.append("relaunch: no activity line")
        }
        relaunch.child.stop()

        if !visibilityProblems().isEmpty { problems.append("visibility: \(visibilityProblems())") }
        let summary = "\(results.values.filter { $0.hasPrefix("PASS") }.count) of \(liveScenarios.count + 1) scenarios pass, \(okActs.count) ok quits"
        return problems.isEmpty ? .pass(summary) : .fail(problems.joined(separator: "; "))
    }

    // MARK: - Engine lines

    static func actions(_ e: Rig.EngineRun, _ bundleId: String) -> [[String: Any]] {
        e.child.events("action").map(\.obj).filter {
            ($0["ruleId"] as? String) == QuitDisplay.ruleId && ($0["target"] as? String) == bundleId
        }
    }

    static func outcome(_ e: Rig.EngineRun, _ action: [String: Any]) -> String? {
        guard let id = action["actionId"] as? Int else { return nil }
        if (action["dryRun"] as? Bool) == true { return "dry-run" }
        return e.child.events("actionOutcome").map(\.obj).last { ($0["actionId"] as? Int) == id }?["outcome"] as? String
    }

    static func decisions(_ e: Rig.EngineRun, _ pid: Int32) -> [[String: Any]] {
        e.child.events("quitDecision").map(\.obj).filter { ($0["pid"] as? Int).map(Int32.init) == pid }
    }

    // MARK: - Waiting and cleanup

    /// Spins the main run loop (NSRunningApplication only updates while it runs) until `cond`
    /// or the deadline. A deadline that runs out is recorded as a TIMEOUT unless the wait is a
    /// plain pause (`recordTimeout: false`).
    @discardableResult
    static func spin(_ seconds: Double, _ cond: () -> Bool, recordTimeout: Bool = false) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            CFRunLoopRunInMode(.defaultMode, 0.05, false)
        }
        return cond()
    }

    static func cleanup(_ apps: [TestApp], appsDir: String, rig: Rig) {
        for a in apps where !a.terminated { a.send("exit") }
        _ = spin(5, { apps.allSatisfy(\.terminated) })
        for a in apps where !a.terminated {
            rig.report.line("  check 9: \(a.scenario) (pid \(a.pid)) still running after exit; SIGTERM")
            kill(a.pid, SIGTERM)
        }
        _ = spin(3, { apps.allSatisfy(\.terminated) })
        for a in apps { _ = rig.run(lsregister, ["-u", a.bundle], timeout: 30) }
        try? FileManager.default.removeItem(atPath: appsDir)
    }
}

/// One rig test app: its bundle, its status file and its control FIFO.
final class TestApp: @unchecked Sendable {
    let scenario: String
    let mode: String
    let bundleId: String
    let bundle: String
    let statusPath: String
    let ctlPath: String
    private(set) var app: NSRunningApplication?
    private(set) var launchedAt: Double = 0

    var pid: Int32 { app?.processIdentifier ?? -1 }
    /// `isTerminated`, or the pid gone from the process table (NSRunningApplication may not
    /// update in a process that runs no AppKit app; a probe, never a signal).
    var terminated: Bool {
        guard let app else { return true }
        if app.isTerminated { return true }
        return kill(app.processIdentifier, 0) != 0 && errno == ESRCH
    }

    private init(scenario: String, mode: String, bundleId: String, bundle: String, dir: String) {
        self.scenario = scenario
        self.mode = mode
        self.bundleId = bundleId
        self.bundle = bundle
        statusPath = "\(dir)/\(scenario).status.jsonl"
        ctlPath = "\(dir)/\(scenario).ctl"
    }

    /// `<dir>/<scenario>.app`: LSUIElement, the given bundle id, ad hoc signed.
    static func make(scenario: String, mode: String? = nil, bundleId: String, binary: String, dir: String) throws -> TestApp {
        let bundle = "\(dir)/\(scenario).app"
        let macos = bundle + "/Contents/MacOS"
        try FileManager.default.createDirectory(atPath: macos, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: binary, toPath: macos + "/swapless-window-app")
        let plist: [String: Any] = ["CFBundleIdentifier": bundleId, "CFBundleExecutable": "swapless-window-app",
                                    "CFBundleName": "rig \(scenario)", "CFBundlePackageType": "APPL", "LSUIElement": true]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: bundle + "/Contents/Info.plist"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-s", "-", "--force", bundle]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let a = TestApp(scenario: scenario, mode: mode ?? scenario, bundleId: bundleId, bundle: bundle, dir: dir)
        unlink(a.statusPath)
        unlink(a.ctlPath)
        guard mkfifo(a.ctlPath, 0o600) == 0 else { throw CheckFailure(why: "mkfifo \(a.ctlPath) failed") }
        return a
    }

    /// Never activates; a new instance; not in recent items.
    func launch() throws {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.createsNewApplicationInstance = true
        cfg.addsToRecentItems = false
        cfg.arguments = ["--mode", mode, "--ctl", ctlPath, "--status", statusPath]
        nonisolated(unsafe) var got: NSRunningApplication?
        nonisolated(unsafe) var err: Error?
        nonisolated(unsafe) var done = false
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: bundle), configuration: cfg) { a, e in
            got = a
            err = e
            done = true
        }
        guard Check9.spin(20, { done }), let got else {
            Timeouts.shared.record("check 9: launching \(scenario)")
            throw CheckFailure(why: "\(scenario): launch failed (\(String(describing: err)))")
        }
        app = got
        launchedAt = now()
    }

    /// Ends this instance (its own `exit`, then SIGTERM after 5 s) and launches a fresh one with
    /// an empty status file; waits for its `ready` (deadline 20 s).
    func relaunch() throws {
        if !terminated { send("exit") }
        if !Check9.spin(5, { self.terminated }), let p = app?.processIdentifier {
            kill(p, SIGTERM)
            _ = Check9.spin(3, { self.terminated })
        }
        unlink(statusPath)
        unlink(ctlPath)
        guard mkfifo(ctlPath, 0o600) == 0 else { throw CheckFailure(why: "mkfifo \(ctlPath) failed") }
        try launch()
        guard Check9.spin(20, { self.event("ready") != nil }) else {
            Timeouts.shared.record("check 9: \(scenario) never wrote ready after a relaunch")
            throw CheckFailure(why: "\(scenario): not ready in 20 s after a relaunch")
        }
    }

    func events(_ name: String? = nil) -> [[String: Any]] {
        guard let text = try? String(contentsOfFile: statusPath, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { l in
            guard let o = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any] else { return nil }
            if let name, (o["event"] as? String) != name { return nil }
            return o
        }
    }

    func event(_ name: String) -> [String: Any]? { events(name).first }

    func send(_ command: String) {
        let fd = open(ctlPath, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else { return }
        let line = command + "\n"
        _ = line.withCString { write(fd, $0, strlen($0)) }
        close(fd)
    }
}

/// The rig's own AX / CG / SkyLight helpers (read-only, except `pressClose`, which only ever
/// presses a close button whose pid is the given test app's).
enum RigWindows {
    typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    typealias SpacesFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    typealias ConnFn = @convention(c) () -> Int32
    typealias DisplaysFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    nonisolated(unsafe) static let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    static let getWindow = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")
        .map { unsafeBitCast($0, to: GetWindowFn.self) }
    static let spacesFn = sky.flatMap { dlsym($0, "CGSCopySpacesForWindows") }.map { unsafeBitCast($0, to: SpacesFn.self) }
    static let connFn = sky.flatMap { dlsym($0, "CGSMainConnectionID") }.map { unsafeBitCast($0, to: ConnFn.self) }
    static let displaysFn = sky.flatMap { dlsym($0, "CGSCopyManagedDisplaySpaces") }.map { unsafeBitCast($0, to: DisplaysFn.self) }

    struct Win {
        let element: AXUIElement
        let id: UInt32
        let subrole: String?
    }

    static func axWindows(pid: Int32) -> [Win] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success,
              let ws = v as? [AXUIElement] else { return [] }
        return ws.map { w in
            var id: CGWindowID = 0
            _ = getWindow?(w, &id)
            var s: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &s)
            return Win(element: w, id: id, subrole: s as? String)
        }
    }

    /// nil on success, else why not. Only presses a close button owned by `pid`.
    static func pressClose(pid: Int32, windowId: UInt32?) -> String? {
        guard pid > 0 else { return "no pid" }
        let ws = axWindows(pid: pid)
        guard let w = (windowId.flatMap { id in ws.first { $0.id == id } }) ?? (windowId == nil ? ws.first : nil) else {
            return "window \(windowId.map(String.init) ?? "?") not in AX (\(ws.map(\.id)))"
        }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w.element, kAXCloseButtonAttribute as CFString, &v) == .success,
              let close = v, CFGetTypeID(close) == AXUIElementGetTypeID() else { return "no close button" }
        let button = close as! AXUIElement
        var owner: pid_t = 0
        guard AXUIElementGetPid(button, &owner) == .success, owner == pid else { return "close button pid \(owner) ≠ \(pid)" }
        let r = AXUIElementPerformAction(button, kAXPressAction as CFString)
        return r == .success ? nil : "AXPress \(r.rawValue)"
    }

    static func spaces(_ id: UInt32) -> Set<UInt64> {
        guard let spacesFn, let connFn,
              let arr = spacesFn(connFn(), 7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return Set(arr.map(\.uint64Value))
    }

    static func visibleSpaces() -> Set<UInt64> {
        guard let displaysFn, let connFn,
              let arr = displaysFn(connFn())?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return Set(arr.compactMap { ((($0["Current Space"] as? [String: Any])?["ManagedSpaceID"]) as? NSNumber)?.uint64Value })
    }

    /// Windows of `pid` whose bounds intersect an active display.
    static func onScreen(pid: Int32) -> [String] {
        guard pid > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        let displays = ids.prefix(Int(n)).map { CGDisplayBounds($0) }
        let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var hits: [String] = []
        for d in all where (d[kCGWindowOwnerPID as String] as? Int32) == pid {
            guard let b = d[kCGWindowBounds as String] as? [String: Double] else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if r.width > 0, r.height > 0, displays.contains(where: { $0.intersects(r) }) {
                hits.append("window \(d[kCGWindowNumber as String] ?? "?") at \(r)")
            }
        }
        return hits
    }

    /// `ri_phys_footprint` of a test app (same uid), in MiB.
    static func footprintMB(pid: Int32) -> Double {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return r == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : 0
    }
}
