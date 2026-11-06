import Foundation
import Testing
@testable import SwaplessCore

/// Local wall time → unix time, in an injected zone (never the system zone).
func localTs(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0, tz: TimeZone) -> Double {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!.timeIntervalSince1970
}

func actionRow(id: Int64 = 1, ts: Double, target: String = "wallpaper", before: Double = 1200, after: Double? = 150,
               outcome: String = "ok", dry: Bool = false, wsBefore: Double? = nil, wsAfter: Double? = nil) -> ActionRow {
    ActionRow(id: id, ts: ts, ruleId: "wallpaper-leak-guard", target: target, pids: [1], beforeMB: before,
              afterMB: after, outcome: outcome, dryRun: dry, wsBeforeMB: wsBefore, wsAfterMB: wsAfter)
}

@Suite("S3 · activity summary")
struct ActivityTests {
    let mx = TimeZone(identifier: "America/Mexico_City")!
    let chicago = TimeZone(identifier: "America/Chicago")!

    var now: Double { localTs(2026, 11, 6, 12, 0, tz: mx) }

    func sum(_ rows: [ActionRow], sampleDays: Set<String> = [], now: Double? = nil, tz: TimeZone? = nil) -> ActivitySummary {
        ActivitySummary.summarize(actions: rows, sampleDays: sampleDays, now: now ?? self.now, timeZone: tz ?? mx)
    }

    @Test func kindMapping() {
        #expect(ActivitySummary.kind(of: actionRow(ts: 0, target: "wallpaper")) == .restart)
        #expect(ActivitySummary.kind(of: actionRow(ts: 0, target: "rig-helper")) == .restart)
        #expect(ActivitySummary.kind(of: actionRow(ts: 0, target: "foo")) == nil)
        let s = sum([actionRow(ts: now - 60, target: "foo")])
        #expect(s.days[0].counts.isEmpty)
    }

    @Test func dryRunsAreIgnored() {
        let s = sum([actionRow(ts: now - 60, outcome: "dry-run", dry: true)])
        #expect(s.total == ActivityCounts())
    }

    @Test func everyOutcomeCountsAndFailedIsTheThree() {
        let outcomes = ["pending", "ok", "no-improvement", "agent-missing", "extension-missing", "interrupted", "signalled"]
        let rows = outcomes.enumerated().map { actionRow(id: Int64($0.offset), ts: now - 60, after: nil, outcome: $0.element) }
        let s = sum(rows)
        #expect(s.days[0].counts.count(.restart) == 7)
        #expect(s.days[0].counts.failed == 3)
        #expect(s.days[0].counts.freedMB == nil)
    }

    @Test func freedIsSignedWithWindowServer() {
        // The extension freed 100, WindowServer grew 300: −200.
        let r = actionRow(ts: now - 60, before: 300, after: 200, outcome: "no-improvement", wsBefore: 1000, wsAfter: 1300)
        #expect(ActivitySummary.freedMB(of: r) == -200)
        let s = sum([r])
        #expect(s.days[0].counts.freedMB == -200)   // unfloored in the struct
        #expect(s.total.freedMB == -200)
    }

    @Test func windowServerNilCountsTheExtensionOnly() {
        #expect(ActivitySummary.freedMB(of: actionRow(ts: 0, before: 1000, after: 100, wsBefore: 1500, wsAfter: nil)) == 900)
        #expect(ActivitySummary.freedMB(of: actionRow(ts: 0, before: 1000, after: 100, wsBefore: nil, wsAfter: 1200)) == 900)
    }

    @Test func pendingAndInterruptedFreeNothing() {
        #expect(ActivitySummary.freedMB(of: actionRow(ts: 0, after: nil, outcome: "pending")) == nil)
        #expect(ActivitySummary.freedMB(of: actionRow(ts: 0, after: 100, outcome: "interrupted")) == nil)
        #expect(ActivitySummary.freedMB(of: actionRow(ts: 0, before: 0, after: 0, outcome: "ok")) == nil)
    }

    /// DECISIONS.md 2026-11-05: the owner's two restarts.
    @Test func theOwnersTwoRestarts() {
        let rows = [
            actionRow(id: 1, ts: localTs(2026, 11, 5, 15, 36, tz: mx), before: 1258, after: 133, wsBefore: 1524, wsAfter: 1139),
            actionRow(id: 2, ts: localTs(2026, 11, 5, 16, 13, tz: mx), before: 1075.2, after: 148.1, wsBefore: 1495.5, wsAfter: 1081.5),
        ]
        let s = sum(rows, now: localTs(2026, 11, 5, 20, 0, tz: mx))
        #expect(s.days[0].counts.count(.restart) == 2)
        #expect(abs(s.days[0].counts.freedMB! - 2851.1) < 1e-6)
        #expect(MenuModel.activityBody(s.days[0].counts) == "2 restarts · 2.8 GB freed")
    }

    @Test func sevenDaysTodayFirst() {
        let s = sum([])
        #expect(s.days.count == 7)
        #expect(s.days.map(\.key) == ["2026-11-06", "2026-11-05", "2026-11-04", "2026-11-03", "2026-11-02", "2026-11-01", "2026-10-31"])
        #expect(s.days[3].weekday == 3)   // Tuesday
    }

    @Test func midnightSplitsDaysInMexicoCity() {
        let late = actionRow(id: 1, ts: localTs(2026, 11, 4, 23, 59, 59, tz: mx))
        let early = actionRow(id: 2, ts: localTs(2026, 11, 5, 0, 0, 0, tz: mx))
        let s = sum([late, early])
        #expect(s.days[1].counts.count(.restart) == 1)   // Nov 5
        #expect(s.days[2].counts.count(.restart) == 1)   // Nov 4
    }

    /// 2026-11-01 in Chicago is 25 h (DST ends).
    @Test func dstDayIs25Hours() {
        let now = localTs(2026, 11, 3, 12, 0, tz: chicago)
        let rows = [actionRow(id: 1, ts: localTs(2026, 11, 1, 0, 30, tz: chicago)),
                    actionRow(id: 2, ts: localTs(2026, 11, 1, 23, 30, tz: chicago))]
        let s = sum(rows, now: now, tz: chicago)
        #expect(s.days[2].key == "2026-11-01")
        #expect(s.days[2].counts.count(.restart) == 2)
        #expect(s.days[1].dayStart - s.days[2].dayStart == 25 * 3600)
        #expect(s.days[1].counts.isEmpty && s.days[3].counts.isEmpty)
    }

    @Test func futureAndOldRowsAreIgnored() {
        let rows = [actionRow(id: 1, ts: localTs(2026, 11, 7, 0, 0, 1, tz: mx)),
                    actionRow(id: 2, ts: localTs(2026, 10, 30, 23, 59, tz: mx)),
                    actionRow(id: 3, ts: localTs(2026, 10, 31, 0, 0, tz: mx))]
        let s = sum(rows)
        #expect(s.total.count(.restart) == 1)
        #expect(s.days[6].counts.count(.restart) == 1)
    }

    @Test func runningFromCoverageAndRows() {
        let s = sum([actionRow(ts: localTs(2026, 11, 3, 9, 0, tz: mx))], sampleDays: ["2026-11-05"])
        #expect(s.days[0].running)                     // today, always
        #expect(s.days[1].running)                     // samples
        #expect(!s.days[2].running)                    // nothing
        #expect(s.days[3].running)                     // a counted row
        #expect(!s.days[6].running)
        // A dry-run row alone doesn't make a day running.
        let d = sum([actionRow(ts: localTs(2026, 11, 4, 9, 0, tz: mx), outcome: "dry-run", dry: true)])
        #expect(!d.days[2].running)
    }

    @Test func totalIsTheSum() {
        let rows = [actionRow(id: 1, ts: localTs(2026, 11, 6, 9, 0, tz: mx), before: 1100, after: 100),
                    actionRow(id: 2, ts: localTs(2026, 11, 2, 9, 0, tz: mx), before: 1500, after: 500),
                    actionRow(id: 3, ts: localTs(2026, 11, 2, 10, 0, tz: mx), after: nil, outcome: "agent-missing")]
        let s = sum(rows)
        #expect(s.total.count(.restart) == 3)
        #expect(s.total.failed == 1)
        #expect(s.total.freedMB == 2000)
        #expect(MenuModel.activityBody(s.total) == "3 restarts (1 failed) · 2.0 GB freed")
    }

    @Test func activityLineFields() {
        let s = sum([actionRow(ts: now - 60, before: 1000, after: 1100, outcome: "no-improvement")], sampleDays: ["2026-11-05"])
        let j = JSON.object(ActivityState.summary(s).jsonFields).serialized
        #expect(j.hasPrefix(#"{"recorded":true,"reason":null,"days":[{"day":"2026-11-06","running":true,"restarts":1,"failed":1,"freedMB":-100},{"day":"2026-11-05","running":true,"restarts":0,"failed":0,"freedMB":null}"#))
        #expect(j.hasSuffix(#""total":{"restarts":1,"failed":1,"freedMB":-100}}"#))
        let off = JSON.object(ActivityState.notRecorded(reason: "history off").jsonFields).serialized
        #expect(off == #"{"recorded":false,"reason":"history off","days":[],"total":null}"#)
    }
}
