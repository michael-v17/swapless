import Darwin
import Foundation
import SwaplessCore

/// Check 5 · budget (`--budget`, ~11 min) on the installed release app.
enum Check5 {
    /// The footprint budget, in MiB (owner, 2026-11-05, DECISIONS.md): idle ≤ 30 MiB before the
    /// menu has ever been shown, ≤ 40 MiB after it has been used, peak ≤ 45 MiB.
    static let idleBeforeMenuMiB = 30.0
    static let idleAfterMenuMiB = 40.0
    static let peakMiB = 45.0

    static let installed = "/Applications/Swapless.app/Contents/MacOS/Swapless"
    static let selfPredicate = "subsystem == \"com.michaelv.swapless\" AND category == \"self\" AND processImagePath == \"/Applications/Swapless.app/Contents/MacOS/Swapless\""
    static let samplerPredicate = "subsystem == \"com.michaelv.swapless\" AND category == \"sampler\" AND processImagePath == \"/Applications/Swapless.app/Contents/MacOS/Swapless\""

    struct SelfLine {
        let arrived: Double
        let cpuSeconds: Double
        let footprint: UInt64
        let menuOpenSeconds: Double
        let psTime: Double?
        let physFootprint: UInt64?
        /// `cpuPct10mIdle` as printed (nil when the field is missing).
        let idleRaw: String?
    }

    /// The `self` line's fields, by key.
    static func fields(_ text: String) -> [String: String] {
        guard let r = text.range(of: "self cpuSeconds=") else { return [:] }
        var fields: [String: String] = [:]
        for part in text[r.lowerBound...].split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
        }
        return fields
    }

    static func parse(_ text: String) -> (cpu: Double, fp: UInt64, menu: Double)? {
        guard let r = text.range(of: "self cpuSeconds=") else { return nil }
        var fields: [String: String] = [:]
        for part in text[r.lowerBound...].split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
        }
        guard let cpu = fields["cpuSeconds"].flatMap(Double.init),
              let fp = fields["footprint"].flatMap(UInt64.init),
              let menu = fields["menuOpenSeconds"].flatMap(Double.init) else { return nil }
        return (cpu, fp, menu)
    }

    static func newest(_ paths: [String]) -> Date? {
        paths.compactMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }.max()
    }

    static func allFiles(under dir: String) -> [String] {
        guard let e = FileManager.default.enumerator(atPath: dir) else { return [] }
        return e.compactMap { $0 as? String }.map { dir + "/" + $0 }
    }

    /// The precondition: running from LaunchServices, newer than its executable, identical to the
    /// repo-root bundle, which is newer than Package.swift and every file under Sources/.
    static func installedApp(_ rig: Rig) -> (pid: Int32?, why: String?) {
        let stale = "installed app is stale: run ./scripts/make-app.sh release --adhoc"
        let procs = ProcessTable.read().filter { $0.euid == rig.uid && ProcessTable.executablePath(pid: $0.pid) == installed }
        guard procs.count == 1, let p = procs.first else { return (nil, "\(stale) (\(procs.count) installed instances running)") }
        guard p.ppid == 1 else { return (nil, "\(stale) (ppid \(p.ppid), not launched by LaunchServices)") }
        guard let exeM = newest([installed]), p.identity.startTime > exeM.timeIntervalSince1970 else {
            return (nil, "\(stale) (started before its executable was replaced)")
        }
        let local = rig.repoRoot + "/Swapless.app/Contents/MacOS/Swapless"
        let cmp = rig.run("/usr/bin/cmp", ["-s", installed, local])
        guard cmp.status == 0 else { return (nil, "\(stale) (differs from ./Swapless.app)") }
        guard let localM = newest([local]),
              let srcM = newest([rig.repoRoot + "/Package.swift"] + allFiles(under: rig.repoRoot + "/Sources")),
              localM > srcM else {
            return (nil, "\(stale) (./Swapless.app is older than Package.swift or Sources/)")
        }
        return (p.pid, nil)
    }

    static func run(_ rig: Rig) -> Outcome {
        let checkStart = now()
        // 5c runs beside the installed-app window, so --budget grows by about a minute.
        let c5c = Check5c.begin(rig)
        let (pidOpt, why) = installedApp(rig)
        var outcome: Outcome
        if let why {
            outcome = .fail(why)
        } else {
            let pid = pidOpt!
            // Which CPU budget: 0.2 %, or 0.6 % in top fallback mode.
            let samp = rig.run("/usr/bin/log", ["show", "--last", "2h", "--predicate", samplerPredicate])
            let topMode = samp.out.components(separatedBy: "\n").last { $0.contains("self-check") }?.contains("source=top") ?? false
            let cpuLimit = topMode ? 0.6 : 0.2
            rig.report.line("  check 5: installed Swapless pid \(pid); CPU budget \(cpuLimit) % (\(topMode ? "top fallback" : "coalition") mode)")
            var attempt = 0
            outcome = .fail("not measured")
            while attempt < 2 {
                attempt += 1
                let r = window(rig, pid: pid, cpuLimit: cpuLimit, since: attempt == 1 ? checkStart : now())
                if case .skip(let w) = r, w == "disturbed" {
                    if attempt == 1 {
                        rig.report.line("  check 5: window disturbed; measuring once more")
                        continue
                    }
                    outcome = .skip("disturbed (twice)")
                    break
                }
                outcome = r
                break
            }
        }
        // The peak test and the (offscreen) menu test run whatever happened above.
        let c = c5c.finish(rig)
        rig.report.result("  check 5c budget-with-quit-on-close", c)
        return combine([outcome, c, peakTest(rig), menuTest(rig), menuOpenTest(rig)])
    }

    /// Any fail fails (all reasons kept); else any skip skips; else pass.
    static func combine(_ parts: [Outcome]) -> Outcome {
        var fails: [String] = []
        var skips: [String] = []
        var passes: [String] = []
        for p in parts {
            switch p {
            case .fail(let w): fails.append(w)
            case .skip(let w): skips.append(w)
            case .pass(let w): passes.append(w)
            }
        }
        if !fails.isEmpty { return .fail(fails.joined(separator: "; ")) }
        if !skips.isEmpty { return .skip((skips + passes).joined(separator: " · ")) }
        return .pass(passes.joined(separator: " · "))
    }

    /// One measurement window: from the first `self` line after `since` to the second line after
    /// that (≈ 10 min). `.skip("disturbed")` asks for one re-measure.
    static func window(_ rig: Rig, pid: Int32, cpuLimit: Double, since: Double) -> Outcome {
        let stream = Child(name: "c5-log-stream", executable: "/usr/bin/log",
                           arguments: ["stream", "--level", "info", "--predicate", selfPredicate],
                           environment: rig.baseEnv())
        do { try stream.start() } catch { return .fail("log stream failed to start") }
        defer { stream.stop() }
        var lines: [SelfLine] = []
        var from = 0
        let firstDeadline = since + 360
        while lines.count < 3 {
            let deadline = lines.isEmpty ? firstDeadline : lines[0].arrived + 11 * 60
            let remaining = deadline - now()
            if remaining <= 0 { break }
            guard let idx = stream.waitLine(from: from, timeout: remaining, { _, t in t.contains("self cpuSeconds=") }) else { break }
            from = idx + 1
            let text = stream.lines()[idx].text
            guard let p = parse(text) else { continue }
            let arrived = now()
            let ps = rig.psTime(pid: pid)
            let fpt = rig.footprintTool(pid: pid)
            lines.append(SelfLine(arrived: arrived, cpuSeconds: p.cpu, footprint: p.fp, menuOpenSeconds: p.menu,
                                  psTime: ps, physFootprint: fpt?.phys, idleRaw: fields(text)["cpuPct10mIdle"]))
            rig.report.line(String(format: "  check 5: self line %d: cpuSeconds %.3f (ps %@) footprint %@ (footprint(1) %@) menuOpenSeconds %.1f",
                                   lines.count, p.cpu, ps.map { String(format: "%.2f", $0) } ?? "nil", mb(p.fp),
                                   fpt.map { mb($0.phys) } ?? "nil", p.menu))
        }
        if lines.isEmpty { return .fail("self-report: no installed-app self line within 360 s") }
        if lines.count < 3 { return .fail("self-report: only \(lines.count) self lines by window start + 11 min") }
        let a = lines[0]
        let b = lines[2]
        // Disturbance: actions logged by the installed app, or the menu opened.
        let acts = rig.run("/usr/bin/log", ["show", "--start", logStamp(a.arrived - 180), "--end", logStamp(b.arrived + 1),
                                            "--predicate", installedActionsPredicate])
        if acts.out.contains("action id=") || b.menuOpenSeconds != a.menuOpenSeconds {
            return .skip("disturbed")
        }
        var problems: [String] = []
        guard let psA = a.psTime, let psB = b.psTime else { return .fail("ps time unavailable") }
        let cpuPct = (psB - psA) / (b.arrived - a.arrived) * 100
        if cpuPct > cpuLimit { problems.append(String(format: "CPU %.3f %% > %.1f %%", cpuPct, cpuLimit)) }
        // v1-menu-today: the idle figure the footer shows agrees with the window's CPU (the
        // menu was closed throughout: the disturbance rule re-measures otherwise).
        var idleNote = "cpuPct10mIdle missing"
        if let raw = b.idleRaw, let idle = Double(raw) {
            let diff = abs(idle - cpuPct)
            idleNote = String(format: "cpuPct10mIdle %.3f vs window %.3f (|Δ| %.3f pp, limit %.2f)", idle, cpuPct, diff, idleTolerance)
            if diff > idleTolerance { problems.append("idle agreement: " + idleNote) }
        } else {
            problems.append("self-report: line 3 cpuPct10mIdle is \(b.idleRaw ?? "missing")")
        }
        rig.report.line("  check 5: idle agreement: " + idleNote)
        for (i, l) in [a, lines[1], b].enumerated() {
            if let ps = l.psTime, abs(l.cpuSeconds - ps) > max(0.05, 0.10 * ps) {
                problems.append(String(format: "self-report %d: cpuSeconds %.3f vs ps %.2f", i + 1, l.cpuSeconds, ps))
            }
            if let phys = l.physFootprint, abs(Double(l.footprint) - Double(phys)) > 2 * MiB {
                problems.append("self-report \(i + 1): footprint \(mb(l.footprint)) vs footprint(1) \(mb(phys))")
            }
            if l.physFootprint == nil { problems.append("self-report \(i + 1): footprint(1) failed") }
        }
        // At the end: top MEM within the idle limit for whether the menu has been used since
        // launch (menuOpenSeconds > 0), and phys_footprint_peak ≤ 45 MiB.
        let menuUsed = a.menuOpenSeconds > 0
        let idleLimit = menuUsed ? idleAfterMenuMiB : idleBeforeMenuMiB
        let topMem = (try? rig.top())?.values[pid]
        let fpt = rig.footprintTool(pid: pid)
        if let topMem, Double(topMem) > idleLimit * MiB {
            problems.append(String(format: "top MEM %@ > %.0f MiB (%@)", mb(topMem), idleLimit,
                                   menuUsed ? "menu used" : "menu never shown"))
        }
        if topMem == nil { problems.append("the installed app is missing from top") }
        if let fpt, Double(fpt.peak) > peakMiB * MiB {
            problems.append(String(format: "phys_footprint_peak %@ > %.0f MiB", mb(fpt.peak), peakMiB))
        }
        if fpt == nil { problems.append("footprint(1) failed at the end") }
        let summary = String(format: "window %.0f s · CPU %.3f %% (Δps %.2f s) · %@ · top MEM %@ (limit %.0f MiB, %@) · peak %@",
                             b.arrived - a.arrived, cpuPct, psB - psA, idleNote, topMem.map(mb) ?? "nil", idleLimit,
                             menuUsed ? "menu used" : "menu never shown", fpt.map { mb($0.peak) } ?? "nil")
        rig.report.line("  check 5: " + summary)
        return problems.isEmpty ? .pass(summary) : .fail(summary + "; " + problems.joined(separator: "; "))
    }

    /// The on-screen menu walk (`--on-screen-menu` only; never in `--budget` or the done-gate).
    /// It opens the real status-item menu on the owner's screen, so it runs only in an
    /// announced session the owner approved (owner rule, DECISIONS.md 2026-11-05). The release
    /// app shows its menu `menuShows` times, walking a few group submenus each time (the app's
    /// `SWAPLESS_RIG_MENU_SHOWS` hook). Every planned submenu must open, and none may close on
    /// its own (a refresh must never close an open submenu). After the menu has stayed
    /// closed for `menuIdleSeconds`, footprint(1) must be ≤ 40 MiB (menu used) and the peak
    /// ≤ 45 MiB.
    static let menuShows = 10
    static let menuIdleSeconds: Double = 60

    static func onScreenMenuWalk(_ rig: Rig) -> Outcome {
        do {
            let dir = try rig.tempStateDir()
            var env = rig.baseEnv()
            env["SWAPLESS_STATE_DIR"] = dir
            env["SWAPLESS_DRY_RUN"] = "1"
            env["SWAPLESS_RIG_MENU_SHOWS"] = String(menuShows)
            let exe = rig.repoRoot + "/Swapless.app/Contents/MacOS/Swapless"
            let c = Child(name: "menu-walk", executable: exe, arguments: [], environment: env,
                          stderrPath: "\(rig.rigDir)/menu-walk.stderr")
            try c.start()
            defer { c.stop() }
            guard let s = c.waitEvent("start", timeout: 60), let r = c.waitEvent("rules", from: s.index + 1, timeout: 30) else {
                return .fail("on-screen walk: no start/rules lines")
            }
            if (s.obj["dryRun"] as? Bool) != true || realpathString((s.obj["stateDir"] as? String) ?? "") != realpathString(dir)
                || (r.obj["status"] as? String) != "ok" {
                return .fail("on-screen walk: start-line guard")
            }
            // Each show takes ~13 s; shows wait for idle input (≤ 120 s each) and may be redone.
            guard let m = c.waitEvent("menuShows", timeout: Double(menuShows) * 30 + 600) else {
                return .fail("on-screen walk: no menuShows line")
            }
            if let e = m.obj["error"] as? String {
                // The owner's keyboard or mouse kept interrupting (an open menu takes the
                // keyboard): like the budget window's "disturbed", a skip, never a pass.
                return e.hasPrefix("disturbed") ? .skip("on-screen walk: \(e)") : .fail("on-screen walk: \(e)")
            }
            let shown = JSONRead.int(m.obj["n"]) ?? 0
            let planned = JSONRead.int(m.obj["submenusPlanned"]) ?? 0
            let opened = JSONRead.int(m.obj["submenusOpened"]) ?? 0
            let unexpected = JSONRead.int(m.obj["unexpectedSubmenuCloses"]) ?? -1
            let extra = JSONRead.int(m.obj["extraClicks"]) ?? 0
            let disturbed = JSONRead.int(m.obj["disturbedShows"]) ?? 0
            if shown != menuShows { return .fail("on-screen walk: \(shown) of \(menuShows) shows") }
            var problems: [String] = []
            if planned != menuShows * 3 || opened != planned {
                problems.append("\(opened) of \(planned) planned submenus opened (needs \(menuShows * 3) of \(menuShows * 3))")
            }
            if unexpected != 0 { problems.append("\(unexpected) submenu(s) closed while open (the refresh must never close one)") }
            let closedAt = now()
            while now() - closedAt < menuIdleSeconds {
                if !c.isRunning { return .fail("on-screen walk: the app exited while idle (status \(c.exitStatus))") }
                usleep(500_000)
            }
            guard let fpt = rig.footprintTool(pid: c.pid) else { return .fail("on-screen walk: footprint(1) failed") }
            let line = String(format: "on-screen walk: %d shows (%d redone after input), %d/%d submenus opened, %d closed unexpectedly, %d extra clicks; then %.0f s closed: footprint(1) %@ (limit %.0f MiB), peak %@ (limit %.0f MiB)",
                              shown, disturbed, opened, planned, unexpected, extra, menuIdleSeconds, mb(fpt.phys),
                              idleAfterMenuMiB, mb(fpt.peak), peakMiB)
            rig.report.line("  check 5: " + line)
            if Double(fpt.phys) > idleAfterMenuMiB * MiB {
                problems.append(String(format: "footprint %@ > %.0f MiB", mb(fpt.phys), idleAfterMenuMiB))
            }
            if Double(fpt.peak) > peakMiB * MiB { problems.append(String(format: "peak %@ > %.0f MiB", mb(fpt.peak), peakMiB)) }
            return problems.isEmpty ? .pass(line) : .fail(line + "; " + problems.joined(separator: "; "))
        } catch {
            return .fail("on-screen walk: \(error)")
        }
    }

    /// Menu draw test, offscreen (owner rule, 2026-11-05: nothing on screen; DECISIONS.md).
    /// The release app runs with no status item and draws its real menu, every row of it and of
    /// every group submenu, with AppKit's menu-item cell into layer-backed views of a window
    /// that is never ordered on screen, `menuDraws` times, 2 s apart, with the menu-open display
    /// sweeps on (the app's `SWAPLESS_RIG_MENU_DRAWS` hook). Every draw must complete (an AppKit
    /// exception in the fill stops the chain: that is how the reused-row bug was found), rows
    /// must be drawn, none may be visible, and the peak must stay ≤ 45 MiB.
    /// Not a check of the 40 MiB "after use" limit: drawing offscreen leaves +3–4 MiB, not the
    /// +10–14 MiB the on-screen menu leaves (docs/research/2026-11-05-menu-footprint.md), so
    /// that limit is the owner's acceptance check, with the footprint the menu shows. The
    /// footprints are reported for the record.
    static let menuDraws = 50
    static let drawSettleSeconds: Double = 30

    static func menuTest(_ rig: Rig) -> Outcome {
        do {
            let dir = try rig.tempStateDir()
            var env = rig.baseEnv()
            env["SWAPLESS_STATE_DIR"] = dir
            env["SWAPLESS_DRY_RUN"] = "1"
            env["SWAPLESS_RIG_MENU_DRAWS"] = String(menuDraws)
            let exe = rig.repoRoot + "/Swapless.app/Contents/MacOS/Swapless"
            let c = Child(name: "c5-menu", executable: exe, arguments: [], environment: env,
                          stderrPath: "\(rig.rigDir)/c5-menu.stderr")
            try c.start()
            defer { c.stop() }
            guard let s = c.waitEvent("start", timeout: 60), let r = c.waitEvent("rules", from: s.index + 1, timeout: 30) else {
                return .fail("menu draw test: no start/rules lines")
            }
            if (s.obj["dryRun"] as? Bool) != true || realpathString((s.obj["stateDir"] as? String) ?? "") != realpathString(dir)
                || (r.obj["status"] as? String) != "ok" {
                return .fail("menu draw test: start-line guard")
            }
            // First sample + settle + 2 s per draw, with room for a loaded Mac.
            let due = drawSettleSeconds + Double(menuDraws) * 2 + 180
            guard let m = c.waitEvent("menuDraws", timeout: due) else {
                return .fail("menu draw test: TIMEOUT: no menuDraws line in \(Int(due)) s, so the draw chain stopped. AppKit logs an exception raised in a timer callback and carries on: /usr/bin/log show --last 10m --predicate 'processID == \(c.pid)'")
            }
            let n = JSONRead.int(m.obj["n"]) ?? 0
            let rows = JSONRead.int(m.obj["rows"]) ?? 0
            let visible = JSONRead.int(m.obj["visibleDraws"]) ?? -1
            let before = JSONRead.uint64(m.obj["footprintBefore"]) ?? .max
            let closedAt = now()
            while now() - closedAt < menuIdleSeconds {
                if !c.isRunning { return .fail("menu draw test: the app exited while idle (status \(c.exitStatus))") }
                usleep(500_000)
            }
            guard let fpt = rig.footprintTool(pid: c.pid) else { return .fail("menu draw test: footprint(1) failed") }
            let line = String(format: "menu draw test (offscreen: no status item, window never ordered on screen): %d draws, %d rows drawn, %d visible; footprint before %@, %.0f s after %@ (for the record: offscreen doesn't reproduce the on-screen cost), peak %@ (limit %.0f MiB)",
                              n, rows, visible, mb(before), menuIdleSeconds, mb(fpt.phys), mb(fpt.peak), peakMiB)
            rig.report.line("  check 5: " + line)
            var problems: [String] = []
            if n != menuDraws { problems.append("\(n) of \(menuDraws) draws") }
            if rows < menuDraws * 5 { problems.append("only \(rows) rows drawn") }
            if visible != 0 { problems.append("\(visible) draws had a visible window (must be 0)") }
            if Double(fpt.peak) > peakMiB * MiB { problems.append(String(format: "peak %@ > %.0f MiB", mb(fpt.peak), peakMiB)) }
            return problems.isEmpty ? .pass(line) : .fail(line + "; " + problems.joined(separator: "; "))
        } catch {
            return .fail("menu draw test: \(error)")
        }
    }

    /// |cpuPct10mIdle − window CPU| limit, percentage points (v1-menu-today S5).
    static let idleTolerance = 0.02

    /// Menu-open test, offscreen (v1-menu-today S5, T4): the release app with no status item
    /// simulates a 60 s menu open on never-shown menus, with three group submenus opened in turn
    /// (`SWAPLESS_RIG_MENU_OPEN`). A regression gate for the 5 s cadence and the single refresh
    /// per publish; it can't see on-screen drawing (that is the owner's acceptance).
    static let menuOpenSeconds = 60

    static func menuOpenTest(_ rig: Rig) -> Outcome {
        let hint = "/usr/bin/log show --last 15m --predicate 'processID == %d'"
        do {
            let dir = try rig.tempStateDir()
            var env = rig.baseEnv()
            env["SWAPLESS_STATE_DIR"] = dir
            env["SWAPLESS_DRY_RUN"] = "1"
            env["SWAPLESS_RIG_MENU_OPEN"] = String(menuOpenSeconds)
            let exe = rig.repoRoot + "/Swapless.app/Contents/MacOS/Swapless"
            let c = Child(name: "c5-open", executable: exe, arguments: ["--duration", "360"], environment: env,
                          stderrPath: "\(rig.rigDir)/c5-open.stderr")
            let started = now()
            try c.start()
            defer { c.stop() }
            func missing(_ what: String, _ deadline: Double) -> Outcome {
                if !c.isRunning { return .fail("menu-open test: exited early (status \(c.exitStatus)) before its \(what) line") }
                return .fail("menu-open test: TIMEOUT: no \(what) line within \(Int(deadline)) s of start. " + String(format: hint, c.pid))
            }
            guard let s = c.waitEvent("start", timeout: 60) else { return missing("start", 60) }
            guard let r = c.waitEvent("rules", from: s.index + 1, timeout: 30) else { return missing("rules", 90) }
            if (s.obj["dryRun"] as? Bool) != true || realpathString((s.obj["stateDir"] as? String) ?? "") != realpathString(dir)
                || (r.obj["status"] as? String) != "ok" {
                return .fail("menu-open test: start-line guard")
            }
            guard let m = c.waitEvent("menuOpen", from: r.index + 1, timeout: max(0, started + 180 - now())) else {
                return missing("menuOpen", 180)
            }
            guard let tl = c.waitEvent("menuOpenTail", from: m.index + 1, timeout: max(0, started + 330 - now())) else {
                return missing("menuOpenTail", 330)
            }
            let o = m.obj
            let sweeps = JSONRead.int(o["displaySweeps"]) ?? -1
            let publishes = JSONRead.int(o["publishes"]) ?? -1
            let refreshes = JSONRead.int(o["refreshes"]) ?? -1
            let batches = JSONRead.int(o["compressedReadBatches"]) ?? -1
            let opened = JSONRead.int(o["submenusOpened"]) ?? -1
            let cpuOpen = JSONRead.double(o["cpuSecondsOpen"]) ?? -1
            let pctOpen = JSONRead.double(o["cpuPercentOpen"]) ?? .infinity
            let windows = JSONRead.int(o["windows"]) ?? -1
            let tailCpu = JSONRead.double(tl.obj["cpuSeconds"]) ?? -1
            let tailPct = JSONRead.double(tl.obj["cpuPercent"]) ?? .infinity
            let line = String(format: "menu-open test: %d s open, displaySweeps %d (12–13), publishes %d (≤ %d), refreshes %d (≤ %d), compressedReadBatches %d (== 3), submenusOpened %d, cpuSecondsOpen %.3f, cpuPercentOpen %.3f %% (≤ 1.0), tail %.3f s = %.3f %% over 120 s (≤ 0.3), windows %d (offscreen: the on-screen cost is the owner's acceptance)",
                              menuOpenSeconds, sweeps, publishes, sweeps + 2, refreshes, publishes + 1, batches, opened,
                              cpuOpen, pctOpen, tailCpu, tailPct, windows)
            rig.report.line("  check 5: " + line)
            var problems: [String] = []
            if !(12...13).contains(sweeps) { problems.append("displaySweeps \(sweeps) not in 12–13") }
            if publishes > sweeps + 2 { problems.append("publishes \(publishes) > displaySweeps + 2") }
            if refreshes > publishes + 1 { problems.append("refreshes \(refreshes) > publishes + 1") }
            if batches != 3 { problems.append("compressedReadBatches \(batches) ≠ 3") }
            if pctOpen > 1.0 { problems.append(String(format: "cpuPercentOpen %.3f %% > 1.0 %%", pctOpen)) }
            if tailPct > 0.3 { problems.append(String(format: "tail %.3f %% > 0.3 %%", tailPct)) }
            if windows != 0 { problems.append("\(windows) windows (must be 0)") }
            return problems.isEmpty ? .pass(line) : .fail(line + "; " + problems.joined(separator: "; "))
        } catch {
            return .fail("menu-open test: \(error)")
        }
    }

    /// The release app-mode run that builds the real NSMenu 20 times.
    static func peakTest(_ rig: Rig) -> Outcome {
        do {
            let dir = try rig.tempStateDir()
            var env = rig.baseEnv()
            env["SWAPLESS_STATE_DIR"] = dir
            env["SWAPLESS_DRY_RUN"] = "1"
            env["SWAPLESS_RIG_MENU_CYCLES"] = "20"
            let exe = rig.repoRoot + "/Swapless.app/Contents/MacOS/Swapless"
            let c = Child(name: "c5-peak", executable: exe, arguments: [], environment: env,
                          stderrPath: "\(rig.rigDir)/c5-peak.stderr")
            try c.start()
            guard let s = c.waitEvent("start", timeout: 60), let r = c.waitEvent("rules", from: s.index + 1, timeout: 30) else {
                c.stop()
                return .fail("peak test: no start/rules lines")
            }
            if (s.obj["dryRun"] as? Bool) != true || realpathString((s.obj["stateDir"] as? String) ?? "") != realpathString(dir)
                || (r.obj["status"] as? String) != "ok" {
                c.stop()
                return .fail("peak test: start-line guard")
            }
            guard let m = c.waitEvent("menuCycles", timeout: 120) else {
                c.stop()
                return .fail("peak test: no menuCycles line")
            }
            c.waitExit(timeout: 30)
            let peak = JSONRead.uint64(m.obj["peakFootprint"]) ?? .max
            let line = "peak test: \(JSONRead.int(m.obj["n"]) ?? 0) menu cycles, ri_lifetime_max_phys_footprint \(mb(peak)), exit \(c.exitStatus)"
            rig.report.line("  check 5: " + line)
            return Double(peak) <= peakMiB * MiB ? .pass(line) : .fail(line + String(format: " > %.0f MiB", peakMiB))
        } catch {
            return .fail("peak test: \(error)")
        }
    }
}


/// Check 5c (v1-quit-on-close S6): the budget with quit on last window close on. A release
/// headless engine, its own state dir with `"rules": []` (no restart rule) and the switch on, the
/// rig prefix set (it can't quit anything of the owner's), no test apps. CPU from `ps` between
/// 60 s and 660 s after launch (the first minute: self-check, first enumeration, observers, is
/// reported, not judged), ≤ 0.2 % of a core (0.6 % in top mode); footprint ≤ 30 MiB at the end,
/// peak ≤ 45 MiB; a `quitStatus` line with tracked ≥ 1 within 30 s.
final class Check5c: @unchecked Sendable {
    let started: Double
    private let lock = NSLock()
    private var engine: Rig.EngineRun?
    private var startError: String?
    private var ps60: Double?
    private var ps660: Double?
    /// footprint(1) at 660 s, while the engine is certainly running.
    private var fp660: (phys: UInt64, peak: UInt64)?
    private var done = false
    private var notes: [String] = []

    static let warmup = 60.0
    static let window = 600.0

    private init() { started = now() }

    static func begin(_ rig: Rig) -> Check5c {
        let c = Check5c()
        do {
            let dir = try rig.tempStateDir(rules: #"{"version":2,"rules":[],"quitOnLastWindow":{"enabled":true},"apps":[]}"#)
            c.engine = try rig.startEngine(name: "c5c-engine", release: true, stateDir: dir,
                                           env: ["SWAPLESS_RIG_QUIT_BUNDLE_PREFIX": Check9.livePrefix],
                                           duration: 3600, expectDryRun: false)
        } catch let e as CheckFailure {
            c.startError = e.why
            return c
        } catch {
            c.startError = "\(error)"
            return c
        }
        let pid = c.engine!.child.pid
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: max(0, c.started + warmup - now()))
            let a = rig.psTime(pid: pid)
            Thread.sleep(forTimeInterval: max(0, c.started + warmup + window - now()))
            let b = rig.psTime(pid: pid)
            let f = rig.footprintTool(pid: pid)
            c.lock.lock()
            c.ps60 = a
            c.ps660 = b
            c.fp660 = f
            c.done = true
            c.lock.unlock()
        }
        return c
    }

    func finish(_ rig: Rig) -> Outcome {
        if let startError { return .fail("5c: engine didn't start: \(startError)") }
        guard let e = engine else { return .fail("5c: no engine") }
        var problems: [String] = []
        let tracked = e.child.events("quitStatus").map(\.obj).first { ($0["tracked"] as? Int ?? 0) >= 1 }
        let firstStatusT = e.child.events("quitStatus").first?.t
        if tracked == nil || (firstStatusT.map { $0 - started > 30 } ?? true) {
            problems.append("no quitStatus with tracked ≥ 1 within 30 s")
        }
        let deadline = started + Self.warmup + Self.window + 60
        while now() < deadline {
            lock.lock()
            let d = done
            lock.unlock()
            if d { break }
            Thread.sleep(forTimeInterval: 1)
        }
        lock.lock()
        let a = ps60, b = ps660, d = done, fpt = fp660
        lock.unlock()
        guard d else {
            Timeouts.shared.record("5c: the ps window never finished")
            return .fail("5c: the ps window never finished")
        }
        let topMode = (e.start["source"] as? String) == "top"
        let limit = topMode ? 0.6 : 0.2
        e.child.stop()
        guard let a, let b else { return .fail("5c: ps time unavailable") }
        let pct = (b - a) / Self.window * 100
        let fp = fpt.map { Double($0.phys) / MiB }
        let peak = fpt.map { Double($0.peak) / MiB }
        rig.report.line(String(format: "  check 5c: quit-on-close on, tracking %@ apps · CPU %.3f %% over %.0f s (limit %.1f, %@ mode; warm-up %.1f s CPU) · footprint %@ · peak %@",
                               "\(tracked?["tracked"] ?? "?")", pct, Self.window, limit, topMode ? "top" : "coalition", a,
                               fp.map { String(format: "%.1f MiB", $0) } ?? "?", peak.map { String(format: "%.1f MiB", $0) } ?? "?"))
        if pct > limit { problems.append(String(format: "CPU %.3f %% > %.1f %%", pct, limit)) }
        if let fp, fp > Check5.idleBeforeMenuMiB { problems.append(String(format: "footprint %.1f MiB > %.0f", fp, Check5.idleBeforeMenuMiB)) }
        if let peak, peak > Check5.peakMiB { problems.append(String(format: "peak %.1f MiB > %.0f", peak, Check5.peakMiB)) }
        if fpt == nil { problems.append("footprint(1) failed") }
        let scope = e.child.events("action").count
        if scope != 0 { problems.append("\(scope) action(s) (expected none)") }
        return problems.isEmpty ? .pass(String(format: "CPU %.3f %%, footprint %.1f MiB, peak %.1f MiB", pct, fp ?? 0, peak ?? 0))
            : .fail("5c: " + problems.joined(separator: "; "))
    }
}
