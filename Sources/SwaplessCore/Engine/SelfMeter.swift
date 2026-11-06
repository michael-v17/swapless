import CSwaplessProc
import Darwin
import Foundation

/// Swapless's own cost (§ B): CPU in mach ticks × timebase, footprint, peak.
public struct SelfReading: Sendable, Equatable {
    /// Cumulative own user+system CPU, seconds.
    public var cpuSeconds: Double
    /// Cumulative reaped children (where `top` runs land), seconds.
    public var childCpuSeconds: Double
    /// Δ(cpu + child) over the rolling 10 min, percent of one core.
    public var cpuPercent: Double
    public var footprint: UInt64
    public var peakFootprint: UInt64
    /// Δ(cpu + child) ÷ Δuptime over the newest ≥ 600 s of **menu-closed** time, percent of
    /// one core (v1-menu-today T6). nil until 60 s of closed time is measured.
    public var cpuPercentIdle: Double?
    /// Cumulative CPU (cpu + child) spent in menu-open intervals since launch, seconds.
    public var menuOpenCpuSeconds: Double

    public init(cpuSeconds: Double, childCpuSeconds: Double, cpuPercent: Double, footprint: UInt64,
                peakFootprint: UInt64, cpuPercentIdle: Double? = nil, menuOpenCpuSeconds: Double = 0) {
        self.cpuSeconds = cpuSeconds
        self.childCpuSeconds = childCpuSeconds
        self.cpuPercent = cpuPercent
        self.footprint = footprint
        self.peakFootprint = peakFootprint
        self.cpuPercentIdle = cpuPercentIdle
        self.menuOpenCpuSeconds = menuOpenCpuSeconds
    }

    public var json: JSON {
        .object([
            ("cpuSeconds", .double(cpuSeconds)),
            ("childCpuSeconds", .double(childCpuSeconds)),
            ("cpuPercent", .double(cpuPercent)),
            ("footprint", .uint(footprint)),
            ("peakFootprint", .uint(peakFootprint)),
            ("cpuPercentIdle", .opt(cpuPercentIdle)),
            ("menuOpenCpuSeconds", .double(menuOpenCpuSeconds)),
        ])
    }
}

public final class SelfMeter: @unchecked Sendable {
    public static let windowSeconds = 600.0
    public static let cpuBudgetPercent = 0.2
    public static let cpuBudgetTopPercent = 0.6
    /// The footprint budget (owner, 2026-11-05, DECISIONS.md): ≤ 30 MiB idle before the menu
    /// has ever been shown, ≤ 40 MiB after it has been used (drawing it leaves ~10–14 MiB of
    /// framework memory no public API releases), peak ≤ 45 MiB.
    public static let footprintBudget: UInt64 = 30 * 1024 * 1024
    public static let footprintBudgetAfterMenu: UInt64 = 40 * 1024 * 1024
    public static let peakBudget: UInt64 = 45 * 1024 * 1024

    private let numer: UInt32
    private let denom: UInt32
    private var history: [(uptime: Double, cpu: Double)] = []
    private let startUptime: Double
    public private(set) var last: SelfReading?

    public init() {
        var n: UInt32 = 1, d: UInt32 = 1
        sw_timebase(&n, &d)
        numer = n == 0 ? 1 : n
        denom = d == 0 ? 1 : d
        startUptime = Clock.uptime()
    }

    /// Mach ticks → seconds with the timebase (125/3 on M1). Read as ns they undercount 41×.
    public static func ticksToSeconds(_ ticks: UInt64, numer: UInt32, denom: UInt32) -> Double {
        Double(ticks) * Double(numer) / Double(denom) / 1_000_000_000
    }

    /// One interval between two consecutive readings: entirely open or entirely closed (T6).
    public typealias Interval = (dt: Double, dcpu: Double, open: Bool)

    /// Intervals since the oldest one the idle window still needs, newest last.
    private var intervals: [Interval] = []
    private var lastPoint: (uptime: Double, cpu: Double)?
    private var openCpu: Double = 0

    /// Reads own CPU and footprint. `menuOpenDuringInterval` labels the interval that ends at
    /// this reading: the engine passes its `menuOpen` before toggling it at a transition, and
    /// its current value at a base tick.
    public func read(uptime: Double = Clock.uptime(), menuOpenDuringInterval: Bool = false) -> SelfReading {
        var ru = sw_rusage_t()
        _ = sw_pid_rusage(getpid(), &ru)
        let cpu = Self.ticksToSeconds(ru.user_time &+ ru.system_time, numer: numer, denom: denom)
        let child = Self.ticksToSeconds(ru.child_user_time &+ ru.child_system_time,
                                        numer: numer, denom: denom)
        return record(uptime: uptime, cpuTotal: cpu + child, footprint: ru.phys_footprint,
                      peak: ru.lifetime_max_phys_footprint, menuOpenDuringInterval: menuOpenDuringInterval,
                      cpuSeconds: cpu, childCpuSeconds: child)
    }

    /// Everything `read` does after the syscall (the test seam): intervals, trimming, idle %,
    /// open CPU, and the all-time rolling 10-min figure.
    func record(uptime: Double, cpuTotal total: Double, footprint: UInt64, peak: UInt64,
                menuOpenDuringInterval open: Bool,
                cpuSeconds: Double? = nil, childCpuSeconds: Double = 0) -> SelfReading {
        if let p = lastPoint, uptime > p.uptime {
            let dt = uptime - p.uptime
            let dcpu = max(0, total - p.cpu)
            if open {
                openCpu += dcpu
                // Consecutive open intervals merge: idle skips them anyway, and memory stays
                // bounded however long the menu stays open.
                if let lastIv = intervals.last, lastIv.open {
                    intervals[intervals.count - 1] = (lastIv.dt + dt, lastIv.dcpu + dcpu, true)
                } else {
                    intervals.append((dt, dcpu, true))
                }
            } else {
                intervals.append((dt, dcpu, false))
            }
            trimIntervals()
        }
        if lastPoint == nil || uptime > lastPoint!.uptime { lastPoint = (uptime, total) }

        history.append((uptime, total))
        while let first = history.first, uptime - first.uptime > Self.windowSeconds, history.count > 2 {
            history.removeFirst()
        }
        var pct = 0.0
        if let first = history.first, uptime - first.uptime > 0.5 {
            pct = (total - first.cpu) / (uptime - first.uptime) * 100
        } else if uptime - startUptime > 0.5 {
            pct = total / (uptime - startUptime) * 100
        }
        let r = SelfReading(cpuSeconds: cpuSeconds ?? total, childCpuSeconds: childCpuSeconds, cpuPercent: pct,
                            footprint: footprint, peakFootprint: peak,
                            cpuPercentIdle: Self.idlePercent(intervals), menuOpenCpuSeconds: openCpu)
        last = r
        return r
    }

    /// Drops intervals older than the oldest one the idle window needs.
    private func trimIntervals() {
        var closed = 0.0
        var i = intervals.count - 1
        while i >= 0 {
            if !intervals[i].open {
                closed += intervals[i].dt
                if closed >= Self.windowSeconds { break }
            }
            i -= 1
        }
        if i > 0 { intervals.removeFirst(i) }
    }

    /// T6: walk newest → oldest, skip open intervals, sum closed Δuptime and ΔCPU until the
    /// summed Δuptime reaches `window` (the crossing interval is included whole). nil with less
    /// than `minClosed` seconds of closed time.
    public static func idlePercent(_ intervals: [Interval], window: Double = 600,
                                   minClosed: Double = 60) -> Double? {
        var dt = 0.0
        var dcpu = 0.0
        for iv in intervals.reversed() where !iv.open {
            dt += iv.dt
            dcpu += iv.dcpu
            if dt >= window { break }
        }
        guard dt >= minClosed, dt > 0 else { return nil }
        return dcpu / dt * 100
    }

    /// The menu footer's "over budget": the menu-closed CPU (`cpuPercentIdle`; nil is not
    /// over) or the footprint above its limit. The footprint limit is 30 MiB until the menu has
    /// first been shown, 40 MiB after.
    public static func overBudget(_ r: SelfReading, topMode: Bool, menuShown: Bool) -> Bool {
        let cpuLimit = topMode ? cpuBudgetTopPercent : cpuBudgetPercent
        let footprintLimit = menuShown ? footprintBudgetAfterMenu : footprintBudget
        let cpuOver = r.cpuPercentIdle.map { $0 > cpuLimit } ?? false
        return cpuOver || r.footprint > footprintLimit
    }

    /// The `self` log line (category `self`): the § B line, then the v1-menu-today fields.
    public static func logLine(_ r: SelfReading, menuOpenSeconds: Double, displaySweeps: Int) -> String {
        let idle = r.cpuPercentIdle.map { String(format: "%.3f", $0) } ?? "none"
        return "self cpuSeconds=\(String(format: "%.3f", r.cpuSeconds)) childCpuSeconds=\(String(format: "%.3f", r.childCpuSeconds)) cpuPct10m=\(String(format: "%.3f", r.cpuPercent)) footprint=\(r.footprint) peak=\(r.peakFootprint) menuOpenSeconds=\(String(format: "%.1f", menuOpenSeconds)) cpuPct10mIdle=\(idle) menuOpenCpuSeconds=\(String(format: "%.3f", r.menuOpenCpuSeconds)) displaySweeps=\(displaySweeps)"
    }
}
