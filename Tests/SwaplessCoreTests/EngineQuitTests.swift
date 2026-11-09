import Foundation
import Testing
@testable import SwaplessCore

/// v1-quit-on-close S3: the engine side of a quit (rows, outcomes, settings by mtime) and the
/// rig prefix seam.
@Suite("Quit · engine and config")
struct EngineQuitTests {
    struct NoSignals: SignalSender {
        func sigterm(pid: Int32, target: RestartTarget) -> SignalResult { .refused("test") }
    }

    func engine(_ dir: URL, rules: String, env: [String: String] = [:]) throws -> Engine {
        try Data(rules.utf8).write(to: RulesFile.url(in: dir))
        var e = env
        e["SWAPLESS_STATE_DIR"] = dir.path
        let cfg = try Config.load(env: e, defaultStateDir: dir.appendingPathComponent("default"),
                                  flavour: Flavour(isRelease: false, mode: .headless)).get()
        return Engine(config: cfg, sink: EventSink(jsonTypes: []), labeler: Labeler(), signalSender: NoSignals())
    }

    let v2On = #"{"version":2,"rules":[],"quitOnLastWindow":{"enabled":true},"apps":[]}"#

    @Test func aQuitRowAndItsOutcomeAreWrittenAndReadBack() throws {
        let dir = makeTempDir()
        let e = try engine(dir, rules: v2On)
        e.prepareForTests()
        let now = Date().timeIntervalSince1970
        let id = try #require(e.recordQuit(pid: 4242, bundleId: "com.apple.Notes", name: "Notes", beforeMB: 312,
                                           dryRun: false, at: now))
        e.updateQuitOutcome(id: id, outcome: "ok")
        let st = e.stateForTests  // after the async outcome (same queue)
        #expect(st.quit.lastQuit == QuitActionDisplay(ts: now, bundleId: "com.apple.Notes", name: "Notes",
                                                      beforeMB: 312, outcome: "ok"))
        if case .summary(let s) = st.activity {
            #expect(s.days[0].counts.count(.quit) == 1)
            #expect(s.days[0].counts.freedMB == 312)
        } else {
            Issue.record("activity not recorded")
        }
        let h = HistoryStore(stateDir: dir, currentRuleIds: [], now: now)
        let rows = h.actions(since: now - 60)
        #expect(rows.count == 1)
        #expect(rows.first?.ruleId == "quit-on-last-window")
        #expect(rows.first?.target == "com.apple.Notes")
        #expect(rows.first?.pids == [4242])
        #expect(rows.first?.outcome == "ok")
        #expect(rows.first?.afterMB == nil)
    }

    @Test func aDryRunRowIsNotCountedAndNotTheLastQuit() throws {
        let dir = makeTempDir()
        let e = try engine(dir, rules: v2On)
        e.prepareForTests()
        _ = e.recordQuit(pid: 1, bundleId: "com.x", name: "X", beforeMB: 10, dryRun: true, at: Date().timeIntervalSince1970)
        let st = e.stateForTests
        #expect(st.quit.lastQuit == nil)
        if case .summary(let s) = st.activity { #expect(s.days[0].counts.count(.quit) == 0) }
    }

    @Test func theWallpaperRowsIgnoreQuitRows() throws {
        let dir = makeTempDir()
        let now = Date().timeIntervalSince1970
        let h = HistoryStore(stateDir: dir, currentRuleIds: [], now: now)
        let restart = try #require(h.insertAction(ts: now - 100, ruleId: "wallpaper-leak-guard", target: "wallpaper",
                                                  pids: [1], beforeMB: 1100, outcome: "ok", dryRun: false))
        _ = h.insertAction(ts: now - 10, ruleId: "quit-on-last-window", target: "com.apple.Notes", pids: [2],
                           beforeMB: 300, outcome: "ok", dryRun: false)
        h.close()
        let e = try engine(dir, rules: "{\"version\":1,\"rules\":[\(wallRule())]}")
        e.prepareForTests()
        let r = e.oneShot()
        #expect(r.state.ruleDisplays.first?.lastAction?.id == restart)
        #expect(r.state.quit.lastQuit?.bundleId == "com.apple.Notes")
    }

    @Test func currentQuitViewPicksUpAnEditByMtime() throws {
        let dir = makeTempDir()
        let e = try engine(dir, rules: v2On.replacingOccurrences(of: "true", with: "false"))
        e.prepareForTests()
        #expect(e.currentQuitView().settings.enabled == false)
        Thread.sleep(forTimeInterval: 0.02)
        try Data(v2On.utf8).write(to: RulesFile.url(in: dir))
        let v = e.currentQuitView()
        #expect(v.settings.enabled)
        #expect(v.settings.isActive)
        #expect(v.historyOn)
    }

    @Test func printMenuSaysNotWatched() throws {
        let dir = makeTempDir()
        let e = try engine(dir, rules: v2On)
        let r = e.oneShot()
        #expect(r.state.quit.paused == "not watched by --print-menu")
    }

    @Test func pausedReasonOrder() {
        let on = QuitSettings(status: .ok, enabled: true, apps: [])
        let w = WatcherStatus(trusted: false, available: false, unavailableReason: "x", stageManager: true, tracked: 1, armed: 1)
        #expect(QuitDisplay.pausedReason(settings: .invalid("x"), oneShot: false, observeOnly: true, historyOn: false, watcher: w) == "rules.json invalid")
        #expect(QuitDisplay.pausedReason(settings: on, oneShot: true, observeOnly: true, historyOn: false, watcher: w) == "not watched by --print-menu")
        #expect(QuitDisplay.pausedReason(settings: on, oneShot: false, observeOnly: true, historyOn: false, watcher: w) == "another Swapless is acting")
        #expect(QuitDisplay.pausedReason(settings: on, oneShot: false, observeOnly: false, historyOn: false, watcher: w) == "history off")
        #expect(QuitDisplay.pausedReason(settings: on, oneShot: false, observeOnly: false, historyOn: true, watcher: w) == "needs Accessibility")
        var w2 = w
        w2.trusted = true
        #expect(QuitDisplay.pausedReason(settings: on, oneShot: false, observeOnly: false, historyOn: true, watcher: w2) == "unavailable on this macOS")
        w2.available = true
        #expect(QuitDisplay.pausedReason(settings: on, oneShot: false, observeOnly: false, historyOn: true, watcher: w2) == "Stage Manager is on")
        w2.stageManager = false
        #expect(QuitDisplay.pausedReason(settings: on, oneShot: false, observeOnly: false, historyOn: true, watcher: w2) == nil)
        #expect(QuitDisplay.pausedReason(settings: on, oneShot: false, observeOnly: false, historyOn: true, watcher: nil) == nil)
    }

    // MARK: the rig prefix seam (S6)

    func load(_ env: [String: String]) -> Result<Config, ConfigError> {
        let root = makeTempDir()
        var e = env
        e["SWAPLESS_STATE_DIR"] = root.appendingPathComponent("s").path
        return Config.load(env: e, defaultStateDir: root.appendingPathComponent("default"),
                           flavour: Flavour(isRelease: true, mode: .headless), cwd: root.path)
    }

    @Test func rigPrefixSeam() throws {
        #expect(try load([:]).get().rigQuitBundlePrefix == nil)
        #expect(try load(["SWAPLESS_RIG_QUIT_BUNDLE_PREFIX": "com.michaelv.swapless.rig.window.live."]).get()
            .rigQuitBundlePrefix == "com.michaelv.swapless.rig.window.live.")
        #expect(throws: ConfigError.self) { try load(["SWAPLESS_RIG_QUIT_BUNDLE_PREFIX": "com.apple."]).get() }
        #expect(throws: ConfigError.self) { try load(["SWAPLESS_RIG_QUIT_BUNDLE_PREFIX": "com.michaelv.swapless.rig."]).get() }
        #expect(throws: ConfigError.self) { try load(["SWAPLESS_RIG_QUIT_BUNDLE_PREFIX": ""]).get() }
    }
}
