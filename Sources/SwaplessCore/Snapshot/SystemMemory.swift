import CSwaplessProc
import Darwin
import Foundation

/// System memory signals (spec S1). Holds the previous swap-in counter for the rate.
public final class SystemMemory: @unchecked Sendable {
    private var lastSwapins: UInt64?
    private var lastUptime: Double?

    public init() {}

    /// The first sample after this call reports a null swap-in rate (wake).
    public func resetRate() {
        lastSwapins = nil
        lastUptime = nil
    }

    public func read(uptime: Double) -> SystemSample {
        let free = Sysctl.int("kern.memorystatus_level") ?? 0
        let pressure = Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1
        var swapUsed: UInt64 = 0
        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 { swapUsed = xsw.xsu_used }
        var pages: UInt64 = 0
        var swapins: UInt64 = 0
        var pageSize: UInt64 = 16384
        _ = sw_host_vm(&pages, &swapins, &pageSize)
        let rate = Self.swapinRate(previous: lastSwapins, previousUptime: lastUptime,
                                   current: swapins, uptime: uptime)
        lastSwapins = swapins
        lastUptime = uptime
        return SystemSample(freePct: free, pressure: pressure, swapUsedBytes: swapUsed,
                            swapinBytesPerSec: rate, swapinsTotal: swapins,
                            compressedBytes: pages &* pageSize)
    }

    /// Δ swapins × 16384 ÷ Δ uptime seconds. The global counter counts 16 KiB compressed-swap
    /// units; never mix it with per-task (byte) swap-ins.
    public static func swapinRate(previous: UInt64?, previousUptime: Double?, current: UInt64,
                                  uptime: Double) -> Double? {
        guard let previous, let previousUptime else { return nil }
        let dt = uptime - previousUptime
        guard dt > 0, current >= previous else { return nil }
        return Double(current - previous) * 16384 / dt
    }

    public static func pressureName(_ level: Int) -> String {
        switch level {
        case 4: return "critical"
        case 2: return "warning"
        default: return "normal"
        }
    }
}
