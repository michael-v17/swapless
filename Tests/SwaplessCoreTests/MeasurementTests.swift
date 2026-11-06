import CSwaplessProc
import Foundation
import Testing
@testable import SwaplessCore

@Suite("S1 · TopParser")
struct TopParserTests {
    @Test func realOutputPidMem() throws {
        let v = try TopParser.parse(Fixture.text("top-pid-mem.txt"))
        #expect(v.count > 500)
        // Every value parsed; kernel_task (pid 0) is listed.
        #expect(v[0] != nil)
    }

    @Test func realOutputWithCmprsHeaderVariant() throws {
        let v = try TopParser.parse(Fixture.text("top-pid-mem-cmprs.txt"))
        #expect(v.count > 500)
    }

    @Test func secondSampleWithTrailingSigns() throws {
        let text = Fixture.text("top-second-sample.txt")
        #expect(text.contains("+") || text.contains("-"))
        let v = try TopParser.parse(text)
        #expect(v.count > 500)
    }

    @Test func unitsArePowersOf1024() throws {
        #expect(TopParser.parseMem("305M") == 305 * 1_048_576)
        #expect(TopParser.parseMem("5936K") == 5936 * 1024)
        #expect(TopParser.parseMem("512B") == 512)
        #expect(TopParser.parseMem("10G") == 10 * 1_073_741_824)
        #expect(TopParser.parseMem("97M+") == 97 * 1_048_576)
        #expect(TopParser.parseMem("97M-") == 97 * 1_048_576)
        #expect(TopParser.parseMem("garbage") == nil)
    }

    @Test func headerIsFoundNotSkipped() throws {
        // A synthetic 10G row and a header that is not on a fixed line.
        let text = """
        Processes: 3 total
        some other header line
        another

        PID    MEM
        1      10G
        42     305M+
        7      5936K-
        """
        let v = try TopParser.parse(text)
        #expect(v[1] == 10 * 1_073_741_824)
        #expect(v[42] == 305 * 1_048_576)
        #expect(v[7] == 5936 * 1024)
    }

    @Test func noHeaderThrows() {
        #expect(throws: TopParser.ParseError.noHeader) { try TopParser.parse("Processes: 1\n1 2M\n") }
    }
}

@Suite("S1 · sw_decode_usage")
struct DecodeUsageTests {
    func buffer(eqos: UInt64 = 7, footprint: UInt64 = 123_456_789, started: UInt64 = 5,
                exited: UInt64 = 4, words: Int = 128) -> [UInt64] {
        var w = [UInt64](repeating: 0, count: words)
        w[0] = started
        w[1] = exited
        if words > 23 { w[23] = eqos }
        if words > 40 { w[40] = footprint }
        return w
    }

    @Test func readsOffset320() {
        let w = buffer()
        var fp: UInt64 = 0, st: UInt64 = 0, ex: UInt64 = 0
        let rc = w.withUnsafeBytes { sw_decode_usage($0.baseAddress, $0.count, &fp, &st, &ex) }
        #expect(rc == 0)
        #expect(fp == 123_456_789)
        #expect(st == 5)
        #expect(ex == 4)
        // Byte offset 320 is word 40.
        #expect(40 * 8 == 320)
    }

    @Test func driftWhenEqosLenIsNot7() {
        let w = buffer(eqos: 8)
        var fp: UInt64 = 0, st: UInt64 = 0, ex: UInt64 = 0
        let rc = w.withUnsafeBytes { sw_decode_usage($0.baseAddress, $0.count, &fp, &st, &ex) }
        #expect(rc == SW_ERR_LAYOUT_DRIFT)
    }

    @Test func shortBufferIsDrift() {
        let w = buffer(words: 40)  // 320 bytes: word 40 is missing
        var fp: UInt64 = 0, st: UInt64 = 0, ex: UInt64 = 0
        let rc = w.withUnsafeBytes { sw_decode_usage($0.baseAddress, $0.count, &fp, &st, &ex) }
        #expect(rc == SW_ERR_LAYOUT_DRIFT)
        let rc0 = sw_decode_usage(nil, 0, &fp, &st, &ex)
        #expect(rc0 == SW_ERR_LAYOUT_DRIFT)
    }

    @Test func exactly41WordsDecodes() {
        let w = buffer(words: 41)
        var fp: UInt64 = 0
        let rc = w.withUnsafeBytes { sw_decode_usage($0.baseAddress, $0.count, &fp, nil, nil) }
        #expect(rc == 0)
        #expect(fp == 123_456_789)
    }
}

@Suite("S1 · self-meter units")
struct SelfMeterTests {
    @Test func ticksTimes125Over3() {
        let s = SelfMeter.ticksToSeconds(47_941_393, numer: 125, denom: 3)
        #expect(abs(s - 1.998) < 0.001)
        // Read as nanoseconds it would undercount 41×.
        #expect(s / (47_941_393 / 1e9) > 41)
    }

    @Test func selfLineFormat() {
        let r = SelfReading(cpuSeconds: 1.23456, childCpuSeconds: 0.5, cpuPercent: 0.0123,
                            footprint: 21_000_000, peakFootprint: 25_000_000)
        #expect(SelfMeter.logLine(r, menuOpenSeconds: 12.34, displaySweeps: 0)
            == "self cpuSeconds=1.235 childCpuSeconds=0.500 cpuPct10m=0.012 footprint=21000000 peak=25000000 menuOpenSeconds=12.3 cpuPct10mIdle=none menuOpenCpuSeconds=0.000 displaySweeps=0")
    }

    /// Owner, 2026-11-05: ≤ 30 MiB before the menu is first shown, ≤ 40 MiB after.
    @Test func overBudgetFootprintLimitDependsOnTheMenu() {
        func r(_ mib: Double, cpu: Double = 0.1) -> SelfReading {
            SelfReading(cpuSeconds: 1, childCpuSeconds: 0, cpuPercent: cpu,
                        footprint: UInt64(mib * 1_048_576), peakFootprint: UInt64(mib * 1_048_576),
                        cpuPercentIdle: cpu)
        }
        #expect(!SelfMeter.overBudget(r(29.9), topMode: false, menuShown: false))
        #expect(SelfMeter.overBudget(r(30.1), topMode: false, menuShown: false))
        #expect(!SelfMeter.overBudget(r(34.4), topMode: false, menuShown: true))
        #expect(!SelfMeter.overBudget(r(39.9), topMode: false, menuShown: true))
        #expect(SelfMeter.overBudget(r(40.1), topMode: false, menuShown: true))
        #expect(SelfMeter.overBudget(r(20, cpu: 0.25), topMode: false, menuShown: true))   // idle CPU over
        #expect(!SelfMeter.overBudget(r(20, cpu: 0.25), topMode: true, menuShown: false))
    }

    @Test func swapinRateUses16KiBUnits() {
        #expect(SystemMemory.swapinRate(previous: nil, previousUptime: nil, current: 10, uptime: 1) == nil)
        let r = SystemMemory.swapinRate(previous: 100, previousUptime: 10, current: 110, uptime: 20)
        #expect(r == 16384)
    }
}

@Suite("S1 · self-check")
struct SelfCheckTests {
    /// 12 single-member same-user coalitions, WindowServer in a system coalition.
    func entries() -> [ProcessSample] {
        var e: [ProcessSample] = []
        for i in 0..<12 {
            e.append(proc(Int32(100 + i), coalition: UInt64(1000 + i), footprintMB: Double(10 + i)))
        }
        e.append(proc(88, euid: 88, path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
                      coalition: 381))
        e.append(proc(89, euid: 0, name: "MTLCompilerService", coalition: 381))
        return e
    }

    func probe(coalitionOffset: Int64 = 0, wsRC: Int32 = 0, wsMB: UInt64 = 1186,
               symbols: Int32 = 3) -> SelfCheckProbe {
        SelfCheckProbe(
            coalitionUsage: { cid in
                if cid == 381 { return (wsRC, wsMB * 1_048_576, 2, 0) }
                let fp = UInt64(Int64((10 + Int(cid) - 1000)) * 1_048_576 + coalitionOffset)
                return (0, fp, 1, 0)
            },
            rusageFootprint: { pid in UInt64((10 + Int(pid) - 100) * 1_048_576) },
            responsiblePid: { $0 },
            symbols: { symbols })
    }

    @Test func passes() {
        let r = SelfCheck.run(entries: entries(), ownUid: 501, ownPid: 100, probe: probe())
        #expect(r.coalition == .pass)
        #expect(r.checked == 10)
        #expect(r.passed == 10)
        #expect(r.windowServer == .pass)
        #expect(r.responsibility == .pass)
    }

    @Test func failsWhenCoalitionDisagreesWithRusage() {
        let r = SelfCheck.run(entries: entries(), ownUid: 501, ownPid: 100, probe: probe(coalitionOffset: 4096))
        #expect(r.coalition == .fail)
        #expect(r.passed == 0)
    }

    @Test func failsOnWindowServerB() {
        let r1 = SelfCheck.run(entries: entries(), ownUid: 501, ownPid: 100, probe: probe(wsRC: -1))
        #expect(r1.windowServer == .fail)
        #expect(r1.coalition == .fail)
        let r2 = SelfCheck.run(entries: entries(), ownUid: 501, ownPid: 100, probe: probe(wsMB: 10))
        #expect(r2.windowServer == .fail)
        #expect(r2.coalition == .fail)
    }

    @Test func missingSymbol() {
        let r = SelfCheck.run(entries: entries(), ownUid: 501, ownPid: 100, probe: probe(symbols: 2))
        #expect(r.coalition == .missing)
        #expect(r.windowServer == .missing)
        #expect(r.checked == 0)
        let r2 = SelfCheck.run(entries: entries(), ownUid: 501, ownPid: 100, probe: probe(symbols: 1))
        #expect(r2.responsibility == .missing)
    }

    @Test func driftFails() {
        let p = SelfCheckProbe(coalitionUsage: { _ in (SW_ERR_LAYOUT_DRIFT, 0, 0, 0) },
                               rusageFootprint: { _ in 1 }, responsiblePid: { $0 }, symbols: { 3 })
        let r = SelfCheck.run(entries: entries(), ownUid: 501, ownPid: 100, probe: p)
        #expect(r.coalition == .fail)
    }

    @Test func tooFewCandidatesFails() {
        let few = Array(entries().prefix(4)) + entries().suffix(2)
        let r = SelfCheck.run(entries: few, ownUid: 501, ownPid: 100, probe: probe())
        #expect(r.checked == 4)
        #expect(r.coalition == .fail)
    }

    @Test func skippedReportsZeroes() {
        let r = SelfCheck.skipped(probe: probe(), ownPid: 100)
        #expect(r.coalition == .skipped)
        #expect(r.windowServer == .skipped)
        #expect(r.checked == 0 && r.passed == 0)
    }
}

@Suite("S1 · totals by source")
struct TotalsTests {
    @Test func coalitionSourceUsesCoalitionFootprint() {
        let s = snapshot([
            proc(10, coalition: 5, footprintMB: 100),
            proc(11, euid: 0, coalition: 5),  // transient setuid child, unreadable
        ], coalitions: [5: 130])
        let g = Grouper(labeler: Labeler()).group(s)
        #expect(g.count == 1)
        #expect(g[0].footprint == 130 * MB)
        #expect(g[0].unreadableCount == 1)
        #expect(g[0].unreadableBytes == 30 * MB)
    }

    @Test func topSourceSumsMembersAndSkipsMissing() {
        let s = snapshot([
            proc(10, coalition: 5, footprintMB: 100),
            proc(11, euid: 0, coalition: 5, footprintMB: 40, readable: false),  // top value
            proc(12, euid: 0, coalition: 5),  // absent from the last top run
        ], source: .top)
        let g = Grouper(labeler: Labeler()).group(s)
        #expect(g[0].footprint == 140 * MB)
    }

    @Test func noneSourceSystemGroupIsNull() {
        let s = snapshot([
            proc(20, euid: 0, coalition: 9),
            proc(10, coalition: 5, footprintMB: 100),
        ], source: .none)
        let g = Grouper(labeler: Labeler()).group(s)
        #expect(g.count == 2)
        #expect(g[0].footprint == 100 * MB)
        #expect(g[1].footprint == nil)  // sorts last
        #expect(g[1].kind == .system)
    }
}
