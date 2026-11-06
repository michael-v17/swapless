import Foundation
import Testing
@testable import SwaplessCore

/// v1-menu-today S1 / T6: the menu-closed ("idle") CPU figure and the open-menu CPU.
@Suite("S1 · self meter: idle CPU")
struct SelfMeterIdleTests {
    typealias Iv = SelfMeter.Interval

    @Test func allClosedIsExact() {
        let ivs: [Iv] = Array(repeating: (30, 0.03, false), count: 20)   // 600 s, 0.6 s CPU
        let p = try! #require(SelfMeter.idlePercent(ivs))
        #expect(abs(p - 0.1) < 1e-9)
    }

    @Test func openIntervalInTheMiddleIsExcluded() {
        var ivs: [Iv] = Array(repeating: (30, 0.03, false), count: 5)
        ivs.append((60, 3.6, true))   // 6 % while open
        ivs += Array(repeating: (30, 0.03, false), count: 5)
        let p = try! #require(SelfMeter.idlePercent(ivs))
        #expect(abs(p - 0.1) < 1e-9)
    }

    @Test func theCrossingIntervalIsIncludedWhole() {
        // Newest last: 590 s closed at 0.1 %, then (older) a 100 s interval at 1 %.
        var ivs: [Iv] = [(100, 1.0, false)]
        ivs += Array(repeating: (59, 0.059, false), count: 10)
        let p = try! #require(SelfMeter.idlePercent(ivs))
        #expect(abs(p - (0.59 + 1.0) / 690 * 100) < 1e-9)
        // An even older interval is not reached.
        let p2 = try! #require(SelfMeter.idlePercent([(1000, 100, false)] + ivs))
        #expect(abs(p2 - p) < 1e-12)
    }

    @Test func lessThan60sClosedIsNil() {
        #expect(SelfMeter.idlePercent([(59.9, 0.1, false)]) == nil)
        #expect(SelfMeter.idlePercent([(30, 0.1, false), (500, 5, true), (29, 0.1, false)]) == nil)
        #expect(SelfMeter.idlePercent([(60, 0.06, false)]) != nil)
    }

    @Test func onlyOpenIntervalsIsNil() {
        #expect(SelfMeter.idlePercent([(600, 30, true), (300, 10, true)]) == nil)
        #expect(SelfMeter.idlePercent([]) == nil)
    }

    @Test func closedTimeBeforeA15MinOpenSessionCounts() {
        var ivs: [Iv] = Array(repeating: (30, 0.03, false), count: 10)   // 300 s at 0.1 %
        ivs.append((900, 54, true))                                       // 15 min open at 6 %
        let p = try! #require(SelfMeter.idlePercent(ivs))
        #expect(abs(p - 0.1) < 1e-9)
    }

    // MARK: record(…)

    func feed(_ m: SelfMeter, _ steps: [(dt: Double, dcpu: Double, open: Bool)], start: Double = 1000,
              cpu0: Double = 10) -> SelfReading {
        var t = start
        var c = cpu0
        var r = m.record(uptime: t, cpuTotal: c, footprint: 1, peak: 1, menuOpenDuringInterval: false)
        for s in steps {
            t += s.dt
            c += s.dcpu
            r = m.record(uptime: t, cpuTotal: c, footprint: 1, peak: 1, menuOpenDuringInterval: s.open)
        }
        return r
    }

    @Test func recordComputesIdleAndOpenCpu() {
        let m = SelfMeter()
        var steps: [(dt: Double, dcpu: Double, open: Bool)] = Array(repeating: (30, 0.03, false), count: 10)
        steps.append((10, 0.5, true))
        steps.append((5, 0.25, true))
        steps.append((15, 0.015, false))
        steps += Array(repeating: (30, 0.03, false), count: 10)
        let r = feed(m, steps)
        #expect(abs(r.menuOpenCpuSeconds - 0.75) < 1e-9)
        #expect(abs(r.cpuPercentIdle! - 0.1) < 1e-9)
        // The all-time rolling figure still includes the open time.
        #expect(r.cpuPercent > 0.1)
    }

    @Test func idleIsNilUntil60sClosed() {
        let m = SelfMeter()
        #expect(feed(m, [(30, 0.03, false)]).cpuPercentIdle == nil)
        let m2 = SelfMeter()
        #expect(feed(m2, [(30, 0.03, false), (30, 0.03, false)]).cpuPercentIdle != nil)
    }

    @Test func menuOpenCpuSecondsSumsOpenIntervalsOnly() {
        let m = SelfMeter()
        let r = feed(m, [(30, 1, false), (5, 0.2, true), (30, 1, false), (5, 0.3, true), (5, 0.1, true)])
        #expect(abs(r.menuOpenCpuSeconds - 0.6) < 1e-9)
    }

    @Test func trimmingKeepsTheWindowAndStaysBounded() {
        let m = SelfMeter()
        // 2 h closed at 1 %, then 10 min at 0.1 %: only the last 600 s count.
        var steps: [(dt: Double, dcpu: Double, open: Bool)] = Array(repeating: (30, 0.3, false), count: 240)
        steps += Array(repeating: (30, 0.03, false), count: 20)
        let r = feed(m, steps)
        #expect(abs(r.cpuPercentIdle! - 0.1) < 1e-9)
        // A 2 h open session: merged into one interval, and the closed time before it still counts.
        let r2 = feed(m, Array(repeating: (30, 1.8, true), count: 240), start: 1000 + 260 * 30, cpu0: 10 + 72 + 0.6)
        #expect(abs(r2.cpuPercentIdle! - 0.1) < 1e-9)
    }

    // MARK: overBudget (the flag stays computed in Engine.publish)

    func reading(idle: Double?, cpu: Double = 0.1, mib: Double = 20) -> SelfReading {
        SelfReading(cpuSeconds: 1, childCpuSeconds: 0, cpuPercent: cpu, footprint: UInt64(mib * 1_048_576),
                    peakFootprint: UInt64(mib * 1_048_576), cpuPercentIdle: idle)
    }

    @Test func overBudgetUsesIdleCPU() {
        #expect(SelfMeter.overBudget(reading(idle: 0.25), topMode: false, menuShown: true))
        #expect(!SelfMeter.overBudget(reading(idle: 0.1, cpu: 0.5), topMode: false, menuShown: true))
        #expect(!SelfMeter.overBudget(reading(idle: nil, cpu: 5), topMode: false, menuShown: true))
        #expect(!SelfMeter.overBudget(reading(idle: 0.5), topMode: true, menuShown: true))
        #expect(SelfMeter.overBudget(reading(idle: 0.7), topMode: true, menuShown: true))
        // Footprint split unchanged.
        #expect(SelfMeter.overBudget(reading(idle: nil, mib: 30.1), topMode: false, menuShown: false))
        #expect(!SelfMeter.overBudget(reading(idle: nil, mib: 39.9), topMode: false, menuShown: true))
        #expect(SelfMeter.overBudget(reading(idle: nil, mib: 40.1), topMode: false, menuShown: true))
    }

    @Test func selfLineAppendsTheNewFields() {
        var r = reading(idle: 0.1234)
        r.menuOpenCpuSeconds = 1.5
        #expect(SelfMeter.logLine(r, menuOpenSeconds: 98, displaySweeps: 31)
            == "self cpuSeconds=1.000 childCpuSeconds=0.000 cpuPct10m=0.100 footprint=20971520 peak=20971520 menuOpenSeconds=98.0 cpuPct10mIdle=0.123 menuOpenCpuSeconds=1.500 displaySweeps=31")
        r.cpuPercentIdle = nil
        #expect(SelfMeter.logLine(r, menuOpenSeconds: 0, displaySweeps: 0).hasSuffix(" cpuPct10mIdle=none menuOpenCpuSeconds=1.500 displaySweeps=0"))
    }

    @Test func sampleJSONCarriesTheNewKeys() {
        let j = reading(idle: nil).json.serialized
        #expect(j.contains("\"cpuPercentIdle\":null"))
        #expect(j.contains("\"menuOpenCpuSeconds\":0"))
    }
}
