import CSwaplessProc
import Darwin
import Foundation

/// The § A self-check: (a) the coalition total equals rusage on single-member same-user
/// coalitions, (b) WindowServer's coalition reads, plus the responsibility symbol.
public struct SelfCheckResult: Sendable, Equatable {
    public enum Status: String, Sendable {
        case pass, fail, missing, skipped
    }

    public var coalition: Status
    public var checked: Int
    public var passed: Int
    public var windowServer: Status
    public var responsibility: Status
    /// Why it failed, for the `.default` log line.
    public var reason: String?

    public init(coalition: Status, checked: Int, passed: Int, windowServer: Status,
                responsibility: Status, reason: String? = nil) {
        self.coalition = coalition
        self.checked = checked
        self.passed = passed
        self.windowServer = windowServer
        self.responsibility = responsibility
        self.reason = reason
    }

    /// Coalition mode is allowed only when the self-check passed.
    public var coalitionUsable: Bool { coalition == .pass }

    public var json: JSON {
        .object([
            ("coalition", .string(coalition.rawValue)),
            ("checked", .i(checked)),
            ("passed", .i(passed)),
            ("windowServer", .string(windowServer.rawValue)),
            ("responsibility", .string(responsibility.rawValue)),
        ])
    }
}

/// The system calls the self-check needs, injectable for fixtures.
public struct SelfCheckProbe: Sendable {
    /// rc, footprint, started, exited
    public var coalitionUsage: @Sendable (UInt64) -> (Int32, UInt64, UInt64, UInt64)
    /// `ri_phys_footprint`, nil when unreadable.
    public var rusageFootprint: @Sendable (Int32) -> UInt64?
    public var responsiblePid: @Sendable (Int32) -> Int32
    public var symbols: @Sendable () -> Int32

    public init(coalitionUsage: @escaping @Sendable (UInt64) -> (Int32, UInt64, UInt64, UInt64),
                rusageFootprint: @escaping @Sendable (Int32) -> UInt64?,
                responsiblePid: @escaping @Sendable (Int32) -> Int32,
                symbols: @escaping @Sendable () -> Int32) {
        self.coalitionUsage = coalitionUsage
        self.rusageFootprint = rusageFootprint
        self.responsiblePid = responsiblePid
        self.symbols = symbols
    }

    public static let live = SelfCheckProbe(
        coalitionUsage: { cid in
            var fp: UInt64 = 0, st: UInt64 = 0, ex: UInt64 = 0
            let rc = sw_coalition_usage(cid, &fp, &st, &ex)
            return (rc, fp, st, ex)
        },
        rusageFootprint: { pid in
            var ru = sw_rusage_t()
            return sw_pid_rusage(pid, &ru) == 0 ? ru.phys_footprint : nil
        },
        responsiblePid: { pid in sw_responsible_pid(pid) },
        symbols: { sw_symbols_available() })
}

public enum SelfCheck {
    public static let maxChecked = 10
    public static let minChecked = 5
    public static let passFraction = 0.9
    public static let windowServerMinBytes: UInt64 = 50 * 1024 * 1024

    /// A skipped self-check (`SWAPLESS_FORCE_TOP=1`).
    public static func skipped(probe: SelfCheckProbe = .live, ownPid: Int32 = getpid()) -> SelfCheckResult {
        SelfCheckResult(coalition: .skipped, checked: 0, passed: 0, windowServer: .skipped,
                        responsibility: responsibility(probe: probe, ownPid: ownPid))
    }

    public static func responsibility(probe: SelfCheckProbe, ownPid: Int32) -> SelfCheckResult.Status {
        if probe.symbols() & Int32(SW_SYM_RESPONSIBLE_PID) == 0 { return .missing }
        return probe.responsiblePid(ownPid) > 0 ? .pass : .fail
    }

    /// `entries` needs pid, euid, coalition and path (from a process table + flavor 20).
    public static func run(entries: [ProcessSample], ownUid: UInt32, ownPid: Int32,
                           probe: SelfCheckProbe) -> SelfCheckResult {
        let resp = responsibility(probe: probe, ownPid: ownPid)
        if probe.symbols() & Int32(SW_SYM_COALITION_USAGE) == 0 {
            return SelfCheckResult(coalition: .missing, checked: 0, passed: 0,
                                   windowServer: .missing, responsibility: resp,
                                   reason: "coalition_info_resource_usage is missing")
        }
        var byCoalition: [UInt64: [ProcessSample]] = [:]
        for e in entries where e.coalition != 0 { byCoalition[e.coalition, default: []].append(e) }

        // (a) single-member same-user coalitions, largest footprint first.
        var candidates: [(cid: UInt64, pid: Int32, footprint: UInt64)] = []
        for (cid, members) in byCoalition {
            guard members.count == 1, let m = members.first, m.euid == ownUid else { continue }
            let (rc, fp, started, exited) = probe.coalitionUsage(cid)
            if rc == SW_ERR_LAYOUT_DRIFT {
                return SelfCheckResult(coalition: .fail, checked: 0, passed: 0,
                                       windowServer: .fail, responsibility: resp,
                                       reason: "coalition usage layout drift")
            }
            guard rc == 0, started &- exited == 1 else { continue }
            guard probe.rusageFootprint(m.pid) != nil else { continue }
            candidates.append((cid, m.pid, fp))
        }
        candidates.sort { $0.footprint > $1.footprint }
        var checked = 0
        var passed = 0
        for c in candidates {
            if checked >= maxChecked { break }
            guard let r1 = probe.rusageFootprint(c.pid) else { continue }
            let (rc, fp, _, _) = probe.coalitionUsage(c.cid)
            guard let r2 = probe.rusageFootprint(c.pid) else { continue }
            guard rc == 0 else {
                checked += 1
                continue
            }
            checked += 1
            if fp >= min(r1, r2) && fp <= max(r1, r2) { passed += 1 }
        }

        // (b) WindowServer's coalition.
        var ws: SelfCheckResult.Status = .fail
        var wsReason: String?
        if let w = entries.first(where: { $0.path.hasSuffix("/WindowServer") }), w.coalition != 0 {
            let (rc, fp, _, _) = probe.coalitionUsage(w.coalition)
            if rc == 0 && fp >= windowServerMinBytes {
                ws = .pass
            } else {
                wsReason = "WindowServer coalition rc \(rc), footprint \(fp)"
            }
        } else {
            wsReason = "WindowServer not found"
        }

        let aPass = checked >= minChecked && Double(passed) >= passFraction * Double(checked)
        var reason: String?
        if !aPass { reason = "single-member check: \(passed) of \(checked) passed" }
        if ws != .pass { reason = [reason, wsReason].compactMap { $0 }.joined(separator: "; ") }
        return SelfCheckResult(coalition: aPass && ws == .pass ? .pass : .fail,
                               checked: checked, passed: passed, windowServer: ws,
                               responsibility: resp, reason: reason)
    }
}
