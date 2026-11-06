import Foundation

/// A process the evaluator resolved from the snapshot by exact path + euid == ownUid.
public struct ResolvedProcess: Sendable, Equatable, Hashable {
    public var pid: Int32
    public var identity: ProcessIdentity
    public var path: String
    public var euid: UInt32
    public var footprint: UInt64

    public init(pid: Int32, identity: ProcessIdentity, path: String, euid: UInt32, footprint: UInt64) {
        self.pid = pid
        self.identity = identity
        self.path = path
        self.euid = euid
        self.footprint = footprint
    }
}

/// What a fire asks the actuator to do. Only code can name the target (§ J).
public struct Intent: Sendable, Equatable {
    public var ruleId: String
    public var target: RestartTarget
    /// The trigger processes (wallpaper: every extension instance; rigHelper: one identity).
    public var trigger: [ResolvedProcess]
    /// The restart set, in signalling order (extensions first, then agents).
    public var restartSet: [ResolvedProcess]
    public var beforeMB: Double
}

/// A decision line (transitions only).
public struct Decision: Sendable, Equatable {
    public var ruleId: String
    public var reason: String

    public init(ruleId: String, reason: String) {
        self.ruleId = ruleId
        self.reason = reason
    }
}

/// The evaluator's memory between base ticks.
public struct EvaluatorState: Sendable, Equatable {
    /// wallpaper: the extension identity set of the previous tick and its consecutive count.
    var wallpaperSet: [String: Set<ProcessIdentity>] = [:]
    var wallpaperCount: [String: Int] = [:]
    /// rigHelper: per-identity consecutive counts.
    var identityCounts: [String: [ProcessIdentity: Int]] = [:]
    /// The last reason emitted per rule (nil after a fire).
    public var lastReason: [String: String] = [:]

    public init() {}

    /// A fire resets the last reason.
    public mutating func didFire(ruleId: String) { lastReason[ruleId] = nil }

    /// Records a decision that came from § J (identity-changed, history-off).
    public mutating func emitted(ruleId: String, reason: String) -> Bool {
        guard lastReason[ruleId] != reason else { return false }
        lastReason[ruleId] = reason
        return true
    }
}

/// Inputs that are not the snapshot.
public struct EvaluationContext: Sendable {
    public var now: Double
    public var ownUid: UInt32
    /// Actions of the last 24 h (dry runs and `interrupted` included).
    public var actions: [ActionRow]
    /// rule id → paused reason.
    public var pauses: [String: String]
    /// Rules whose verify is still in flight.
    public var verifying: Set<String>
    /// `SWAPLESS_RIG_HELPER_PATH` (DEBUG only).
    public var rigHelperPath: String?

    public init(now: Double, ownUid: UInt32, actions: [ActionRow], pauses: [String: String],
                verifying: Set<String>, rigHelperPath: String?) {
        self.now = now
        self.ownUid = ownUid
        self.actions = actions
        self.pauses = pauses
        self.verifying = verifying
        self.rigHelperPath = rigHelperPath
    }
}

/// § I evaluation, pure: (snapshot, rules, action history, rule_state) → [Intent] + [Decision].
public enum RuleEvaluator {
    public static let mib = 1_048_576.0

    /// The action that reaches maxPerDay (dry runs and `interrupted` included) also writes a
    /// `max-per-day` pause.
    public static func reachesMaxPerDay(rule: Rule, actions: [ActionRow], now: Double) -> Bool {
        actions.filter { $0.ruleId == rule.id && now - $0.ts < 86400 }.count >= rule.maxPerDay
    }

    /// Same-euid processes at exactly `path`.
    public static func resolve(_ s: Snapshot, path: String, ownUid: UInt32) -> [ResolvedProcess] {
        s.entries.filter { $0.path == path && $0.euid == ownUid }.map {
            ResolvedProcess(pid: $0.pid, identity: $0.identity, path: $0.path, euid: $0.euid,
                            footprint: $0.footprint ?? 0)
        }.sorted { $0.pid < $1.pid }
    }

    /// The trigger processes of a target.
    public static func triggers(_ target: RestartTarget, in s: Snapshot, ctx: EvaluationContext) -> [ResolvedProcess] {
        switch target {
        case .wallpaper:
            return resolve(s, path: RestartTarget.wallpaperExtensionPath, ownUid: ctx.ownUid)
        #if DEBUG
        case .rigHelper:
            guard let p = ctx.rigHelperPath else { return [] }
            return resolve(s, path: p, ownUid: ctx.ownUid)
                .filter { ProcessTable.basename($0.path) == RestartTarget.rigHelperBasename }
        #endif
        }
    }

    public static func evaluate(snapshot s: Snapshot, rules: RulesLoad, ctx: EvaluationContext,
                                state: inout EvaluatorState) -> (intents: [Intent], decisions: [Decision]) {
        var intents: [Intent] = []
        var decisions: [Decision] = []
        func decide(_ id: String, _ reason: String) {
            guard !id.isEmpty, state.lastReason[id] != reason else { return }
            state.lastReason[id] = reason
            decisions.append(Decision(ruleId: id, reason: reason))
        }

        for entry in rules.status == .ok ? rules.entries : [] {
            // 1. Invalid or disabled.
            guard let rule = entry.rule else {
                decide(entry.id, "disabled")
                continue
            }
            let trig = triggers(rule.target, in: s, ctx: ctx)
            // Consecutive counts are tracked on every base tick, whatever the reason.
            let readiness = updateCounts(rule: rule, triggers: trig, state: &state)

            if !rule.enabled {
                decide(rule.id, "disabled")
                continue
            }
            // 2. Paused.
            if ctx.pauses[rule.id] != nil {
                decide(rule.id, "paused")
                continue
            }
            // 3. Target absent.
            if trig.isEmpty {
                decide(rule.id, "target-absent")
                continue
            }
            // 4–5. Per-candidate readiness (wallpaper: one candidate, the whole set).
            guard let best = readiness.max(by: { $0.stage < $1.stage }) else {
                decide(rule.id, "target-absent")
                continue
            }
            if best.stage == .below {
                decide(rule.id, "below-threshold")
                continue
            }
            if best.stage == .pending {
                decide(rule.id, "consecutive-pending")
                continue
            }
            // 6. Cooldown: a verify in flight, or the previous action too recent.
            let mine = ctx.actions.filter { $0.ruleId == rule.id }
            if ctx.verifying.contains(rule.id)
                || mine.contains(where: { ctx.now - $0.ts < Double(rule.cooldownMinutes) * 60 }) {
                decide(rule.id, "cooldown")
                continue
            }
            // 7. Max per day.
            if mine.filter({ ctx.now - $0.ts < 86400 }).count >= rule.maxPerDay {
                decide(rule.id, "max-per-day")
                continue
            }
            // 8. Fire.
            let restart = restartSet(rule.target, trigger: best.trigger, in: s, ctx: ctx)
            let before = Double(best.trigger.reduce(UInt64(0)) { $0 + $1.footprint }) / mib
            intents.append(Intent(ruleId: rule.id, target: rule.target, trigger: best.trigger,
                                  restartSet: restart, beforeMB: before))
            state.didFire(ruleId: rule.id)
        }
        return (intents, decisions)
    }

    enum Stage: Int, Comparable {
        case below = 0, pending = 1, ready = 2
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    struct Readiness {
        var stage: Stage
        var trigger: [ResolvedProcess]
    }

    /// Steps 4–5 for every candidate, updating the consecutive counts.
    static func updateCounts(rule: Rule, triggers trig: [ResolvedProcess],
                             state: inout EvaluatorState) -> [Readiness] {
        let threshold = rule.thresholdBytes
        switch rule.target {
        case .wallpaper:
            // The identity is the set of same-euid extension identities; any change restarts
            // the count at 1. The trigger footprint is their sum.
            let set = Set(trig.map(\.identity))
            let sum = trig.reduce(UInt64(0)) { $0 + $1.footprint }
            let above = !trig.isEmpty && sum > threshold
            let prevSet = state.wallpaperSet[rule.id]
            var count = state.wallpaperCount[rule.id] ?? 0
            if above {
                count = (prevSet == set && count > 0) ? count + 1 : 1
            } else {
                count = 0
            }
            state.wallpaperSet[rule.id] = set
            state.wallpaperCount[rule.id] = count
            guard !trig.isEmpty else { return [] }
            let stage: Stage = !above ? .below : (count >= rule.consecutiveSamples ? .ready : .pending)
            return [Readiness(stage: stage, trigger: trig)]
        #if DEBUG
        case .rigHelper:
            // Each identity keeps its own count and is its own trigger.
            var counts = state.identityCounts[rule.id] ?? [:]
            var next: [ProcessIdentity: Int] = [:]
            var out: [Readiness] = []
            for p in trig {
                let above = p.footprint > threshold
                let c = above ? (counts[p.identity] ?? 0) + 1 : 0
                next[p.identity] = c
                let stage: Stage = !above ? .below : (c >= rule.consecutiveSamples ? .ready : .pending)
                out.append(Readiness(stage: stage, trigger: [p]))
            }
            counts = next
            state.identityCounts[rule.id] = counts
            return out
        #endif
        }
    }

    /// The restart set: wallpaper = every extension instance then every agent; rigHelper = only
    /// the triggering identity.
    static func restartSet(_ target: RestartTarget, trigger: [ResolvedProcess], in s: Snapshot,
                           ctx: EvaluationContext) -> [ResolvedProcess] {
        switch target {
        case .wallpaper:
            return resolve(s, path: RestartTarget.wallpaperExtensionPath, ownUid: ctx.ownUid)
                + resolve(s, path: RestartTarget.wallpaperAgentPath, ownUid: ctx.ownUid)
        #if DEBUG
        case .rigHelper:
            return trigger
        #endif
        }
    }
}
