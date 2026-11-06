import Darwin
import Foundation
import SwaplessCore

enum Preflight {
    static func run(_ rig: Rig) -> Outcome? {
        var free = rig.freePct()
        let deadline = now() + 600
        while free < 40 {
            if now() >= deadline { return .fail("mac-too-busy (free \(free) % after 10 min of polling)") }
            rig.report.line("preflight: free \(free) % < 40; polling again in 30 s")
            sleep(30)
            free = rig.freePct()
        }
        rig.wallpaperBaseline = rig.wallpaperIdentities()
        let ids = rig.wallpaperBaseline.map { "\($0.pid)@\(String(format: "%.6f", $0.startTime))" }
        return .pass("free \(free) % · wallpaper baseline [\(ids.joined(separator: ", "))]")
    }
}

/// Check 1 · footprint-matches-top.
enum Check1 {
    static func run(_ rig: Rig) -> Outcome {
        var notes: [String] = []
        var fails: [String] = []
        for forceTop in [false, true] {
            let tag = forceTop ? "top-mode" : "coalition-mode"
            do {
                let r = try one(rig, forceTop: forceTop)
                notes.append("[\(tag)] " + r.notes.joined(separator: " · "))
                fails += r.fails.map { "[\(tag)] \($0)" }
                for n in r.notes { rig.report.line("  check 1 [\(tag)] \(n)") }
                for f in r.fails { rig.report.line("  check 1 [\(tag)] FAIL \(f)") }
            } catch let e as CheckFailure {
                fails.append("[\(tag)] \(e.why)")
                rig.report.line("  check 1 [\(tag)] FAIL \(e.why)")
            } catch {
                fails.append("[\(tag)] \(error)")
            }
            Children.shared.stopAll()
        }
        if fails.isEmpty { return .pass("both runs matched top") }
        return .fail(fails.joined(separator: "; "))
    }

    struct RunResult {
        var notes: [String] = []
        var fails: [String] = []
    }

    static func one(_ rig: Rig, forceTop: Bool) throws -> RunResult {
        var res = RunResult()
        let name = forceTop ? "c1-top" : "c1"
        let helper = try rig.startHelper(name: "\(name)-helper", ["--start-mb", "256", "--hold-end", "60"])
        guard helper.waitLine(timeout: 20, { _, l in l.contains("\"allocatedMB\":256") }) != nil else {
            throw CheckFailure(why: "helper never reached 256 MiB")
        }
        let dir = try rig.tempStateDir()
        var env = ["SWAPLESS_SAMPLE_INTERVAL": "2"]
        if forceTop { env["SWAPLESS_FORCE_TOP"] = "1" }
        let engine = try rig.startEngine(name: "\(name)-engine", stateDir: dir, env: env,
                                         duration: 60 + 30, expectDryRun: false)
        defer { engine.child.stop() }

        if forceTop {
            let src = engine.start["source"] as? String
            let sc = (engine.start["selfCheck"] as? [String: Any])?["coalition"] as? String
            if src != "top" { res.fails.append("source=\(src ?? "nil"), expected top") }
            if sc != "skipped" { res.fails.append("selfCheck.coalition=\(sc ?? "nil"), expected skipped") }
        } else {
            let src = engine.start["source"] as? String
            let sc = engine.start["selfCheck"] as? [String: Any]
            res.notes.append("source=\(src ?? "nil") selfCheck=\(sc?["coalition"] ?? "nil") checked=\(sc?["checked"] ?? "nil") passed=\(sc?["passed"] ?? "nil") windowServer=\(sc?["windowServer"] ?? "nil")")
            if src != "coalition" {
                res.fails.append("source=\(src ?? "nil"): the coalition self-check did not pass (Brakes: stop and report)")
            }
        }

        // The first sample, then the rig's own top.
        guard let first = engine.child.waitEvent("sample", timeout: 60) else {
            throw CheckFailure(why: "no first sample")
        }
        let top = try rig.top()
        guard let after = engine.child.waitEvent("sample", from: first.index + 1, timeout: 30, {
            SampleView.t($0) > top.t1
        }) else {
            throw CheckFailure(why: "no sample after T1")
        }
        let fpTool = rig.footprintTool(pid: helper.pid)
        let samples = engine.child.events("sample").map(\.obj)
        guard let before = samples.last(where: { SampleView.t($0) < top.t0 }) else {
            throw CheckFailure(why: "no sample before T0")
        }
        let a = after.obj
        res.notes.append(String(format: "T0=%.3f T1=%.3f before.t=%.3f after.t=%.3f", top.t0, top.t1,
                                SampleView.t(before), SampleView.t(a)))

        // The helper: tol 1 MB, plus footprint(1)'s phys_footprint vs the after sample.
        let hb = SampleView.footprint(SampleView.member(before, pid: helper.pid))
        let ha = SampleView.footprint(SampleView.member(a, pid: helper.pid))
        if let hb, let ha, let ht = top.values[helper.pid] {
            let ok = inRange(Double(ht), Double(hb), Double(ha), tol: MiB)
            res.notes.append("helper top=\(mb(ht)) engine=\(mb(hb))/\(mb(ha)) \(ok ? "ok" : "MISMATCH")")
            if !ok { res.fails.append("helper: top \(mb(ht)) outside [\(mb(hb)), \(mb(ha))] ± 1 MiB") }
        } else {
            res.fails.append("helper missing (engine before=\(hb.map(mb) ?? "nil") after=\(ha.map(mb) ?? "nil") top=\(top.values[helper.pid].map(mb) ?? "nil"))")
        }
        if let fpTool, let ha {
            let d = abs(Double(fpTool.phys) - Double(ha))
            res.notes.append("helper footprint(1)=\(mb(fpTool.phys)) vs after \(mb(ha)) Δ=\(mb(d))")
            if d > MiB { res.fails.append("helper: footprint(1) \(mb(fpTool.phys)) vs after \(mb(ha)) > 1 MiB") }
        } else {
            res.fails.append("footprint(1) on the helper failed")
        }

        // WallpaperImageExtension (if running): tol 2 MB.
        let wie = SampleView.members(a).filter { ($0["path"] as? String) == RestartTarget.wallpaperExtensionPath }
        if wie.isEmpty {
            res.notes.append("WallpaperImageExtension not running")
        }
        for m in wie {
            let pid = Int32(JSONRead.int(m["pid"]) ?? -1)
            let b = SampleView.footprint(SampleView.member(before, pid: pid))
            let af = SampleView.footprint(m)
            guard let b, let af, let t = top.values[pid] else {
                res.fails.append("WallpaperImageExtension \(pid): missing value")
                continue
            }
            let ok = inRange(Double(t), Double(b), Double(af), tol: 2 * MiB)
            res.notes.append("WallpaperImageExtension top=\(mb(t)) engine=\(mb(b))/\(mb(af)) \(ok ? "ok" : "MISMATCH")")
            if !ok { res.fails.append("WallpaperImageExtension: top \(mb(t)) outside engine ± 2 MiB") }
        }

        // WindowServer's group vs Σ top MEM over its members.
        let wsPid = SampleView.members(a).first { (($0["path"] as? String) ?? "").hasSuffix("/WindowServer") }
            .flatMap { JSONRead.int($0["pid"]) }.map(Int32.init)
        if let wsPid, let ga = SampleView.group(a, containing: wsPid), let gb = SampleView.group(before, containing: wsPid) {
            let pids = ((ga["members"] as? [[String: Any]]) ?? []).compactMap { JSONRead.int($0["pid"]) }.map(Int32.init)
            let topSum = pids.reduce(UInt64(0)) { $0 + (top.values[$1] ?? 0) }
            let fa = JSONRead.uint64(ga["footprint"])
            let fb = JSONRead.uint64(gb["footprint"])
            if let fa, let fb {
                let tol = Double(pids.count) * MiB + 0.01 * Double(topSum)
                let ok = inRange(Double(topSum), Double(fb), Double(fa), tol: tol)
                res.notes.append("WindowServer group (\(pids.count) members) Σtop=\(mb(topSum)) engine=\(mb(fb))/\(mb(fa)) tol=\(mb(tol)) \(ok ? "ok" : "MISMATCH")")
                if !ok { res.fails.append("WindowServer group: Σtop \(mb(topSum)) outside engine ± \(mb(tol))") }
            } else {
                res.fails.append("WindowServer group footprint is null")
            }
        } else {
            res.fails.append("WindowServer group not found")
        }

        // Broad: ≥ 95 % of same-user processes ≥ 50 MB in both, tol max(2 MB, 2 %).
        var total = 0
        var good = 0
        var worst: [String] = []
        for m in SampleView.members(a) where (m["readable"] as? Bool) == true {
            let pid = Int32(JSONRead.int(m["pid"]) ?? -1)
            guard let af = SampleView.footprint(m), let t = top.values[pid] else { continue }
            guard Double(af) >= 50 * MiB, Double(t) >= 50 * MiB else { continue }
            let bm = SampleView.member(before, pid: pid)
            let sameStart = bm.map { JSONRead.double($0["startTime"]) == JSONRead.double(m["startTime"]) } ?? false
            let b = sameStart ? (SampleView.footprint(bm) ?? af) : af
            total += 1
            let tol = max(2 * MiB, 0.02 * Double(t))
            if inRange(Double(t), Double(b), Double(af), tol: tol) {
                good += 1
            } else if worst.count < 5 {
                worst.append("\(m["name"] ?? "?")(\(pid)) top=\(mb(t)) engine=\(mb(b))/\(mb(af))")
            }
        }
        let frac = total > 0 ? Double(good) / Double(total) : 0
        res.notes.append(String(format: "broad %d/%d same-user ≥ 50 MB within tol (%.1f %%)", good, total, frac * 100)
                         + (worst.isEmpty ? "" : " outliers: " + worst.joined(separator: ", ")))
        if total == 0 || frac < 0.95 { res.fails.append("broad: \(good)/\(total) < 95 %") }

        // Coverage: every pid top listed is in the after sample, gone, or a new process.
        let memberPids = Set(SampleView.members(a).compactMap { JSONRead.int($0["pid"]) }.map(Int32.init))
        let excluded = Children.shared.pids.union([top.pid])
        var missing: [String] = []
        var goneOrNew = 0
        for pid in top.values.keys where !memberPids.contains(pid) && !excluded.contains(pid) {
            if let e = ProcessTable.entry(pid: pid) {
                if e.identity.startTime >= top.t0 {
                    goneOrNew += 1
                } else {
                    missing.append("\(pid)(\(e.comm))")
                }
            } else {
                goneOrNew += 1
            }
        }
        res.notes.append("coverage: top \(top.values.count) pids, sample \(memberPids.count) members, \(goneOrNew) gone/new, \(missing.count) missing")
        if !missing.isEmpty { res.fails.append("coverage: missing \(missing.prefix(10).joined(separator: ", "))") }

        helper.stop()
        return res
    }
}
