import Foundation
import Testing
@testable import SwaplessCore

/// v1-quit-on-close S5: the quit rows of the menu.
@Suite("Quit · menu rows")
struct QuitMenuTests {
    let now = 1_800_000_000.0  // 08:00 UTC
    let utc = TimeZone(identifier: "UTC")!

    func load(enabled: Bool, apps: String = "[]") -> RulesLoad {
        RulesFile.decode(Data(#"{"version":2,"rules":[\#(wallRule())],"quitOnLastWindow":{"enabled":\#(enabled)},"apps":\#(apps)}"#.utf8),
                         allowedTargets: ["wallpaper"])
    }

    func state(_ rules: RulesLoad, paused: String? = nil, watching: Int = 2, last: QuitActionDisplay? = nil,
               observeOnly: Bool = false) -> EngineState {
        var st = EngineState()
        st.rules = rules
        st.observeOnly = observeOnly
        st.quit = QuitDisplay(settings: rules.quit, paused: paused, watching: watching, lastQuit: last)
        return st
    }

    func rows(_ st: EngineState, running: [RunningApp] = []) -> [MenuItem] {
        MenuModel.quitRows(MenuInput(state: st, now: now, timeZone: utc, runningApps: running))
    }

    func titles(_ items: [MenuItem]) -> [String] { items.filter { !$0.isSeparator }.map(\.title) }

    func last(_ outcome: String, bundle: String = "com.apple.Notes") -> QuitActionDisplay {
        QuitActionDisplay(ts: now - 60, bundleId: bundle, name: "Notes", beforeMB: 312, outcome: outcome)
    }

    @Test func offShowsTheToggleAndTheListOnly() {
        let r = rows(state(load(enabled: false)))
        #expect(r.first?.isSeparator == true)
        #expect(r.first?.slot == "sep.quit")
        #expect(titles(r) == ["Quit apps when their last window closes", "Never quit"])
        let toggle = r.first { $0.slot == "quit.toggle" }
        #expect(toggle?.checked == false)
        #expect(toggle?.enabled == true)
        #expect(toggle?.action == .toggleQuitOnClose)
    }

    @Test func statusPerState() {
        let on = load(enabled: true)
        func status(_ st: EngineState) -> [String] { Array(titles(rows(st)).dropFirst().dropLast()) }
        #expect(status(state(on, watching: 1)) == ["Watching 1 app"])
        #expect(status(state(on, watching: 3)) == ["Watching 3 apps"])
        #expect(status(state(on, last: last("pending"))) == ["Quitting Notes…"])
        // 1_800_000_000 − 60 s = 07:59 UTC.
        #expect(status(state(on, last: last("ok"))) == ["Last quit 07:59: Notes · 312 MB", "Never quit Notes"])
        #expect(status(state(on, last: last("refused"))) == ["07:59: Notes didn't quit · left open", "Never quit Notes"])
        #expect(status(state(on, last: last("not-sent"))) == ["07:59: Notes couldn't be asked to quit"])
        // Any other outcome (interrupted) falls through to Watching.
        #expect(status(state(on, watching: 2, last: last("interrupted"))) == ["Watching 2 apps"])
        for p in ["unavailable on this macOS", "Stage Manager is on", "another Swapless is acting", "history off",
                  "not watched by --print-menu"] {
            #expect(status(state(on, paused: p, last: last("ok"))) == ["Paused: \(p)"])
        }
        #expect(status(state(on, paused: "needs Accessibility")) == ["Paused: needs Accessibility", "Open Accessibility settings…"])
        let acc = rows(state(on, paused: "needs Accessibility")).first { $0.slot == "quit.accessibility" }
        #expect(acc?.action == .openAccessibilitySettings)
        #expect(acc?.enabled == true)
    }

    @Test func theNeverQuitOfferOnlyForUnprotectedApps() {
        let protected = load(enabled: true, apps: #"[{"bundleId":"com.apple.Notes","name":"Notes","neverQuit":true}]"#)
        #expect(!titles(rows(state(protected, last: last("ok")))).contains("Never quit Notes"))
        #expect(!titles(rows(state(load(enabled: true), last: last("ok", bundle: "com.apple.finder")))).contains("Never quit Notes"))
        let offer = rows(state(load(enabled: true), last: last("ok"))).first { $0.slot == "quit.never.offer" }
        #expect(offer?.action == .addNeverQuit("com.apple.Notes", "Notes"))
    }

    @Test func theNeverQuitSubmenu() {
        let apps = #"[{"bundleId":"com.z","name":"zed","neverQuit":true},{"bundleId":"com.a","name":"Alpha","neverQuit":true},{"bundleId":"com.k","name":"Kept","neverQuit":false}]"#
        let running = [RunningApp(bundleId: "com.apple.finder", name: "Finder"), RunningApp(bundleId: "com.a", name: "Alpha"),
                       RunningApp(bundleId: "com.tinyspeck.slackmacgap", name: "Slack"), RunningApp(bundleId: "com.apple.Notes", name: "Notes"),
                       RunningApp(bundleId: "com.k", name: "Kept")]
        let menu = rows(state(load(enabled: false, apps: apps)), running: running).first { $0.slot == "quit.never" }
        let kids = menu?.children ?? []
        #expect(titles(kids) == ["Finder (always)", "Alpha", "zed", "Add running app"])
        #expect(kids.first?.enabled == false && kids.first?.checked == true)
        #expect(kids.first { $0.title == "Alpha" }?.action == .removeNeverQuit("com.a"))
        #expect(kids.first { $0.title == "Alpha" }?.checked == true)
        let add = kids.first { $0.slot == "quit.add" }?.children ?? []
        // Not Finder, not the protected ones; an entry with neverQuit false can still be added.
        #expect(titles(add) == ["Kept", "Notes", "Slack"])
        #expect(add.first { $0.title == "Notes" }?.action == .addNeverQuit("com.apple.Notes", "Notes"))
        let none = rows(state(load(enabled: false))).first { $0.slot == "quit.never" }?.children?
            .first { $0.slot == "quit.add" }?.children ?? []
        #expect(titles(none) == ["No other apps running"])
        #expect(none.first?.enabled == false)
    }

    @Test func invalidAndObserveOnlyDisableTheWrites() {
        let bad = load(enabled: true, apps: #"[{"bundleId":"a","name":"A"}]"#)
        let r = rows(state(bad, paused: "rules.json invalid"), running: [RunningApp(bundleId: "com.x", name: "X")])
        #expect(titles(r) == ["Quit apps when their last window closes", "Paused: rules.json invalid",
                              "rules.json: apps[0]: missing key 'neverQuit'", "Never quit"])
        #expect(r.first { $0.slot == "quit.toggle" }?.enabled == false)
        let add = r.first { $0.slot == "quit.never" }?.children?.first { $0.slot == "quit.add" }?.children ?? []
        #expect(add.allSatisfy { !$0.enabled })
        let obs = rows(state(load(enabled: true, apps: #"[{"bundleId":"com.a","name":"A","neverQuit":true}]"#), observeOnly: true))
        #expect(obs.first { $0.slot == "quit.toggle" }?.enabled == false)
        #expect(obs.first { $0.slot == "quit.never" }?.children?.first { $0.title == "A" }?.enabled == false)
    }

    @Test func rowOrderInTheRulesSection() {
        var st = state(load(enabled: false))
        st.rules = RulesFile.decode(Data("{nope".utf8), allowedTargets: ["wallpaper"])
        let items = MenuModel.rulesSection(MenuInput(state: st, now: now, timeZone: utc))
        let slots = items.map(\.slot)
        let sep = slots.firstIndex(of: "sep.quit") ?? -1
        let err = slots.firstIndex(of: "rule.error.file") ?? -1
        #expect(sep > slots.firstIndex(of: "rule.none")!)
        #expect(sep < err)
    }

    @Test func todayStringsWithQuits() {
        #expect(MenuModel.activityBody(ActivityCounts(byKind: [.restart: 2, .quit: 3], failed: 1, freedMB: 4198))
            == "2 restarts (1 failed) · 3 quits · 4.1 GB freed")
        #expect(MenuModel.activityBody(ActivityCounts(byKind: [.quit: 3], freedMB: 912)) == "3 quits · 912 MB freed")
        #expect(MenuModel.activityBody(ActivityCounts(byKind: [.restart: 1], freedMB: 2867)) == "1 restart · 2.8 GB freed")
        #expect(MenuModel.activityBody(ActivityCounts()) == "no restarts or quits")
    }
}

/// v1-quit-on-close S4 / T10: quits in the activity summary.
@Suite("Quit · activity")
struct QuitActivityTests {
    let utc = TimeZone(identifier: "UTC")!
    let now = 1_800_000_000.0

    func row(_ id: Int64, rule: String = "quit-on-last-window", target: String = "com.apple.Notes", outcome: String,
             before: Double, after: Double? = nil, ws: (Double, Double)? = nil, dry: Bool = false) -> ActionRow {
        ActionRow(id: id, ts: now - 3600, ruleId: rule, target: target, pids: [1], beforeMB: before, afterMB: after,
                  outcome: outcome, dryRun: dry, wsBeforeMB: ws?.0, wsAfterMB: ws?.1)
    }

    @Test func kindByRuleIdWhateverTheTarget() {
        #expect(ActivitySummary.kind(of: row(1, target: "wallpaper", outcome: "ok", before: 1)) == .quit)
        #expect(ActivitySummary.kind(of: row(1, rule: "wallpaper-leak-guard", target: "wallpaper", outcome: "ok", before: 1)) == .restart)
        #expect(ActivitySummary.kind(of: row(1, rule: "other", target: "com.x", outcome: "ok", before: 1)) == nil)
    }

    @Test func onlyOkQuitsCountAndFree() {
        let rows = [row(1, outcome: "ok", before: 300), row(2, outcome: "refused", before: 500),
                    row(3, outcome: "not-sent", before: 500), row(4, outcome: "pending", before: 500),
                    row(5, outcome: "interrupted", before: 500), row(6, outcome: "dry-run", before: 500, dry: true),
                    row(7, outcome: "ok", before: 0)]
        let s = ActivitySummary.summarize(actions: rows, sampleDays: [], now: now, timeZone: utc)
        #expect(s.days[0].counts.count(.quit) == 2)
        #expect(s.days[0].counts.failed == 0)
        #expect(s.days[0].counts.freedMB == 300)
    }

    @Test func aDayWithARestartAndTwoQuits() {
        let rows = [row(1, rule: "wallpaper-leak-guard", target: "wallpaper", outcome: "ok", before: 2851.1 + 100,
                        after: 100, ws: (0, 0)),
                    row(2, outcome: "ok", before: 300), row(3, target: "com.tinyspeck.slackmacgap", outcome: "ok", before: 612)]
        let s = ActivitySummary.summarize(actions: rows, sampleDays: [], now: now, timeZone: utc)
        #expect(abs((s.days[0].counts.freedMB ?? 0) - 3763.1) < 1e-6)
        #expect(MenuModel.activityBody(s.days[0].counts) == "1 restart · 2 quits · 3.7 GB freed")
        #expect(MenuModel.activityBody(s.total) == "1 restart · 2 quits · 3.7 GB freed")
        let fields = ActivityState.summary(s).jsonFields
        let total = fields.first { $0.0 == "total" }?.1.serialized ?? ""
        #expect(total.hasPrefix(#"{"restarts":1,"quits":2,"failed":0,"freedMB":3763."#))
    }
}
