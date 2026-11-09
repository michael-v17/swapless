// swapless-rig: the rig's checks (S6). Run through scripts/leak-rig.sh.
//
//   bare run            preflight + checks 1–4
//   --only N[,N…]       preflight + just those checks (1–4 only)
//   --budget            preflight + checks 1–5 (5 includes 5c)
//   --quit-on-close     preflight + check 9: launches the rig's off-screen test apps, which
//                       Mission Control can still show. Only in an announced session with
//                       the owner present (owner, 2026-11-06); never in the done-gate.
//   --sim               preflight + check 6
//   --live-wallpaper    preflight + check 7
//   --on-screen-menu    preflight + the on-screen menu walk: it opens the real menu on the
//                       owner's screen. Only in an announced session the owner approved
//                       (DECISIONS.md 2026-11-05); never part of the done-gate. It is
//                       numbered 8 internally; check 9 (quit on last window close) is not it.
//
// Exit code 0 iff there is no FAIL.
import Darwin
import Foundation
import SwaplessCore

let usage = "usage: --only takes 1–4; check 5 runs via --budget, 6 via --sim, 7 via --live-wallpaper; --quit-on-close (check 9) and --on-screen-menu only in an announced session the owner approved"

struct RigArgs {
    var debugBin = ""
    var releaseBin = ""
    var checks: [Int] = [1, 2, 3, 4]
    var mode = "default"
    var parentPid: Int32?
}

func exitUsage(_ msg: String) -> Never {
    print(msg)
    exit(2)
}

func parseRigArgs() -> RigArgs {
    var a = RigArgs()
    let argv = CommandLine.arguments
    var i = 1
    var modes: [String] = []
    func value() -> String {
        i += 1
        guard i < argv.count else { exitUsage("\(argv[i - 1]) needs a value") }
        return argv[i]
    }
    while i < argv.count {
        switch argv[i] {
        case "--debug-bin": a.debugBin = value()
        case "--release-bin": a.releaseBin = value()
        case "--parent-pid": a.parentPid = Int32(value())
        case "--only":
            let v = value()
            var list: [Int] = []
            for part in v.split(separator: ",", omittingEmptySubsequences: false) {
                guard let n = Int(part), (1...4).contains(n) else { exitUsage(usage) }
                if !list.contains(n) { list.append(n) }
            }
            guard !list.isEmpty else { exitUsage(usage) }
            a.checks = list.sorted()
            modes.append("only-" + list.sorted().map(String.init).joined(separator: ","))
        case "--budget":
            a.checks = [1, 2, 3, 4, 5]
            modes.append("budget")
        case "--sim":
            a.checks = [6]
            modes.append("sim")
        case "--live-wallpaper":
            a.checks = [7]
            modes.append("live-wallpaper")
        case "--quit-on-close":
            a.checks = [9]
            modes.append("quit-on-close")
        case "--on-screen-menu":
            a.checks = [8]
            modes.append("on-screen-menu")
        default:
            exitUsage("unknown argument \(argv[i])\n\(usage)")
        }
        i += 1
    }
    if modes.count > 1 { exitUsage("modes don't combine: \(modes.joined(separator: " "))\n\(usage)") }
    if let m = modes.first { a.mode = m }
    guard !a.debugBin.isEmpty, !a.releaseBin.isEmpty else { exitUsage("--debug-bin and --release-bin are required") }
    return a
}

let rigArgs = parseRigArgs()
let repoRoot = FileManager.default.currentDirectoryPath
let rigDir = repoRoot + "/.build/rig"
try? FileManager.default.createDirectory(atPath: rigDir, withIntermediateDirectories: true)

// One rig at a time.
let lockFd = open(rigDir + "/rig.lock", O_RDWR | O_CREAT, 0o644)
if lockFd < 0 || flock(lockFd, LOCK_EX | LOCK_NB) != 0 {
    print("rig: FAIL rig-busy (another rig invocation holds .build/rig/rig.lock)")
    exit(1)
}

let report = Report(dir: rigDir, mode: rigArgs.mode.replacingOccurrences(of: ",", with: "-"))
let rig = Rig(debugBin: rigArgs.debugBin, releaseBin: rigArgs.releaseBin, repoRoot: repoRoot,
              rigDir: rigDir, report: report)

/// Cleanup on every exit path: children, then (check 6) the rig-booted simulator.
nonisolated(unsafe) var extraCleanup: [() -> Void] = []
func cleanupAll() {
    Children.shared.stopAll()
    for c in extraCleanup { c() }
    extraCleanup.removeAll()
    rig.cleanup()
}

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    s.setEventHandler {
        report.line("rig: interrupted by signal \(sig); cleaning up")
        cleanupAll()
        exit(1)
    }
    s.resume()
    signalSources.append(s)
}

report.line("swapless-rig · mode \(rigArgs.mode) · checks \(rigArgs.checks.map(String.init).joined(separator: ",")) · \(Date())")
report.line("debug-bin \(rigArgs.debugBin) · release-bin \(rigArgs.releaseBin)")

/// A check during which a wait ran out cannot pass: the TIMEOUT lines become its FAIL.
func withTimeouts(_ o: Outcome) -> Outcome {
    let t = Timeouts.shared.drain()
    if t.isEmpty { return o }
    switch o {
    case .fail(let w): return .fail(w + "; " + timeoutText(t))
    case .pass, .skip: return .fail(timeoutText(t))
    }
}

func timeoutText(_ t: [String]) -> String { t.map { "TIMEOUT: " + $0 }.joined(separator: "; ") }

var ok = true
if let pre = Preflight.run(rig) {
    let pre = withTimeouts(pre)
    report.result("preflight", pre)
    ok = !pre.isFail
}

var check2Run: Check2Run?
if ok {
    for n in rigArgs.checks {
        let name: String
        let outcome: Outcome
        switch n {
        case 1:
            name = "check 1 footprint-matches-top"
            outcome = Check1.run(rig)
        case 2:
            name = "check 2 growth-flagged"
            let (o, run) = Check2.run(rig, evaluate: true)
            check2Run = run
            outcome = o
        case 3:
            name = "check 3 no-action-without-rule"
            outcome = Check3.run(rig, check2: check2Run)
        case 4:
            name = "check 4 ruled-action-once"
            outcome = Check4.run(rig)
        case 5:
            name = "check 5 budget"
            outcome = Check5.run(rig)
        case 6:
            name = "check 6 simulator"
            outcome = Check6.run(rig, parentPid: rigArgs.parentPid)
        case 7:
            name = "check 7 live-wallpaper"
            outcome = Check7.run(rig)
        case 9:
            report.line("rig: check 9 launches off-screen test apps for ~4 min; Mission Control would show them (announced session only)")
            name = "check 9 quit-on-last-window-close"
            outcome = Check9.run(rig)
        case 8:
            name = "on-screen menu walk (announced session only)"
            report.line("rig: on-screen menu walk: the real Swapless menu opens \(Check5.menuShows) times on this screen, ~13 s each")
            outcome = Check5.onScreenMenuWalk(rig)
        default:
            continue
        }
        Children.shared.stopAll()
        report.result(name, withTimeouts(outcome))
    }
}

cleanupAll()
let lateTimeouts = Timeouts.shared.drain()
if !lateTimeouts.isEmpty { report.result("cleanup", .fail(timeoutText(lateTimeouts))) }
let failed = !report.failures.isEmpty
report.line("rig: \(failed ? "FAIL" : "PASS") · \(report.failures.count) failed · \(report.skips.count) skipped · report \(report.path)")
exit(failed ? 1 : 0)
