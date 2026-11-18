import Darwin
import Foundation
import SwaplessCore

/// Check 6 · simulator (`--sim`; one boot per implementation run, owner call 7).
enum Check6 {
    static let deviceName = "iPhone 18 Pro"

    struct Device {
        let udid: String
        let name: String
        let state: String
    }

    static func devices(_ rig: Rig) -> [Device] {
        let r = rig.run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"])
        guard r.status == 0, let data = r.out.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devs = root["devices"] as? [String: [[String: Any]]] else { return [] }
        var out: [Device] = []
        for (_, list) in devs {
            for d in list {
                guard let u = d["udid"] as? String, let n = d["name"] as? String else { continue }
                if (d["isAvailable"] as? Bool) == false { continue }
                out.append(Device(udid: u, name: n, state: (d["state"] as? String) ?? "?"))
            }
        }
        return out
    }

    static func isBooted(_ rig: Rig, _ udid: String) -> Bool {
        let r = rig.run("/usr/bin/xcrun", ["simctl", "list", "devices", "booted"])
        return r.out.contains(udid)
    }

    static func run(_ rig: Rig, parentPid: Int32?) -> Outcome {
        let marker = rig.rigDir + "/booted-sim"
        if FileManager.default.fileExists(atPath: marker) {
            let contents = (try? String(contentsOfFile: marker, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
            let udid = contents.split(separator: " ").first.map(String.init) ?? ""
            let state = devices(rig).first { $0.udid == udid }?.state ?? "unknown"
            return .fail("stale-booted-sim: .build/rig/booted-sim = '\(contents)', device state \(state) (Brakes: stop and report; the file is left in place)")
        }

        // The engine starts before any boot.
        let dir: String
        let engine: Rig.EngineRun
        do {
            dir = try rig.tempStateDir()
            engine = try rig.startEngine(name: "c6-engine", stateDir: dir,
                                         env: ["SWAPLESS_SAMPLE_INTERVAL": "2"], duration: 450,
                                         expectDryRun: false)
        } catch let e as CheckFailure {
            return .fail(e.why)
        } catch {
            return .fail("\(error)")
        }
        defer { engine.child.stop() }
        guard let first = engine.child.waitEvent("sample", timeout: 60) else {
            return .fail("no first sample")
        }

        let all = devices(rig)
        let alreadyBooted = all.filter { $0.state == "Booted" }.sorted { $0.udid < $1.udid }
        var bootedByRig = false
        let device: Device
        var bootedAt: Double
        if let d = alreadyBooted.first {
            device = d
            bootedAt = SampleView.t(first.obj)
            rig.report.line("  check 6: using the already-booted \(d.name) (\(d.udid)); booting nothing")
        } else {
            guard let d = all.first(where: { $0.name == deviceName }) else {
                return .skip("no '\(deviceName)' device in simctl list")
            }
            device = d
            rig.report.line("  check 6: booting \(d.name) (\(d.udid)); it will be shut down afterwards")
            let record = "\(d.udid) \(parentPid ?? getpid())\n"
            do {
                try record.write(toFile: marker, atomically: true, encoding: .utf8)
            } catch {
                return .fail("can't write \(marker)")
            }
            bootedByRig = true
            extraCleanup.append { shutdown(rig, udid: d.udid, marker: marker) }
            _ = rig.run("/usr/bin/xcrun", ["simctl", "boot", d.udid])
            let status = Child(name: "c6-bootstatus", executable: "/usr/bin/xcrun",
                               arguments: ["simctl", "bootstatus", d.udid, "-b"], environment: rig.baseEnv())
            do { try status.start() } catch { return finish(rig, .fail("bootstatus failed to start"), device: d, bootedByRig: true, marker: marker) }
            if !status.waitExit(timeout: 300) {
                status.stop()
                return finish(rig, .fail("not booted within 300 s"), device: d, bootedByRig: true, marker: marker)
            }
            bootedAt = now()
            rig.report.line(String(format: "  check 6: booted at %.3f (bootstatus exit %d)", bootedAt, status.exitStatus))
        }

        let deviceLabel = SimulatorResolver.deviceName(udid: device.udid, home: NSHomeDirectory()).map { "Simulator · \($0)" }
            ?? "Simulator (unknown device)"

        // The fixture, while the device is booted, whatever the outcome.
        if let fdir = try? rig.tempStateDir() {
            var env = rig.baseEnv()
            env["SWAPLESS_STATE_DIR"] = fdir
            let p = Process()
            p.executableURL = URL(fileURLWithPath: rig.debugEngine)
            // A raw snapshot lists every process on this Mac, so it goes to the gitignored .build/rig/,
            // never straight into the tracked fixture. scripts/trim-snapshot.py makes the fixture from it.
            p.arguments = ["--dump-snapshot", rig.repoRoot + "/.build/rig/sim-booted.json"]
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil {
                Children.shared.addPid(p.processIdentifier)
                let deadline = now() + 60
                while p.isRunning, now() < deadline { usleep(50_000) }
                if p.isRunning {
                    Timeouts.shared.record("--dump-snapshot (pid \(p.processIdentifier)) still running after 60 s")
                } else {
                    rig.report.line("  check 6: raw snapshot .build/rig/sim-booted.json written (exit \(p.terminationStatus)); to refresh the fixture: python3 -I scripts/trim-snapshot.py .build/rig/sim-booted.json Tests/SwaplessCoreTests/Fixtures/sim-booted.json")
                }
            }
        }

        // Steady: 6 consecutive samples (10 s) within ±5 % of their mean, within 120 s of Booted.
        var series: [(t: Double, mb: Double)] = []
        var from = first.index
        var outcome: Outcome = .fail("not-steady")
        let deadline = bootedAt + 120
        while true {
            let remaining = max(1, deadline - now() + 5)
            guard let s = engine.child.waitEvent("sample", from: from, timeout: remaining) else { break }
            from = s.index + 1
            let t = SampleView.t(s.obj)
            if t < bootedAt { continue }
            let groups = SampleView.groups(s.obj)
            let simGroups = groups.filter { ($0["kind"] as? String) == "simulator" }
            let g = simGroups.first { ($0["label"] as? String) == deviceLabel }
            let fp = g.flatMap { JSONRead.uint64($0["footprint"]) }.map { Double($0) / MiB }
            series.append((t, fp ?? 0))
            if series.count >= 6 {
                let last = series.suffix(6).map(\.mb)
                let mean = last.reduce(0, +) / 6
                if mean > 0 && last.allSatisfy({ abs($0 - mean) <= 0.05 * mean }) {
                    outcome = judge(s.obj, label: deviceLabel, rig: rig)
                    break
                }
            }
            if t > deadline { break }
        }
        if case .fail(let why) = outcome, why == "not-steady" {
            let pts = series.map { String(format: "%.0f", $0.mb) }.joined(separator: ",")
            outcome = .fail("not-steady: \(deviceLabel) series MB [\(pts)]")
        }
        return finish(rig, outcome, device: device, bootedByRig: bootedByRig, marker: marker)
    }

    /// Judged from the sample that completes "steady" alone (its members' pid and ppid).
    static func judge(_ sample: [String: Any], label: String, rig: Rig) -> Outcome {
        let groups = SampleView.groups(sample)
        let matches = groups.filter { ($0["kind"] as? String) == "simulator" && ($0["label"] as? String) == label }
        guard matches.count == 1, let g = matches.first else {
            return .fail("expected one simulator group '\(label)', found \(matches.count) (labels: \(groups.filter { ($0["kind"] as? String) == "simulator" }.compactMap { $0["label"] as? String }))")
        }
        let fp = JSONRead.uint64(g["footprint"]) ?? 0
        let members = (g["members"] as? [[String: Any]]) ?? []
        guard let root = members.first(where: { ($0["name"] as? String) == "launchd_sim" }),
              let rootPid = JSONRead.int(root["pid"]) else {
            return .fail("the simulator group has no launchd_sim member")
        }
        // ppid-closure of launchd_sim over every member of the sample.
        var children: [Int: [Int]] = [:]
        var ppidOf: [Int: Int] = [:]
        for m in SampleView.members(sample) {
            guard let pid = JSONRead.int(m["pid"]), let ppid = JSONRead.int(m["ppid"]) else { continue }
            ppidOf[pid] = ppid
            if pid != ppid { children[ppid, default: []].append(pid) }
        }
        var closure: Set<Int> = []
        var stack = [rootPid]
        while let p = stack.popLast() {
            guard closure.insert(p).inserted else { continue }
            stack += children[p] ?? []
        }
        let groupPids = Set(members.compactMap { JSONRead.int($0["pid"]) })
        var problems: [String] = []
        if Double(fp) < 300 * MiB { problems.append("footprint \(mb(fp)) < 300 MB") }
        if groupPids != closure {
            let extra = groupPids.subtracting(closure).sorted().prefix(10)
            let missing = closure.subtracting(groupPids).sorted().prefix(10)
            problems.append("members ≠ ppid-closure of launchd_sim (extra \(Array(extra)), missing \(Array(missing)))")
        }
        // No pid in any other group has a simulator-group pid in its ppid chain.
        var leaks: [Int] = []
        for og in groups where (og["label"] as? String) != label || (og["kind"] as? String) != "simulator" {
            for m in (og["members"] as? [[String: Any]]) ?? [] {
                guard let pid = JSONRead.int(m["pid"]) else { continue }
                var p = ppidOf[pid] ?? 0
                var hops = 0
                while p > 1, hops < 256 {
                    if groupPids.contains(p) {
                        leaks.append(pid)
                        break
                    }
                    p = ppidOf[p] ?? 0
                    hops += 1
                }
            }
        }
        if !leaks.isEmpty { problems.append("pids outside the group descend from it: \(leaks.prefix(10))") }
        let summary = "\(label) footprint \(mb(fp)), \(groupPids.count) members (launchd_sim pid \(rootPid))"
        if problems.isEmpty { return .pass(summary) }
        return .fail(summary + "; " + problems.joined(separator: "; "))
    }

    static func shutdown(_ rig: Rig, udid: String, marker: String) {
        _ = rig.run("/usr/bin/xcrun", ["simctl", "shutdown", udid])
        for _ in 0..<60 {
            if !isBooted(rig, udid) { break }
            sleep(1)
        }
        if !isBooted(rig, udid) { try? FileManager.default.removeItem(atPath: marker) }
    }

    static func finish(_ rig: Rig, _ outcome: Outcome, device: Device, bootedByRig: Bool,
                       marker: String) -> Outcome {
        guard bootedByRig else { return outcome }
        Children.shared.stopAll()
        shutdown(rig, udid: device.udid, marker: marker)
        extraCleanup.removeAll()
        if isBooted(rig, device.udid) {
            return .fail("the rig-booted \(device.name) (\(device.udid)) is still booted after the check (Brakes: stop and report). Check outcome was: \(outcome)")
        }
        rig.report.line("  check 6: \(device.name) shut down; confirmed not booted")
        return outcome
    }
}
