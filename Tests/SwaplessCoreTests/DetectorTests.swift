import Foundation
import Testing
@testable import SwaplessCore

/// S3 · the § H detector on synthetic series (30 s base ticks, defaults, 16 GiB).
@Suite("S3 · leak detector")
struct DetectorTests {
    static let gib16: UInt64 = 16 << 30
    static let tick = 30.0
    /// A wall time on a 300 s bucket boundary.
    static let t0 = 1_800_000_000.0

    func obs(_ key: String = "proc:42:1.000000", mb: Double, lifetimeMax: UInt64? = nil) -> SeriesObservation {
        SeriesObservation(key: key, kind: "process", pid: 42, label: "WallpaperImageExtension",
                          path: RestartTarget.wallpaperExtensionPath, groupLabel: "WallpaperImageExtension",
                          footprint: UInt64(max(0, mb) * 1_048_576), lifetimeMax: lifetimeMax)
    }

    /// Runs `value(seconds since start)` every 30 s for `hours`; returns flag/unflag events.
    func run(hours: Double, start: Double = t0, detector: inout LeakDetector,
             value: (Double) -> Double) -> [(t: Double, event: DetectorEvent)] {
        var out: [(Double, DetectorEvent)] = []
        var s = 0.0
        while s <= hours * 3600 {
            let t = start + s
            for e in detector.tick(t: t, observations: [obs(mb: value(s))]) {
                switch e {
                case .flag, .unflag: out.append((t, e))
                case .bucketClosed: break
                }
            }
            s += Self.tick
        }
        return out
    }

    func firstFlag(_ events: [(t: Double, event: DetectorEvent)]) -> (t: Double, FlagEvent)? {
        for (t, e) in events {
            if case .flag(let f) = e { return (t, f) }
        }
        return nil
    }

    @Test func wallpaperSeriesFlagsBetween2h45And3h15ForEachOf50Seeds() {
        for seed in 1...50 {
            var rng = SplitMix64(seed: UInt64(seed))
            var d = LeakDetector(config: .defaults, hwMemsize: Self.gib16)
            let events = run(hours: 6, detector: &d) { s in
                110 + 145 * s / 3600 + rng.uniform(-20, 20)
            }
            let f = firstFlag(events)
            #expect(f != nil, "seed \(seed): no flag")
            if let (t, ev) = f {
                let h = (t - Self.t0) / 3600
                #expect(h >= 2.75 && h <= 3.25, "seed \(seed): flagged at \(h) h")
                #expect(ev.reason == "slope")
                #expect(abs((ev.slopeMBPerHour ?? 0) - 145) < 30)
            }
        }
    }

    @Test func plateauNeverFlags() {
        var d = LeakDetector(config: .defaults, hwMemsize: Self.gib16)
        let events = run(hours: 9, detector: &d) { s in s < 3600 ? 110 : 600 }
        #expect(firstFlag(events) == nil)
    }

    @Test func sawtoothNeverFlags() {
        var d = LeakDetector(config: .defaults, hwMemsize: Self.gib16)
        let events = run(hours: 9, detector: &d) { s in
            if s < 3600 { return 110 }
            let x = (s - 3600).truncatingRemainder(dividingBy: 1200) / 1200
            let tri = x < 0.5 ? x * 2 : (1 - x) * 2
            return 550 + 450 * tri
        }
        #expect(firstFlag(events) == nil)
    }

    @Test func oneOffSpikeNeverFlags() {
        var d = LeakDetector(config: .defaults, hwMemsize: Self.gib16)
        let spikeAt = 7200.0
        let events = run(hours: 4, detector: &d) { s in s == spikeAt ? 600 + 1024 : 600 }
        #expect(firstFlag(events) == nil)
    }

    @Test func fastPathFlagsA2GBStepOnASeriesOlderThan5Minutes() throws {
        var d = LeakDetector(config: .defaults, hwMemsize: Self.gib16)
        let stepAt = 1800.0
        let events = run(hours: 1, detector: &d) { s in s < stepAt ? 600 : 600 + 2048 }
        let (t, f) = try #require(firstFlag(events))
        #expect(f.reason == "fast")
        #expect(t - Self.t0 >= stepAt && t - Self.t0 <= stepAt + Self.tick)
    }

    @Test func launchRampIsNotALeak() {
        var d = LeakDetector(config: .defaults, hwMemsize: Self.gib16)
        // First seen 290 s into a bucket at 50 MB, linear to 2 GB over 270 s, held 15 min.
        let start = Self.t0 + 290
        let events = run(hours: (270 + 900) / 3600, start: start, detector: &d) { s in
            s <= 270 ? 50 + (2048 - 50) * s / 270 : 2048
        }
        #expect(events.isEmpty)
    }

    func fastClearing(agedSeconds: Double) {
        var d = LeakDetector(config: .defaults, hwMemsize: Self.gib16)
        // A 600 MB plateau aged `agedSeconds`, then +2 GB for 30 min, then a drop to 1316 MB.
        let stepAt = agedSeconds
        let dropAt = stepAt + 1800
        var flaggedTicks = 0
        var unflagT: Double?
        var s = 0.0
        while s <= dropAt + 600 {
            let t = Self.t0 + s
            let v: Double = s < stepAt ? 600 : (s < dropAt ? 2648 : 1316)
            let ev = d.tick(t: t, observations: [obs(mb: v)])
            if s >= stepAt && s < dropAt {
                if d.flag("proc:42:1.000000")?.reason == "fast" { flaggedTicks += 1 }
            }
            for e in ev {
                if case .unflag(let f) = e, f.reason == "fast", unflagT == nil { unflagT = s }
            }
            s += Self.tick
        }
        #expect(flaggedTicks == Int(1800 / Self.tick), "aged \(agedSeconds): flagged on \(flaggedTicks) ticks")
        #expect(unflagT == dropAt, "aged \(agedSeconds): unflag at \(String(describing: unflagT))")
    }

    @Test func fastFlagClearsOnTheDropTickAged2h() { fastClearing(agedSeconds: 7200) }
    @Test func fastFlagClearsOnTheDropTickAged20min() { fastClearing(agedSeconds: 1200) }

    @Test func pidReuseStartsANewSeries() {
        var d = LeakDetector(config: .defaults, hwMemsize: Self.gib16)
        _ = d.tick(t: Self.t0, observations: [obs("proc:42:1.000000", mb: 600)])
        _ = d.tick(t: Self.t0 + 30, observations: [obs("proc:42:2.000000", mb: 600)])
        #expect(d.trackedKeys == ["proc:42:2.000000"])
        #expect(d.meta("proc:42:2.000000")?.firstSeen == Self.t0 + 30)
    }

    @Test func belowTrackFloorIsNotTracked() {
        var d = LeakDetector(config: .defaults, hwMemsize: Self.gib16)
        _ = d.tick(t: Self.t0, observations: [obs(mb: 49)])
        #expect(d.trackedKeys.isEmpty)
        _ = d.tick(t: Self.t0 + 30, observations: [obs(mb: 50)])
        #expect(d.trackedKeys.count == 1)
    }

    @Test func lifetimeMaxRaisesTheBucketMax() {
        var d = LeakDetector(config: .defaults, hwMemsize: Self.gib16)
        _ = d.tick(t: Self.t0, observations: [obs(mb: 600, lifetimeMax: 700 * 1_048_576)])
        _ = d.tick(t: Self.t0 + 30, observations: [obs(mb: 600, lifetimeMax: 900 * 1_048_576)])
        let ev = d.tick(t: Self.t0 + 300, observations: [obs(mb: 600, lifetimeMax: 900 * 1_048_576)])
        let closed = ev.compactMap { e -> Bucket? in
            if case .bucketClosed(_, let b) = e { return b }
            return nil
        }
        #expect(closed.first?.max == 900 * 1_048_576)
        #expect(closed.first?.min == 600 * 1_048_576)
    }

    @Test func theilSenAndRising() {
        let b = (0..<10).map { Bucket(start: Double($0) * 300, min: UInt64(100 + $0 * 12) * 1_048_576, max: 0, count: 1) }
        #expect(abs((LeakDetector.theilSen(b) ?? 0) - 144) < 0.001)
        #expect(LeakDetector.risingFraction(b) == 1)
    }

    @Test func goneSeriesUnflags() {
        var d = LeakDetector(config: .defaults, hwMemsize: Self.gib16)
        var s = 0.0
        while s <= 1800 {
            _ = d.tick(t: Self.t0 + s, observations: [obs(mb: s < 900 ? 600 : 2648)])
            s += 30
        }
        #expect(d.flag("proc:42:1.000000") != nil)
        let ev = d.tick(t: Self.t0 + s, observations: [])
        #expect(ev.contains { if case .unflag = $0 { return true } else { return false } })
    }
}
