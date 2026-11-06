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

    public var json: JSON {
        .object([
            ("cpuSeconds", .double(cpuSeconds)),
            ("childCpuSeconds", .double(childCpuSeconds)),
            ("cpuPercent", .double(cpuPercent)),
            ("footprint", .uint(footprint)),
            ("peakFootprint", .uint(peakFootprint)),
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

    public func read(uptime: Double = Clock.uptime()) -> SelfReading {
        var ru = sw_rusage_t()
        _ = sw_pid_rusage(getpid(), &ru)
        let cpu = Self.ticksToSeconds(ru.user_time &+ ru.system_time, numer: numer, denom: denom)
        let child = Self.ticksToSeconds(ru.child_user_time &+ ru.child_system_time,
                                        numer: numer, denom: denom)
        let total = cpu + child
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
        let r = SelfReading(cpuSeconds: cpu, childCpuSeconds: child, cpuPercent: pct,
                            footprint: ru.phys_footprint,
                            peakFootprint: ru.lifetime_max_phys_footprint)
        last = r
        return r
    }

    /// The menu footer's "over budget": CPU or footprint above its limit. The footprint limit
    /// is 30 MiB until the menu has first been shown, 40 MiB after.
    public static func overBudget(_ r: SelfReading, topMode: Bool, menuShown: Bool) -> Bool {
        let cpuLimit = topMode ? cpuBudgetTopPercent : cpuBudgetPercent
        let footprintLimit = menuShown ? footprintBudgetAfterMenu : footprintBudget
        return r.cpuPercent > cpuLimit || r.footprint > footprintLimit
    }

    /// The `self` log line (category `self`), exactly as § B words it.
    public static func logLine(_ r: SelfReading, menuOpenSeconds: Double) -> String {
        "self cpuSeconds=\(String(format: "%.3f", r.cpuSeconds)) childCpuSeconds=\(String(format: "%.3f", r.childCpuSeconds)) cpuPct10m=\(String(format: "%.3f", r.cpuPercent)) footprint=\(r.footprint) peak=\(r.peakFootprint) menuOpenSeconds=\(String(format: "%.1f", menuOpenSeconds))"
    }
}
