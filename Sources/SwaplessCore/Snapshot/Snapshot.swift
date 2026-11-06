import Foundation

/// Where the footprints of processes Swapless can't read itself come from (spec § A).
public enum FootprintSourceKind: String, Sendable, Codable {
    /// Private coalition totals (self-check passed).
    case coalition
    /// `top -l 1` for the unreadable pids (degraded).
    case top
    /// `top` failed too: unreadable footprints are null.
    case none
}

/// Process identity = (pid, `p_starttime`) from `kinfo_proc` (spec § F).
public struct ProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    public let startSec: Int64
    public let startUsec: Int32

    public init(pid: Int32, startSec: Int64, startUsec: Int32) {
        self.pid = pid
        self.startSec = startSec
        self.startUsec = startUsec
    }

    /// `proc:<pid>:<sec>.<usec %06d>`
    public var seriesKey: String {
        "proc:\(pid):\(startSec).\(Self.pad6(startUsec))"
    }

    /// Unix seconds as a float (the JSON `startTime`).
    public var startTime: Double { Double(startSec) + Double(startUsec) / 1_000_000 }

    static func pad6(_ v: Int32) -> String {
        let s = String(v)
        return s.count >= 6 ? s : String(repeating: "0", count: 6 - s.count) + s
    }
}

/// One process as seen by one sweep.
public struct ProcessSample: Sendable, Equatable {
    public var pid: Int32
    public var ppid: Int32
    public var euid: UInt32
    public var startSec: Int64
    public var startUsec: Int32
    /// Executable basename (from the path), or `p_comm` when the path is unknown.
    public var name: String
    /// Full executable path; empty when unknown (pid 0).
    public var path: String
    /// `coalition_id[0]`, the resource coalition (0 when unknown).
    public var coalition: UInt64
    /// `coalition_id[1]`, the jetsam coalition.
    public var jetsamCoalition: UInt64
    /// `ri_phys_footprint` for readable pids; the latest `top` value for unreadable ones in
    /// `top` mode; nil otherwise.
    public var footprint: UInt64?
    /// `ri_lifetime_max_phys_footprint` (readable pids only).
    public var lifetimeMax: UInt64?
    /// True when `proc_pid_rusage` succeeded (same-user pids).
    public var readable: Bool
    /// `responsibility_get_pid_responsible_for_pid`, -1 when unknown. Labels only.
    public var responsiblePid: Int32
    /// Basename of the cwd, for Claude Code roots only.
    public var cwdBasename: String?
    /// The device UDID, for `launchd_sim` only.
    public var simulatorUDID: String?

    public init(pid: Int32, ppid: Int32, euid: UInt32, startSec: Int64, startUsec: Int32,
                name: String, path: String, coalition: UInt64, jetsamCoalition: UInt64,
                footprint: UInt64?, lifetimeMax: UInt64?, readable: Bool,
                responsiblePid: Int32, cwdBasename: String? = nil, simulatorUDID: String? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.euid = euid
        self.startSec = startSec
        self.startUsec = startUsec
        self.name = name
        self.path = path
        self.coalition = coalition
        self.jetsamCoalition = jetsamCoalition
        self.footprint = footprint
        self.lifetimeMax = lifetimeMax
        self.readable = readable
        self.responsiblePid = responsiblePid
        self.cwdBasename = cwdBasename
        self.simulatorUDID = simulatorUDID
    }

    public var identity: ProcessIdentity {
        ProcessIdentity(pid: pid, startSec: startSec, startUsec: startUsec)
    }

    public var startTime: Double { identity.startTime }
}

/// One coalition's usage as read by the private call.
public struct CoalitionSample: Sendable, Equatable {
    public var cid: UInt64
    public var footprint: UInt64
    public var started: UInt64
    public var exited: UInt64

    public init(cid: UInt64, footprint: UInt64, started: UInt64, exited: UInt64) {
        self.cid = cid
        self.footprint = footprint
        self.started = started
        self.exited = exited
    }
}

/// System memory signals (spec S1).
public struct SystemSample: Sendable, Equatable {
    /// `kern.memorystatus_level`.
    public var freePct: Int
    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    public var pressure: Int
    /// `vm.swapusage.xsu_used`.
    public var swapUsedBytes: UInt64
    /// Δ swapins × 16384 ÷ Δ uptime; nil on the first sample and the first after wake.
    public var swapinBytesPerSec: Double?
    /// The raw cumulative `HOST_VM_INFO64.swapins` counter (16 KiB units).
    public var swapinsTotal: UInt64
    /// `compressor_page_count` × page size (Activity Monitor's "Compressed").
    public var compressedBytes: UInt64

    public init(freePct: Int, pressure: Int, swapUsedBytes: UInt64, swapinBytesPerSec: Double?,
                swapinsTotal: UInt64, compressedBytes: UInt64) {
        self.freePct = freePct
        self.pressure = pressure
        self.swapUsedBytes = swapUsedBytes
        self.swapinBytesPerSec = swapinBytesPerSec
        self.swapinsTotal = swapinsTotal
        self.compressedBytes = compressedBytes
    }

    public static let zero = SystemSample(freePct: 0, pressure: 1, swapUsedBytes: 0,
                                          swapinBytesPerSec: nil, swapinsTotal: 0,
                                          compressedBytes: 0)
}

/// A Sendable value: everything one sweep saw.
public struct Snapshot: Sendable {
    /// Unix wall time read right before `KERN_PROC_ALL`.
    public var wallTime: Double
    /// Uptime seconds (mach absolute time; stops during sleep).
    public var uptime: Double
    public var bootSessionUUID: String
    public var hwMemsize: UInt64
    /// The uid Swapless runs as (`getuid()`); "same-user" means euid == ownUid.
    public var ownUid: UInt32
    public var entries: [ProcessSample]
    public var coalitions: [UInt64: CoalitionSample]
    public var system: SystemSample
    public var source: FootprintSourceKind

    public init(wallTime: Double, uptime: Double, bootSessionUUID: String, hwMemsize: UInt64,
                ownUid: UInt32, entries: [ProcessSample], coalitions: [UInt64: CoalitionSample],
                system: SystemSample, source: FootprintSourceKind) {
        self.wallTime = wallTime
        self.uptime = uptime
        self.bootSessionUUID = bootSessionUUID
        self.hwMemsize = hwMemsize
        self.ownUid = ownUid
        self.entries = entries
        self.coalitions = coalitions
        self.system = system
        self.source = source
    }

    /// `coal:<kern.bootsessionuuid>:<cid>`
    public func coalitionKey(_ cid: UInt64) -> String { "coal:\(bootSessionUUID):\(cid)" }
}

/// `$HOME` → `~` for anything that leaves the process (logs, JSON, fixtures).
public enum PathSanitizer {
    public static func sanitize(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    public static func expand(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }
}

/// Uptime and wall-clock helpers.
public enum Clock {
    /// Seconds of mach absolute time (stops during sleep, like DispatchTime).
    public static func uptime() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    public static func wall() -> Double { Date().timeIntervalSince1970 }
}
