import Foundation
import Testing
@testable import SwaplessCore

/// The probe readings (docs/research/2026-11-06-quit-on-close-probes.md), transcribed.
enum QuitFixtures {
    struct Entry: Decodable {
        var note: String
        var reading: WindowReading
    }

    static let all: [String: Entry] = {
        try! JSONDecoder().decode([String: Entry].self, from: Fixture.data("quit-readings.json"))
    }()

    static func reading(_ name: String) -> WindowReading {
        guard let e = all[name] else { fatalError("no reading \(name)") }
        return e.reading
    }
}

@Suite("Quit · window verdict (probe readings)")
struct WindowVerdictTests {
    func alive(_ name: String, closed: Set<UInt32> = []) -> Verdict {
        WindowVerdict.evaluate(QuitFixtures.reading(name), closed: closed)
    }

    @Test func notesHelpersNeverCount() {
        #expect(alive("notes-closed") == Verdict(alive: 0, ax: 0, elsewhere: 0))
        #expect(alive("notes-open").alive == 1)
    }

    @Test func aMinimizedWindowReportingAXDialogIsAlive() {
        #expect(alive("notes-minimized-visible") == Verdict(alive: 1, ax: 1, elsewhere: 0))
        #expect(alive("notes-minimized-other-space").alive == 1)
    }

    @Test func aWindowOnAnotherSpaceIsAliveElsewhere() {
        #expect(alive("notes-other-space") == Verdict(alive: 1, ax: 0, elsewhere: 1))
    }

    @Test func slackHiddenOnTheVisibleSpaceIsGoneAndTheMarkKeepsItGone() {
        #expect(alive("slack-hidden").alive == 0)
        let marks = WindowVerdict.closedMarks(QuitFixtures.reading("slack-hidden"))
        #expect(marks.contains(43438))
        #expect(alive("slack-hidden-owner-moved", closed: marks).alive == 0)
        #expect(alive("slack-hidden-owner-moved") == Verdict(alive: 1, ax: 0, elsewhere: 1))
    }

    @Test func chromesOffScreenWindowsOnTheVisibleSpaceDontCount() {
        #expect(alive("chrome-open").alive == 1)
        #expect(alive("chrome-closed").alive == 0)
        let marks = WindowVerdict.closedMarks(QuitFixtures.reading("chrome-closed"))
        #expect(alive("chrome-closed-owner-moved", closed: marks).alive == 0)
    }

    @Test func aWindowOnAnInvisibleSpaceIsNeverMarked() {
        #expect(!WindowVerdict.closedMarks(QuitFixtures.reading("notes-other-space")).contains(41836))
    }

    @Test func subroles() {
        func one(_ w: AXWin) -> Int {
            WindowVerdict.evaluate(WindowReading(ax: [w], cg: [], visibleSpaces: [1]), closed: []).alive
        }
        #expect(one(AXWin(id: 1, subrole: "AXDialog")) == 1)
        #expect(one(AXWin(id: 1, subrole: "AXSystemDialog")) == 1)
        #expect(one(AXWin(id: 1, subrole: "AXUnknown")) == 1)
        #expect(one(AXWin(id: 1, subrole: nil)) == 1)
        #expect(one(AXWin(id: 1, subrole: "AXFloatingWindow")) == 0)
        #expect(one(AXWin(id: 1, subrole: "AXSystemFloatingWindow")) == 0)
        #expect(one(AXWin(id: 1, subrole: "AXFloatingWindow", minimized: true)) == 1)
        #expect(one(AXWin(id: 1, role: "AXGroup", subrole: "AXHostingView")) == 0)
        #expect(one(AXWin(id: 1, role: "AXScrollArea", subrole: "AXDesktop")) == 0)
    }

    @Test func errors() {
        #expect(WindowVerdict.evaluate(WindowReading(ax: nil, cg: [], visibleSpaces: []), closed: []).error == "ax-error")
        let noId = WindowVerdict.evaluate(WindowReading(ax: [AXWin(id: 0)], cg: [], visibleSpaces: []), closed: [])
        #expect(noId.error == "no-window-id")
        #expect(WindowVerdict.closedMarks(WindowReading(ax: nil, cg: [CGWin(id: 5)], visibleSpaces: [])).isEmpty)
    }

    @Test func nonZeroLayersNeverCount() {
        let r = WindowReading(ax: [], cg: [CGWin(id: 9, layer: 3, spaces: [42])], visibleSpaces: [1])
        #expect(WindowVerdict.evaluate(r, closed: []).alive == 0)
    }
}

/// A gate input that passes every check.
func passingGate(now: Double = 1000) -> GateInput {
    GateInput(env: QuitEnvironment(settings: QuitSettings(status: .ok, enabled: true, apps: [])),
              app: AppFacts(pid: 42, bundleId: "com.apple.Notes", name: "Notes", launchTime: 0), now: now)
}

@Suite("Quit · gate")
struct QuitGateTests {
    @Test func passes() {
        #expect(QuitGate.evaluate(passingGate()) == .quit)
        var g = passingGate()
        g.env.dryRun = true
        #expect(QuitGate.evaluate(g) == .dryRun)
    }

    /// One mutation per reason, in T6's order.
    @Test func everyReasonInOrder() {
        typealias M = (inout GateInput) -> Void
        let steps: [(String, M)] = [
            ("rules-invalid", { $0.env.settings = .invalid("x") }),
            ("option-off", { $0.env.settings.enabled = false }),
            ("observe-only", { $0.env.observeOnly = true }),
            ("history-off", { $0.env.historyOn = false }),
            ("untrusted", { $0.env.trusted = false }),
            ("unavailable", { $0.env.available = false }),
            ("stage-manager", { $0.env.stageManager = true }),
            ("locked", { $0.env.pause = "locked" }),
            ("rig-scope", { $0.env.rigPrefix = "com.michaelv.swapless.rig.window.live." }),
            ("no-bundle-id", { $0.app.bundleId = nil; $0.env.rigPrefix = nil }),
            ("finder", { $0.app.bundleId = "com.apple.finder" }),
            ("never-quit", { $0.env.settings.apps = [AppEntry(bundleId: "com.apple.Notes", name: "Notes", neverQuit: true)] }),
            ("self", { $0.env.selfBundleId = "com.apple.Notes" }),
            ("not-regular", { $0.app.regular = false }),
            ("hidden", { $0.app.hidden = true }),
            ("young", { $0.app.launchTime = $0.now - 1 }),
            ("disarmed", { $0.disarmed = true }),
            ("rate-limit", { $0.recentQuits = [$0.now - 1, $0.now - 2, $0.now - 3] }),
        ]
        for (reason, m) in steps {
            var g = passingGate()
            m(&g)
            // Also fail the two last checks (fields no other step touches): the earlier reason
            // must still win.
            if reason != "disarmed" && reason != "rate-limit" {
                g.disarmed = true
                g.recentQuits = [g.now - 1, g.now - 2, g.now - 3]
            }
            let r = QuitGate.evaluate(g)
            #expect(r == .skip(reason), "expected \(reason), got \(r)")
        }
    }

    @Test func finderIsBlockedWithAnEmptyList() {
        var g = passingGate()
        g.app.bundleId = "com.apple.finder"
        #expect(QuitGate.evaluate(g) == .skip("finder"))
    }

    @Test func theRigPrefixAdmitsAnAccessoryAppOnlyWithThePrefix() {
        var g = passingGate()
        g.env.rigPrefix = "com.michaelv.swapless.rig.window.live."
        g.app.bundleId = "com.michaelv.swapless.rig.window.live.close-ax"
        g.app.regular = false
        #expect(QuitGate.evaluate(g) == .quit)
        g.env.rigPrefix = nil
        #expect(QuitGate.evaluate(g) == .skip("not-regular"))
        g.env.rigPrefix = "com.michaelv.swapless.rig.window.dry."
        #expect(QuitGate.evaluate(g) == .skip("rig-scope"))
    }

    @Test func boundaries() {
        var g = passingGate(now: 100)
        g.app.launchTime = 90.01
        #expect(QuitGate.evaluate(g) == .skip("young"))
        g.app.launchTime = 90
        #expect(QuitGate.evaluate(g) == .quit)
        g.app.finishedLaunching = false
        #expect(QuitGate.evaluate(g) == .skip("young"))
        g = passingGate(now: 1000)
        g.recentQuits = [400.01, 500, 600]
        #expect(QuitGate.evaluate(g) == .skip("rate-limit"))
        g.recentQuits = [399.99, 500, 600]
        #expect(QuitGate.evaluate(g) == .quit)
    }
}

@Suite("Quit · tracker sequences")
struct QuitTrackerTests {
    let pid: Int32 = 42
    let env = QuitEnvironment(settings: QuitSettings(status: .ok, enabled: true, apps: []))
    var facts: AppFacts { AppFacts(pid: pid, bundleId: "com.apple.Notes", name: "Notes", launchTime: 0) }

    func reads(_ out: [TrackerOutput]) -> [(Double, ReadPurpose)] {
        out.compactMap { if case let .read(_, at, p) = $0 { return (at, p) } else { return nil } }
    }
    func decisions(_ out: [TrackerOutput]) -> [QuitDecision] {
        out.compactMap { if case let .decision(d) = $0 { return d } else { return nil } }
    }
    func terminates(_ out: [TrackerOutput]) -> Int {
        out.filter { if case .terminate = $0 { return true } else { return false } }.count
    }

    /// An armed tracker: tracked at t=100, armed by notes-open.
    func armed() -> QuitTracker {
        let t = QuitTracker()
        _ = t.track(facts, at: 100)
        _ = t.reading(pid, QuitFixtures.reading("notes-open"), facts: facts, env: env, purpose: .arm, at: 100)
        return t
    }

    /// Close at `t0`, then settle, decide, confirm with the given readings.
    func closeAndRun(_ t: QuitTracker, at t0: Double, settle: String = "notes-closed", decide: String = "notes-closed",
                     confirm: String = "notes-closed", env e: QuitEnvironment? = nil) -> [TrackerOutput] {
        let e = e ?? env
        var out = t.trigger(pid, .destroyed, at: t0)
        #expect(reads(out).first?.0 == t0 + 0.3)
        out += t.reading(pid, QuitFixtures.reading(settle), facts: facts, env: e, purpose: .settle(.destroyed, triggerAt: t0), at: t0 + 0.3)
        guard reads(out).contains(where: { $0.1 == .decide }) else { return out }
        #expect(reads(out).last?.0 == t0 + 5.0)
        out += t.reading(pid, QuitFixtures.reading(decide), facts: facts, env: e, purpose: .decide, at: t0 + 5.0)
        guard reads(out).contains(where: { $0.1 == .confirm }) else { return out }
        #expect(reads(out).last?.0 == t0 + 5.5)
        out += t.reading(pid, QuitFixtures.reading(confirm), facts: facts, env: e, purpose: .confirm, at: t0 + 5.5)
        return out
    }

    @Test func notesCloseQuitsAfterDecideAndConfirm() {
        let t = armed()
        let out = closeAndRun(t, at: 200)
        #expect(terminates(out) == 1)
        #expect(decisions(out).last?.verdict == .quit)
        #expect(t.isDisarmed(pid))
    }

    @Test func slackHiddenThenOwnerMovesSpaceStillQuits() {
        let t = QuitTracker()
        _ = t.track(facts, at: 0)
        _ = t.reading(pid, QuitFixtures.reading("slack-open"), facts: facts, env: env, purpose: .arm, at: 0)
        let out = closeAndRun(t, at: 100, settle: "slack-hidden", decide: "slack-hidden-owner-moved",
                              confirm: "slack-hidden-owner-moved")
        #expect(terminates(out) == 1)
    }

    @Test func aWindowLeftOnAnotherSpaceKeepsTheApp() {
        let t = armed()
        let out = closeAndRun(t, at: 200, settle: "notes-other-space")
        #expect(terminates(out) == 0)
        #expect(decisions(out).first?.reason == "alive")
    }

    @Test func aMinimizedWindowKeepsTheApp() {
        let t = armed()
        let out = closeAndRun(t, at: 200, settle: "notes-minimized-visible")
        #expect(terminates(out) == 0)
    }

    @Test func triggerOnAnUnarmedAppDoesNothing() {
        let t = QuitTracker()
        _ = t.track(facts, at: 0)
        _ = t.reading(pid, QuitFixtures.reading("notes-closed"), facts: facts, env: env, purpose: .arm, at: 0)
        #expect(t.trigger(pid, .destroyed, at: 50).isEmpty)
        #expect(t.trigger(pid, .deactivated, at: 50).isEmpty)
    }

    @Test func enablingWithWindowlessAppsProducesNoDecision() {
        let t = QuitTracker()
        let out = t.track(facts, at: 0)
            + t.reading(pid, QuitFixtures.reading("notes-closed"), facts: facts, env: env, purpose: .arm, at: 0)
        #expect(decisions(out).isEmpty)
        #expect(terminates(out) == 0)
        #expect(!t.isArmed(pid))
    }

    @Test func windowCreatedDuringPendingCancels() {
        let t = armed()
        _ = t.trigger(pid, .destroyed, at: 200)
        _ = t.reading(pid, QuitFixtures.reading("notes-closed"), facts: facts, env: env, purpose: .settle(.destroyed, triggerAt: 200), at: 200.3)
        let out = t.windowCreated(pid, at: 202)
        #expect(decisions(out).first?.reason == "cancelled-window")
        let late = t.reading(pid, QuitFixtures.reading("notes-closed"), facts: facts, env: env, purpose: .decide, at: 205)
        #expect(late.isEmpty)
    }

    @Test func aWindowBackAtTheDecideReadCancels() {
        let t = armed()
        let out = closeAndRun(t, at: 200, decide: "notes-open")
        #expect(terminates(out) == 0)
        #expect(decisions(out).last?.reason == "alive")
    }

    @Test func confirmMustAlsoReadZero() {
        let t = armed()
        let out = closeAndRun(t, at: 200, confirm: "notes-minimized-visible")
        #expect(terminates(out) == 0)
    }

    @Test func refusedDisarmsUntilAnAWindowReading() {
        let t = armed()
        #expect(terminates(closeAndRun(t, at: 200)) == 1)
        // A destroy event of some other element: the app is still armed (it was), but disarmed.
        let again = closeAndRun(t, at: 300)
        #expect(terminates(again) == 0)
        #expect(decisions(again).last?.reason == "disarmed")
        // It opens a window: re-armed, and the next close quits again.
        _ = t.reading(pid, QuitFixtures.reading("notes-open"), facts: facts, env: env, purpose: .arm, at: 400)
        #expect(!t.isDisarmed(pid))
        #expect(terminates(closeAndRun(t, at: 500)) == 1)
    }

    @Test func pauseCancelsPending() {
        let t = armed()
        _ = t.trigger(pid, .destroyed, at: 200)
        _ = t.reading(pid, QuitFixtures.reading("notes-closed"), facts: facts, env: env, purpose: .settle(.destroyed, triggerAt: 200), at: 200.3)
        let out = t.cancelAll(reason: "asleep", at: 201)
        #expect(decisions(out).map(\.reason) == ["asleep"])
        #expect(t.reading(pid, QuitFixtures.reading("notes-closed"), facts: facts, env: env, purpose: .decide, at: 205).isEmpty)
    }

    @Test func goneDuringGrace() {
        let t = armed()
        _ = t.trigger(pid, .destroyed, at: 200)
        _ = t.reading(pid, QuitFixtures.reading("notes-closed"), facts: facts, env: env, purpose: .settle(.destroyed, triggerAt: 200), at: 200.3)
        #expect(decisions(t.untrack(pid, at: 202)).map(\.reason) == ["gone"])
    }

    @Test func deactivationIsABackstopOnlyWhenArmedAndNotPending() {
        let t = armed()
        #expect(reads(t.trigger(pid, .deactivated, at: 200)).count == 1)
        _ = t.reading(pid, QuitFixtures.reading("notes-closed"), facts: facts, env: env, purpose: .settle(.deactivated, triggerAt: 200), at: 200.3)
        #expect(t.trigger(pid, .deactivated, at: 201).isEmpty)
    }

    @Test func dryRunDisarmsWithoutTerminate() {
        let t = armed()
        var e = env
        e.dryRun = true
        let out = closeAndRun(t, at: 200, env: e)
        #expect(terminates(out) == 0)
        #expect(decisions(out).last?.verdict == .dryRun)
        #expect(t.isDisarmed(pid))
    }

    @Test func timing() {
        // 4.99 s: no decide read yet; the decide read is scheduled at exactly +5.0, confirm +5.5.
        let t = armed()
        _ = t.trigger(pid, .destroyed, at: 200)
        let settle = t.reading(pid, QuitFixtures.reading("notes-closed"), facts: facts, env: env,
                               purpose: .settle(.destroyed, triggerAt: 200), at: 200.3)
        #expect(reads(settle).map(\.0) == [205.0])
        #expect(!reads(settle).contains { $0.0 < 205.0 })
        let decide = t.reading(pid, QuitFixtures.reading("notes-closed"), facts: facts, env: env, purpose: .decide, at: 205)
        #expect(reads(decide).map(\.0) == [205.5])
    }

    @Test func rateLimitAtTheFourthQuitWithinTenMinutes() {
        let t = QuitTracker()
        var quits = 0
        var lastReason = ""
        for (i, t0) in [1000.0, 1100, 1200, 1300, 1700.6].enumerated() {
            let p = Int32(100 + i)
            let f = AppFacts(pid: p, bundleId: "com.relaunched", name: "R", launchTime: 0)
            _ = t.track(f, at: t0 - 50)
            _ = t.reading(p, QuitFixtures.reading("notes-open"), facts: f, env: env, purpose: .arm, at: t0 - 50)
            var out = t.trigger(p, .destroyed, at: t0)
            out += t.reading(p, QuitFixtures.reading("notes-closed"), facts: f, env: env, purpose: .settle(.destroyed, triggerAt: t0), at: t0 + 0.3)
            out += t.reading(p, QuitFixtures.reading("notes-closed"), facts: f, env: env, purpose: .decide, at: t0 + 5)
            out += t.reading(p, QuitFixtures.reading("notes-closed"), facts: f, env: env, purpose: .confirm, at: t0 + 5.5)
            quits += terminates(out)
            lastReason = decisions(out).last?.reason ?? ""
            if i == 3 { #expect(lastReason == "rate-limit") }
        }
        // Quits at 1005.5, 1105.5, 1205.5; the 4th (1305.5) is limited; the 5th at 1706.1 is
        // 600.6 s after the first, so allowed.
        #expect(quits == 4)
        #expect(lastReason == "quit")
    }
}

/// S2's property: whatever the event sequence, readings and settings, `terminate` is never
/// emitted when a wall applies.
@Suite("Quit · property: no terminate behind a wall")
struct QuitPropertyTests {
    func pick<T>(_ xs: [T], _ rng: inout SplitMix64) -> T { xs[Int(rng.next() % UInt64(xs.count))] }
    func chance(_ p: Double, _ rng: inout SplitMix64) -> Bool { rng.uniform(0, 1) < p }

    @Test func thousandRandomSequences() {
        let names = Array(QuitFixtures.all.keys).sorted()
        let bundles = ["com.apple.Notes", "com.apple.finder", "com.apple.Music", "com.michaelv.swapless",
                       "com.michaelv.swapless.rig.window.live.x", "com.tinyspeck.slackmacgap"]
        var terminations = 0
        for seed in 0..<1000 {
            var rng = SplitMix64(seed: UInt64(seed) &* 0x9E37 &+ 11)
            // 70 % of sequences are "benign": every wall rarely applies, so the terminate path
            // is reached often and the walls are tested against real attempts.
            let benign = chance(0.7, &rng)
            func wall(_ p: Double, _ rng: inout SplitMix64) -> Bool { chance(benign ? 0.02 : p, &rng) }
            let t = QuitTracker()
            var facts: [Int32: AppFacts] = [:]
            var lastVerdict: [Int32: Verdict] = [:]
            var closed: [Int32: Set<UInt32>] = [:]
            var now = 1000.0
            var queue: [(Int32, Double, ReadPurpose)] = []
            for p in Int32(1)...Int32(3) {
                let f = AppFacts(pid: p, bundleId: wall(0.1, &rng) ? nil : (benign && chance(0.6, &rng) ? "com.apple.Notes" : pick(bundles, &rng)),
                                 name: "A", regular: !wall(0.15, &rng), hidden: wall(0.1, &rng),
                                 launchTime: now - rng.uniform(0, 30), finishedLaunching: !wall(0.1, &rng))
                facts[p] = f
                for o in t.track(f, at: now) { if case let .read(pid, at, pu) = o { queue.append((pid, at, pu)) } }
            }
            for _ in 0..<40 {
                now += rng.uniform(0, 3)
                let p = Int32(1 + Int(rng.next() % 3))
                var env = QuitEnvironment(
                    settings: QuitSettings(status: wall(0.5, &rng) ? pick([.default, .invalid, .missing], &rng) : .ok,
                                           enabled: !wall(0.2, &rng),
                                           apps: chance(0.5, &rng) ? [AppEntry(bundleId: "com.apple.Music", name: "Music", neverQuit: true),
                                                                      AppEntry(bundleId: "com.apple.Notes", name: "Notes", neverQuit: wall(0.3, &rng))] : []),
                    observeOnly: wall(0.1, &rng), historyOn: !wall(0.1, &rng), trusted: !wall(0.1, &rng),
                    available: !wall(0.05, &rng), stageManager: wall(0.05, &rng),
                    pause: wall(0.1, &rng) ? "asleep" : nil,
                    rigPrefix: wall(0.3, &rng) ? "com.michaelv.swapless.rig.window.live." : nil,
                    dryRun: wall(0.1, &rng))
                if env.settings.status != .ok { env.settings.enabled = false }
                var out: [TrackerOutput] = []
                let roll = rng.uniform(0, 1)
                switch roll {
                case ..<0.25: out = t.trigger(p, chance(0.8, &rng) ? .destroyed : .deactivated, at: now)
                case ..<(benign ? 0.27 : 0.4): out = t.windowCreated(p, at: now)
                case ..<(benign ? 0.28 : 0.45): out = t.cancelAll(reason: "locked", at: now)
                default:
                    // Run the earliest due read with a random reading.
                    queue.sort { $0.1 < $1.1 }
                    if let (rp, at, pu) = queue.first {
                        queue.removeFirst()
                        now = max(now, at)
                        // Benign sequences mostly read a window at arming and none at decisions.
                        let opened = ["notes-open", "slack-open", "chrome-open"]
                        let gone = ["notes-closed", "slack-hidden", "chrome-closed"]
                        let name: String
                        if benign && chance(0.8, &rng) {
                            if case .arm = pu { name = pick(opened, &rng) } else { name = pick(gone, &rng) }
                        } else {
                            name = pick(names, &rng)
                        }
                        let r = QuitFixtures.reading(name)
                        var r2 = r
                        if chance(0.05, &rng) { r2.ax = nil }
                        if var f = facts[rp] {
                            f.hidden = wall(0.1, &rng)
                            facts[rp] = f
                            if case .settle = pu { closed[rp, default: []].formUnion(WindowVerdict.closedMarks(r2)) }
                            closed[rp, default: []].subtract(WindowVerdict.axIds(r2))
                            lastVerdict[rp] = WindowVerdict.evaluate(r2, closed: closed[rp] ?? [])
                            out = t.reading(rp, r2, facts: f, env: env, purpose: pu, at: now)
                            for o in out {
                                guard case let .terminate(tp, bundle, _) = o else { continue }
                                terminations += 1
                                let f = facts[tp]!
                                #expect(pu == .confirm)
                                #expect(bundle != "com.apple.finder")
                                #expect(!env.settings.neverQuitIds.contains(bundle))
                                #expect(env.settings.isActive && !env.observeOnly && env.historyOn && env.trusted)
                                #expect(env.available && !env.stageManager && env.pause == nil && !env.dryRun)
                                #expect(!f.hidden && f.finishedLaunching && now - f.launchTime >= QuitTiming.young)
                                #expect(f.regular || QuitGate.rigAdmits(bundle, prefix: env.rigPrefix))
                                if let pre = env.rigPrefix { #expect(bundle.hasPrefix(pre)) }
                                #expect(bundle != env.selfBundleId)
                                #expect(lastVerdict[tp]?.alive == 0 && lastVerdict[tp]?.error == nil)
                            }
                        }
                    }
                }
                for o in out { if case let .read(rp, at, pu) = o { queue.append((rp, at, pu)) } }
            }
        }
        // The generator must reach the terminate path often enough to mean something.
        #expect(terminations >= 150, "only \(terminations) terminations in 1,000 sequences")
    }
}
