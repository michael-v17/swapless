import Darwin
import Foundation
import SwaplessCore

/// What check 3 asserts on when it reuses check 2's run.
struct Check2Run {
    let engine: Child
    let helpers: [(name: String, child: Child, marker: String)]
    let wallpaperBefore: [ProcessIdentity]
    let startedAt: Double
}

/// Check 2 · growth-flagged.
enum Check2 {
    static func run(_ rig: Rig, evaluate: Bool) -> (Outcome, Check2Run?) {
        do {
            let r = try scenario(rig)
            guard evaluate else { return (.pass("scenario ran"), r.run) }
            return (judge(rig, r), r.run)
        } catch let e as CheckFailure {
            return (.fail(e.why), nil)
        } catch {
            return (.fail("\(error)"), nil)
        }
    }

    struct Result {
        let run: Check2Run
        let grower: Child
        let flat: Child
        let saw: Child
    }

    static func scenario(_ rig: Rig) throws -> Result {
        let wallpaperBefore = rig.wallpaperIdentities()
        let startedAt = now()
        let dir = try rig.tempStateDir()
        let det = rig.repoRoot + "/scripts/rig/detector-rig.json"
        let engine = try rig.startEngine(name: "c2-engine", stateDir: dir,
                                         env: ["SWAPLESS_SAMPLE_INTERVAL": "1",
                                               "SWAPLESS_DETECTOR_CONFIG": det],
                                         duration: 140 + 30, expectDryRun: false)
        guard engine.child.waitEvent("sample", timeout: 60) != nil else {
            engine.child.stop()
            throw CheckFailure(why: "no first sample")
        }
        let tmp = dir
        let g = try rig.startHelper(name: "c2-grower", [
            "--start-mb", "32", "--hold-start", "10", "--grow-mb-per-s", "8", "--max-mb", "480",
            "--hold-end", "60", "--marker", "\(tmp)/c2-grower.marker"])
        let f = try rig.startHelper(name: "c2-flat", [
            "--start-mb", "260", "--hold-end", "130", "--marker", "\(tmp)/c2-flat.marker"])
        let s = try rig.startHelper(name: "c2-sawtooth", [
            "--start-mb", "220", "--sawtooth", "220:320:3", "--hold-end", "130",
            "--marker", "\(tmp)/c2-sawtooth.marker"])
        // Every helper must exit on its own; the rig never signals them.
        for h in [g, f, s] { h.waitExit(timeout: 200) }
        engine.child.stop()
        let run = Check2Run(engine: engine.child,
                            helpers: [("grower", g, "\(tmp)/c2-grower.marker"),
                                      ("flat", f, "\(tmp)/c2-flat.marker"),
                                      ("sawtooth", s, "\(tmp)/c2-sawtooth.marker")],
                            wallpaperBefore: wallpaperBefore, startedAt: startedAt)
        return Result(run: run, grower: g, flat: f, saw: s)
    }

    static func helperLines(_ c: Child) -> [[String: Any]] {
        c.lines().compactMap { l in
            l.text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    static func judge(_ rig: Rig, _ r: Result) -> Outcome {
        for (name, c) in [("grower", r.grower), ("flat", r.flat), ("sawtooth", r.saw)] {
            if helperLines(c).contains(where: { ($0["refused"] as? Bool) == true }) {
                return .fail("memory-floor: the \(name) helper refused to allocate (kern.memorystatus_level < 30)")
            }
        }
        let flags = r.run.engine.events("flag").map(\.obj)
        func flagged(_ c: Child) -> [[String: Any]] {
            flags.filter { JSONRead.int($0["pid"]) == Int(c.pid) }
        }
        guard let cross = helperLines(r.grower).first(where: { (JSONRead.int($0["allocatedMB"]) ?? 0) >= 200 }),
              let crossT = JSONRead.double(cross["t"]) else {
            return .fail("the grower never reported ≥ 200 MB")
        }
        var problems: [String] = []
        var notes: [String] = []
        let gf = flagged(r.grower)
        if let first = gf.first, let t = JSONRead.double(first["t"]) {
            let delay = t - crossT
            let slope = JSONRead.double(first["slopeMBPerHour"]) ?? -1
            notes.append(String(format: "grower flagged %.1f s after crossing 200 MB, slope %.0f MB/h (reason %@)",
                                delay, slope, (first["reason"] as? String) ?? "?"))
            if delay > 20 { problems.append(String(format: "grower flagged %.1f s after crossing (> 20 s)", delay)) }
            if delay < 0 { problems.append(String(format: "grower flagged %.1f s before crossing 200 MB", -delay)) }
            if abs(slope - 28_800) > 0.25 * 28_800 { problems.append(String(format: "slope %.0f MB/h outside 28,800 ± 25 %%", slope)) }
        } else {
            problems.append("the grower was never flagged")
        }
        let ff = flagged(r.flat)
        let sf = flagged(r.saw)
        notes.append("flat flags \(ff.count) · sawtooth flags \(sf.count) · all flags \(flags.count)")
        if !ff.isEmpty { problems.append("the flat helper was flagged") }
        if !sf.isEmpty { problems.append("the sawtooth helper was flagged") }
        for n in notes { rig.report.line("  check 2: \(n)") }
        return problems.isEmpty ? .pass(notes.joined(separator: " · ")) : .fail(problems.joined(separator: "; "))
    }
}
