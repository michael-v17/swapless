import CSwaplessProc
import Darwin
import Foundation

/// A process as the inspector sees it right now.
public struct InspectedProcess: Sendable, Equatable {
    public var identity: ProcessIdentity
    public var path: String
    public var euid: UInt32
    public var footprint: UInt64?

    public init(identity: ProcessIdentity, path: String, euid: UInt32, footprint: UInt64?) {
        self.identity = identity
        self.path = path
        self.euid = euid
        self.footprint = footprint
    }

    public var pid: Int32 { identity.pid }
}

/// Step 1's re-read and the verify loop's process list (§ J seam).
public protocol ProcessInspector: Sendable {
    /// `kinfo_proc` + `proc_pidpath` for one pid right now; nil when it is gone.
    func identity(pid: Int32) -> InspectedProcess?
    /// Every process at one of `paths` (any euid; callers filter).
    func list(paths: Set<String>) -> [InspectedProcess]
}

public enum SignalResult: Sendable, Equatable {
    case sent
    case alreadyGone
    case refused(String)
    case failed(Int32)
}

/// The only way to signal (§ J seam). `LiveSignalSender` lives in the app target only.
public protocol SignalSender: Sendable {
    func sigterm(pid: Int32, target: RestartTarget) -> SignalResult
}

/// The refusals, in one pure function both senders call first.
public enum SignalGuard {
    public static func refusal(pid: Int32, target: RestartTarget, ownPid: Int32,
                               refuseWallpaper: Bool) -> String? {
        if pid <= 1 { return "pid-out-of-range" }
        if pid == ownPid { return "own-pid" }
        if target == .wallpaper && refuseWallpaper { return "debug-build-refuses-wallpaper" }
        return nil
    }
}

/// Sends nothing; applies the same refusals (with `refuseWallpaper: false`) and records calls.
public final class DryRunSignalSender: SignalSender, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(pid: Int32, target: RestartTarget)] = []
    private let ownPid: Int32
    private let sink: EventSink?

    public init(ownPid: Int32 = getpid(), sink: EventSink? = nil) {
        self.ownPid = ownPid
        self.sink = sink
    }

    public func sigterm(pid: Int32, target: RestartTarget) -> SignalResult {
        if let r = SignalGuard.refusal(pid: pid, target: target, ownPid: ownPid, refuseWallpaper: false) {
            sink?.error(where: "signal", r, category: .actions)
            return .refused(r)
        }
        lock.lock()
        _calls.append((pid, target))
        lock.unlock()
        return .sent
    }

    public var calls: [(pid: Int32, target: RestartTarget)] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }
}

/// `kinfo_proc` + `proc_pidpath` + rusage, live.
public struct LiveProcessInspector: ProcessInspector {
    public init() {}

    public func identity(pid: Int32) -> InspectedProcess? {
        guard let e = ProcessTable.entry(pid: pid), let path = ProcessTable.executablePath(pid: pid) else { return nil }
        return InspectedProcess(identity: e.identity, path: path, euid: e.euid, footprint: nil)
    }

    public func list(paths: Set<String>) -> [InspectedProcess] {
        var out: [InspectedProcess] = []
        for e in ProcessTable.read() where e.euid == getuid() {
            guard let p = ProcessTable.executablePath(pid: e.pid), paths.contains(p) else { continue }
            var ru = sw_rusage_t()
            let fp: UInt64? = sw_pid_rusage(e.pid, &ru) == 0 ? ru.phys_footprint : nil
            out.append(InspectedProcess(identity: e.identity, path: p, euid: e.euid, footprint: fp))
        }
        return out
    }
}

/// An in-memory table (tests, the property test).
public final class FixtureProcessInspector: ProcessInspector, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [Int32: InspectedProcess]

    public init(_ processes: [InspectedProcess]) {
        table = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public convenience init(snapshot s: Snapshot) {
        self.init(s.entries.map {
            InspectedProcess(identity: $0.identity, path: $0.path, euid: $0.euid, footprint: $0.footprint)
        })
    }

    public func set(_ processes: [InspectedProcess]) {
        lock.lock()
        table = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        lock.unlock()
    }

    public func identity(pid: Int32) -> InspectedProcess? {
        lock.lock()
        defer { lock.unlock() }
        return table[pid]
    }

    public func list(paths: Set<String>) -> [InspectedProcess] {
        lock.lock()
        defer { lock.unlock() }
        return table.values.filter { paths.contains($0.path) }.sorted { $0.pid < $1.pid }
    }
}

/// Where action rows go (HistoryStore in the app; an in-memory log in tests).
public protocol ActionRecorder: AnyObject {
    func insertAction(ts: Double, ruleId: String, target: String, pids: [Int32], beforeMB: Double,
                      outcome: String, dryRun: Bool) -> Int64?
    @discardableResult
    func updateOutcome(id: Int64, outcome: String, afterMB: Double?, wsBeforeMB: Double?, wsAfterMB: Double?) -> Bool
}

extension HistoryStore: ActionRecorder {}

/// A pending wallpaper verification (§ J step 4), driven on a 2 s cadence (uptime).
public struct VerifyPlan: Sendable, Equatable {
    public var ruleId: String
    public var actionId: Int64
    public var preSet: Set<ProcessIdentity>
    public var beforeMB: Double
    public var wsBeforeMB: Double?
    public var agentBackAt: Double?
    public var extensionBackAt: Double?

    public static let agentDeadline = 30.0
    public static let extensionDeadline = 120.0
    public static let afterDelay = 60.0
    public static let cadence = 2.0
}

public struct VerifyResult: Sendable, Equatable {
    public var outcome: String
    public var afterMB: Double?
    public var wsAfterMB: Double?
}

/// What `execute` did.
public enum ExecuteResult: Sendable, Equatable {
    /// Step 1 mismatch: no row, no outcome, no cooldown.
    case identityChanged
    /// The row couldn't be written: nothing was signalled.
    case historyOff
    case dryRun(actionId: Int64)
    /// rigHelper: signalled, outcome written.
    case signalled(actionId: Int64)
    /// wallpaper: signalled, verification pending.
    case verifying(VerifyPlan)
}

/// § J: identity re-check, the row before any signal, SIGTERM (never SIGKILL), verification.
public final class Actuator: @unchecked Sendable {
    public let inspector: ProcessInspector
    public let sender: SignalSender
    public let ownUid: UInt32
    public let dryRun: Bool
    private let sink: EventSink?

    public init(inspector: ProcessInspector, sender: SignalSender, ownUid: UInt32 = getuid(),
                dryRun: Bool, sink: EventSink?) {
        self.inspector = inspector
        self.sender = sender
        self.ownUid = ownUid
        self.dryRun = dryRun
        self.sink = sink
    }

    public func execute(_ intent: Intent, now: Double, recorder: ActionRecorder?,
                        wsBeforeMB: Double?) -> ExecuteResult {
        // 1. Right before signalling, re-read every target: same start time, path and euid.
        for p in intent.restartSet {
            guard let cur = inspector.identity(pid: p.pid), cur.identity == p.identity, cur.path == p.path,
                  cur.euid == ownUid, p.euid == ownUid else {
                return .identityChanged
            }
        }
        // 2. The row first; no row, no signal.
        let pids = intent.restartSet.map(\.pid)
        guard let recorder,
              let id = recorder.insertAction(ts: now, ruleId: intent.ruleId, target: intent.target.rawValue,
                                             pids: pids, beforeMB: intent.beforeMB,
                                             outcome: dryRun ? "dry-run" : "pending", dryRun: dryRun) else {
            return .historyOff
        }
        sink?.log(.actions, "action id=\(id) rule=\(intent.ruleId) target=\(intent.target.rawValue) pids=\(pids) beforeMB=\(String(format: "%.1f", intent.beforeMB)) dryRun=\(dryRun) outcome=\(dryRun ? "dry-run" : "pending")")
        sink?.emit("action", .object([
            ("type", .string("action")),
            ("t", .double(now)),
            ("actionId", .int(id)),
            ("ruleId", .string(intent.ruleId)),
            ("target", .string(intent.target.rawValue)),
            ("pids", .array(pids.map { .i($0) })),
            ("beforeMB", .double(intent.beforeMB)),
            ("dryRun", .bool(dryRun)),
            ("outcome", .string(dryRun ? "dry-run" : "pending")),
        ]))
        if dryRun { return .dryRun(actionId: id) }

        // 3. SIGTERM every extension instance, then the agent(s). ESRCH = already gone.
        for p in intent.restartSet {
            let r = sender.sigterm(pid: p.pid, target: intent.target)
            sink?.log(.actions, "sigterm pid=\(p.pid) target=\(intent.target.rawValue) result=\(r)")
        }
        switch intent.target {
        case .wallpaper:
            return .verifying(VerifyPlan(ruleId: intent.ruleId, actionId: id,
                                         preSet: Set(intent.restartSet.map(\.identity)),
                                         beforeMB: intent.beforeMB, wsBeforeMB: wsBeforeMB))
        #if DEBUG
        case .rigHelper:
            finish(actionId: id, ruleId: intent.ruleId,
                   result: VerifyResult(outcome: "signalled", afterMB: nil, wsAfterMB: nil),
                   wsBeforeMB: nil, recorder: recorder, now: now)
            return .signalled(actionId: id)
        #endif
        }
    }

    /// One verify poll at `elapsed` seconds (uptime) after the signal. Returns the result when
    /// the verification is over.
    public func poll(_ plan: inout VerifyPlan, elapsed: Double, wsNowMB: () -> Double?) -> VerifyResult? {
        let procs = inspector.list(paths: [RestartTarget.wallpaperAgentPath, RestartTarget.wallpaperExtensionPath])
            .filter { $0.euid == ownUid }
        let newAgents = procs.filter { $0.path == RestartTarget.wallpaperAgentPath && !plan.preSet.contains($0.identity) }
        let newExts = procs.filter { $0.path == RestartTarget.wallpaperExtensionPath && !plan.preSet.contains($0.identity) }
        if plan.agentBackAt == nil && !newAgents.isEmpty { plan.agentBackAt = elapsed }
        if plan.extensionBackAt == nil && !newExts.isEmpty { plan.extensionBackAt = elapsed }
        if plan.agentBackAt == nil && elapsed > VerifyPlan.agentDeadline {
            return VerifyResult(outcome: "agent-missing", afterMB: nil, wsAfterMB: wsNowMB())
        }
        if plan.extensionBackAt == nil && elapsed > VerifyPlan.extensionDeadline {
            return VerifyResult(outcome: "extension-missing", afterMB: nil, wsAfterMB: wsNowMB())
        }
        if let back = plan.extensionBackAt, elapsed - back >= VerifyPlan.afterDelay, plan.agentBackAt != nil {
            let after = Double(newExts.reduce(UInt64(0)) { $0 + ($1.footprint ?? 0) }) / 1_048_576
            let outcome = after < 0.5 * plan.beforeMB ? "ok" : "no-improvement"
            return VerifyResult(outcome: outcome, afterMB: after, wsAfterMB: wsNowMB())
        }
        return nil
    }

    /// Writes the outcome and emits the `actionOutcome` line.
    @discardableResult
    public func finish(actionId: Int64, ruleId: String, result: VerifyResult, wsBeforeMB: Double?,
                       recorder: ActionRecorder?, now: Double) -> Bool {
        let ok = recorder?.updateOutcome(id: actionId, outcome: result.outcome, afterMB: result.afterMB,
                                         wsBeforeMB: wsBeforeMB, wsAfterMB: result.wsAfterMB) ?? false
        sink?.log(.actions, "actionOutcome id=\(actionId) rule=\(ruleId) outcome=\(result.outcome) afterMB=\(result.afterMB.map { String(format: "%.1f", $0) } ?? "null") wsBeforeMB=\(wsBeforeMB.map { String(format: "%.1f", $0) } ?? "null") wsAfterMB=\(result.wsAfterMB.map { String(format: "%.1f", $0) } ?? "null")")
        sink?.emit("actionOutcome", Self.outcomeJSON(t: now, actionId: actionId, outcome: result.outcome,
                                                     afterMB: result.afterMB, wsBeforeMB: wsBeforeMB,
                                                     wsAfterMB: result.wsAfterMB))
        return ok
    }

    public static func outcomeJSON(t: Double, actionId: Int64, outcome: String, afterMB: Double?,
                                   wsBeforeMB: Double?, wsAfterMB: Double?) -> JSON {
        .object([
            ("type", .string("actionOutcome")),
            ("t", .double(t)),
            ("actionId", .int(actionId)),
            ("outcome", .string(outcome)),
            ("afterMB", .opt(afterMB)),
            ("wsBeforeMB", .opt(wsBeforeMB)),
            ("wsAfterMB", .opt(wsAfterMB)),
        ])
    }
}
