import CSwaplessProc
import Darwin
import Foundation
import SwaplessCore

/// Check 7 · live-wallpaper (`--live-wallpaper`; owner call 7; one invocation per
/// implementation run, and a precondition SKIP counts as that invocation).
enum Check7 {
    static let portalPath = "/Applications/Portal.app/Contents/MacOS/Portal"

    static func run(_ rig: Rig) -> Outcome {
        // Precondition: Portal running, the extension ≥ 400 MB.
        let portal = rig.processes(atPath: portalPath)
        let ext = rig.processes(atPath: RestartTarget.wallpaperExtensionPath)
        var c: UInt64 = 0
        for e in ext {
            var ru = sw_rusage_t()
            if sw_pid_rusage(e.pid, &ru) == 0 { c += ru.phys_footprint }
        }
        let cMB = Double(c) / MiB
        guard !portal.isEmpty, !ext.isEmpty, cMB >= 400 else {
            return .skip(String(format: "precondition: Portal running=%@, WallpaperImageExtension instances=%d, footprint %.1f MB (needs ≥ 400 MB)",
                                portal.isEmpty ? "no" : "yes", ext.count, cMB))
        }
        let portalBefore = portal.map(\.identity)
        let threshold = Int(cMB.rounded(.down)) - 100
        let before = rig.wallpaperIdentities()
        let agentsBefore = Set(rig.processes(atPath: RestartTarget.wallpaperAgentPath).map(\.identity))
        let extBefore = Set(ext.map(\.identity))
        rig.report.line(String(format: "  check 7: Portal pid %d, extension C = %.1f MB → rule footprintAboveMB %d; release engine, not a dry run",
                               portal[0].pid, cMB, threshold))
        let runStart = now()
        var problems: [String] = []
        var notes: [String] = []
        do {
            let dir = try rig.tempStateDir(rules: "{\"version\":1,\"rules\":[{\"id\":\"wallpaper-live-check\",\"enabled\":true,\"target\":\"wallpaper\",\"action\":\"restart\",\"footprintAboveMB\":\(threshold),\"consecutiveSamples\":2,\"cooldownMinutes\":30,\"maxPerDay\":8}]}")
            let engine = try rig.startEngine(name: "c7-engine", release: true, stateDir: dir,
                                             env: ["SWAPLESS_SAMPLE_INTERVAL": "2"], duration: 300,
                                             expectDryRun: false)
            // Watch for the action, then observe the respawn independently.
            guard let act = engine.child.waitEvent("action", timeout: 120) else {
                engine.child.stop()
                let ds = engine.child.events("decision").map { $0.obj["reason"] as? String ?? "?" }
                throw CheckFailure(why: "no action within 120 s (decisions \(ds))")
            }
            let actT = act.obj["t"] as? Double ?? now()
            var agentBack: Double?
            var extBack: Double?
            let watchStart = now()
            while now() - watchStart < 130 && (agentBack == nil || extBack == nil) {
                let agents = rig.processes(atPath: RestartTarget.wallpaperAgentPath).map(\.identity)
                let exts = rig.processes(atPath: RestartTarget.wallpaperExtensionPath).map(\.identity)
                if agentBack == nil, agents.contains(where: { !agentsBefore.contains($0) }) { agentBack = now() - actT }
                if extBack == nil, exts.contains(where: { !extBefore.contains($0) }) { extBack = now() - actT }
                usleep(500_000)
            }
            // Never stop this engine before its actionOutcome line.
            guard let outcome = engine.child.waitEvent("actionOutcome", from: act.index + 1, timeout: 200) else {
                let exited = !engine.child.isRunning
                engine.child.stop()
                throw CheckFailure(why: exited ? "verify-cut: the engine exited with an action and no actionOutcome"
                                                : "no actionOutcome within 200 s of the action")
            }
            engine.child.stop()
            let actions = engine.child.events("action")
            let o = outcome.obj
            let beforeMB = JSONRead.double(act.obj["beforeMB"]) ?? 0
            let afterMB = JSONRead.double(o["afterMB"])
            let wsB = JSONRead.double(o["wsBeforeMB"])
            let wsA = JSONRead.double(o["wsAfterMB"])
            notes.append(String(format: "action pids %@ beforeMB %.1f → outcome %@ afterMB %@ · WindowServer %@ → %@ MB · agent back %@ s, extension back %@ s",
                                "[" + ((act.obj["pids"] as? [Any]) ?? []).compactMap { JSONRead.int($0) }.map(String.init).joined(separator: ", ") + "]", beforeMB, (o["outcome"] as? String) ?? "?",
                                afterMB.map { String(format: "%.1f", $0) } ?? "null",
                                wsB.map { String(format: "%.1f", $0) } ?? "null",
                                wsA.map { String(format: "%.1f", $0) } ?? "null",
                                agentBack.map { String(format: "%.1f", $0) } ?? "never",
                                extBack.map { String(format: "%.1f", $0) } ?? "never"))
            if actions.count != 1 { problems.append("\(actions.count) actions, expected exactly 1") }
            if (o["outcome"] as? String) != "ok" { problems.append("outcome \(o["outcome"] ?? "nil"), expected ok") }
            if let afterMB, afterMB >= beforeMB { problems.append("after \(afterMB) MB ≥ before \(beforeMB) MB") }
            if afterMB == nil { problems.append("afterMB is null") }
            if agentBack == nil || agentBack! > 30 { problems.append("WallpaperAgent not back with a new identity within 30 s") }
            if extBack == nil || extBack! > 120 { problems.append("WallpaperImageExtension not back within 120 s") }
            if wsB == nil || wsA == nil { problems.append("wsBeforeMB / wsAfterMB not reported") }
        } catch let e as CheckFailure {
            problems.append(e.why)
        } catch {
            problems.append("\(error)")
        }
        // Portal's pid unchanged and still running.
        let portalAfter = rig.processes(atPath: portalPath).map(\.identity)
        if portalAfter != portalBefore {
            problems.append("Portal changed: before \(portalBefore.map(\.pid)) after \(portalAfter.map(\.pid))")
        } else {
            notes.append("Portal pid \(portalBefore.first?.pid ?? -1) unchanged and running")
        }
        notes.append("wallpaper identities before \(before.map(\.pid)) after \(rig.wallpaperIdentities().map(\.pid))")

        // Right after the run: the engine's log, for the proof.
        let log = rig.run("/usr/bin/log", ["show", "--start", logStamp(runStart - 1), "--predicate",
                                           "subsystem == \"com.michaelv.swapless\""])
        let proof = rig.repoRoot + "/docs/proof/v1-core/check7-log.txt"
        let text = log.out.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        try? text.write(toFile: proof, atomically: true, encoding: .utf8)
        notes.append("log saved to docs/proof/v1-core/check7-log.txt")
        for n in notes { rig.report.line("  check 7: \(n)") }
        return problems.isEmpty ? .pass(notes.first ?? "ok") : .fail(problems.joined(separator: "; "))
    }
}
