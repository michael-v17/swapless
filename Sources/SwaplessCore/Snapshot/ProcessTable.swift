import Darwin
import Foundation

/// One row of `sysctl {CTL_KERN, KERN_PROC, KERN_PROC_ALL}`.
public struct ProcessEntry: Sendable, Hashable {
    public var pid: Int32
    public var ppid: Int32
    public var euid: UInt32
    public var startSec: Int64
    public var startUsec: Int32
    /// `p_comm` (at most 16 bytes).
    public var comm: String

    public init(pid: Int32, ppid: Int32, euid: UInt32, startSec: Int64, startUsec: Int32,
                comm: String) {
        self.pid = pid
        self.ppid = ppid
        self.euid = euid
        self.startSec = startSec
        self.startUsec = startUsec
        self.comm = comm
    }

    public var identity: ProcessIdentity {
        ProcessIdentity(pid: pid, startSec: startSec, startUsec: startUsec)
    }
}

/// `KERN_PROC_ALL`: pid, ppid, euid and `p_starttime` for every pid, root included.
public enum ProcessTable {
    public static func read() -> [ProcessEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        for _ in 0..<5 {
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
            // Room for processes born between the two calls.
            size += 64 * MemoryLayout<kinfo_proc>.stride
            let capacity = size / MemoryLayout<kinfo_proc>.stride
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            var got = size
            let rc = procs.withUnsafeMutableBufferPointer { buf in
                sysctl(&mib, 3, buf.baseAddress, &got, nil, 0)
            }
            if rc != 0 {
                if errno == ENOMEM { continue }
                return []
            }
            let n = got / MemoryLayout<kinfo_proc>.stride
            var out: [ProcessEntry] = []
            out.reserveCapacity(n)
            for i in 0..<n { out.append(entry(from: procs[i])) }
            return out
        }
        return []
    }

    /// `KERN_PROC_PID` for one pid; nil when it is gone.
    public static func entry(pid: Int32) -> ProcessEntry? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        guard kp.kp_proc.p_pid == pid else { return nil }
        return entry(from: kp)
    }

    static func entry(from kp: kinfo_proc) -> ProcessEntry {
        let start = kp.kp_proc.p_un.__p_starttime
        let comm = withUnsafeBytes(of: kp.kp_proc.p_comm) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return ProcessEntry(
            pid: kp.kp_proc.p_pid,
            ppid: kp.kp_eproc.e_ppid,
            euid: kp.kp_eproc.e_ucred.cr_uid,
            startSec: Int64(start.tv_sec),
            startUsec: Int32(start.tv_usec),
            comm: comm)
    }

    /// `proc_pidpath`, decoded with replacement characters (never crashes on non-UTF-8).
    public static func executablePath(pid: Int32) -> String? {
        var buf = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = buf.withUnsafeMutableBytes { raw in
            proc_pidpath(pid, raw.baseAddress, UInt32(raw.count))
        }
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(Int(n)), as: UTF8.self)
    }

    /// The cwd via `PROC_PIDVNODEPATHINFO` (same-user pids only).
    public static func workingDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard n == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw -> String in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// Basename helper used for labels.
    public static func basename(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
}

/// Small sysctl readers.
public enum Sysctl {
    public static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        switch size {
        case 4: return Int(Int32(truncatingIfNeeded: value))
        default: return Int(value)
        }
    }

    public static func uint64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        if size == 4 { return UInt64(UInt32(truncatingIfNeeded: value)) }
        return value
    }

    public static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
    }

    public static var bootSessionUUID: String { string("kern.bootsessionuuid") ?? "unknown-boot" }
    public static var hwMemsize: UInt64 { uint64("hw.memsize") ?? 0 }
}
