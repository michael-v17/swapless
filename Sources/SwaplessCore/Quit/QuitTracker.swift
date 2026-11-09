import Foundation

/// What started a check (T4).
public enum QuitTrigger: String, Sendable, Equatable {
    case destroyed
    case deactivated
}

/// Why the watcher must read an app at a given time.
public enum ReadPurpose: Sendable, Equatable {
    /// After `track`, `windowCreated` or `deminiaturized`: arms the app.
    case arm
    /// 0.3 s after a trigger: closed marks plus the first verdict.
    case settle(QuitTrigger, triggerAt: Double)
    /// trigger + 5.0 s.
    case decide
    /// decide + 0.5 s.
    case confirm
}

public struct QuitDecision: Sendable, Equatable {
    public enum Verdict: String, Sendable {
        case quit
        case dryRun = "dry-run"
        case skip
        case cancel
    }

    public var pid: Int32
    public var bundleId: String?
    public var name: String
    public var trigger: QuitTrigger?
    public var verdict: Verdict
    public var reason: String
    public var alive: Int
    public var ax: Int
    public var elsewhere: Int
    public var closed: Int
    public var at: Double
}

public enum TrackerOutput: Sendable, Equatable {
    case read(pid: Int32, at: Double, purpose: ReadPurpose)
    case decision(QuitDecision)
    /// Ask the app to quit (T6). The tracker has already disarmed it.
    case terminate(pid: Int32, bundleId: String, name: String)
}

/// The per-pid state machine (S2). Time is injected; it reads nothing from the system. The
/// watcher executes `read` outputs at their time and feeds the readings back.
public final class QuitTracker {
    struct AppState {
        var facts: AppFacts
        var armed = false
        var pending: (trigger: QuitTrigger, triggerAt: Double)?
        var closed: Set<UInt32> = []
        var disarmed = false
    }

    private var apps: [Int32: AppState] = [:]
    /// Per bundle id: the times of earlier `terminate()` calls (rate limit).
    private var quitTimes: [String: [Double]] = [:]

    public init() {}

    public var trackedCount: Int { apps.count }
    public var armedCount: Int { apps.values.filter(\.armed).count }
    public var pendingPids: [Int32] { apps.filter { $0.value.pending != nil }.map(\.key).sorted() }
    public func isTracked(_ pid: Int32) -> Bool { apps[pid] != nil }
    public func isArmed(_ pid: Int32) -> Bool { apps[pid]?.armed ?? false }
    public func isDisarmed(_ pid: Int32) -> Bool { apps[pid]?.disarmed ?? false }
    public func closedMarks(_ pid: Int32) -> Set<UInt32> { apps[pid]?.closed ?? [] }

    public func track(_ facts: AppFacts, at: Double) -> [TrackerOutput] {
        guard apps[facts.pid] == nil else { return [] }
        apps[facts.pid] = AppState(facts: facts)
        return [.read(pid: facts.pid, at: at, purpose: .arm)]
    }

    /// The app exited. A pending decision ends as `gone` (no row).
    public func untrack(_ pid: Int32, at: Double) -> [TrackerOutput] {
        guard let st = apps.removeValue(forKey: pid) else { return [] }
        guard let p = st.pending else { return [] }
        return [.decision(decision(st, p.trigger, .skip, "gone", Verdict(alive: 0, ax: 0, elsewhere: 0), at))]
    }

    public func trigger(_ pid: Int32, _ kind: QuitTrigger, at: Double) -> [TrackerOutput] {
        guard let st = apps[pid], st.armed else { return [] }
        if kind == .deactivated && st.pending != nil { return [] }
        return [.read(pid: pid, at: at + QuitTiming.settle, purpose: .settle(kind, triggerAt: at))]
    }

    /// `AXWindowCreated` or `AXWindowDeminiaturized`: cancels a pending decision and asks for an
    /// arming read.
    public func windowCreated(_ pid: Int32, at: Double) -> [TrackerOutput] {
        guard var st = apps[pid] else { return [] }
        var out: [TrackerOutput] = []
        if let p = st.pending {
            st.pending = nil
            apps[pid] = st
            out.append(.decision(decision(st, p.trigger, .cancel, "cancelled-window", Verdict(alive: 0, ax: 0, elsewhere: 0), at)))
        }
        out.append(.read(pid: pid, at: at + QuitTiming.settle, purpose: .arm))
        return out
    }

    /// Sleep, lock, display change, Stage Manager, the option off: every pending decision ends.
    public func cancelAll(reason: String, at: Double) -> [TrackerOutput] {
        var out: [TrackerOutput] = []
        for pid in pendingPids {
            guard var st = apps[pid], let p = st.pending else { continue }
            st.pending = nil
            apps[pid] = st
            out.append(.decision(decision(st, p.trigger, .cancel, reason, Verdict(alive: 0, ax: 0, elsewhere: 0), at)))
        }
        return out
    }

    /// A reading the watcher took for `purpose`. `env` is read fresh by the caller.
    public func reading(_ pid: Int32, _ r: WindowReading, facts: AppFacts, env: QuitEnvironment,
                        purpose: ReadPurpose, at: Double) -> [TrackerOutput] {
        guard var st = apps[pid] else { return [] }
        st.facts = facts
        st.closed.subtract(WindowVerdict.axIds(r))
        if case .settle = purpose { st.closed.formUnion(WindowVerdict.closedMarks(r)) }
        let v = WindowVerdict.evaluate(r, closed: st.closed)
        if WindowVerdict.arms(r) && v.error == nil {
            st.armed = true
            st.disarmed = false
        }
        var out: [TrackerOutput] = []
        switch purpose {
        case .arm:
            if let p = st.pending, v.alive > 0 {
                st.pending = nil
                out.append(.decision(decision(st, p.trigger, .cancel, "cancelled-window", v, at)))
            }
        case .settle(let trig, let triggerAt):
            // A trigger while pending only adds marks (and, like any reading, cancels when a
            // window is back).
            if let p = st.pending {
                if v.alive > 0 {
                    st.pending = nil
                    out.append(.decision(decision(st, p.trigger, .cancel, "cancelled-window", v, at)))
                }
                break
            }
            if let e = v.error {
                out.append(.decision(decision(st, trig, .skip, e, v, at)))
            } else if v.alive > 0 {
                out.append(.decision(decision(st, trig, .skip, "alive", v, at)))
            } else {
                st.pending = (trig, triggerAt)
                out.append(.read(pid: pid, at: triggerAt + QuitTiming.grace, purpose: .decide))
            }
        case .decide, .confirm:
            guard let p = st.pending else { break }
            if let e = v.error {
                st.pending = nil
                out.append(.decision(decision(st, p.trigger, .cancel, e, v, at)))
            } else if v.alive > 0 {
                st.pending = nil
                out.append(.decision(decision(st, p.trigger, .cancel, "alive", v, at)))
            } else {
                let g = GateInput(env: env, app: facts, disarmed: st.disarmed,
                                  recentQuits: quitTimes[facts.bundleId ?? ""] ?? [], now: at)
                switch QuitGate.evaluate(g) {
                case .skip(let reason):
                    st.pending = nil
                    out.append(.decision(decision(st, p.trigger, .skip, reason, v, at)))
                case .quit, .dryRun:
                    if purpose == .decide {
                        out.append(.read(pid: pid, at: at + QuitTiming.confirm, purpose: .confirm))
                    } else if env.dryRun {
                        st.pending = nil
                        st.disarmed = true
                        out.append(.decision(decision(st, p.trigger, .dryRun, "dry-run", v, at)))
                    } else {
                        st.pending = nil
                        st.disarmed = true
                        let id = facts.bundleId ?? ""
                        quitTimes[id, default: []].append(at)
                        quitTimes[id] = quitTimes[id]?.filter { at - $0 < QuitTiming.rateLimitWindow }
                        out.append(.decision(decision(st, p.trigger, .quit, "quit", v, at)))
                        out.append(.terminate(pid: pid, bundleId: id, name: facts.name))
                    }
                }
            }
        }
        apps[pid] = st
        return out
    }

    private func decision(_ st: AppState, _ trigger: QuitTrigger?, _ verdict: QuitDecision.Verdict,
                          _ reason: String, _ v: Verdict, _ at: Double) -> QuitDecision {
        QuitDecision(pid: st.facts.pid, bundleId: st.facts.bundleId, name: st.facts.name, trigger: trigger,
                     verdict: verdict, reason: reason, alive: v.alive, ax: v.ax, elsewhere: v.elsewhere,
                     closed: st.closed.count, at: at)
    }
}
