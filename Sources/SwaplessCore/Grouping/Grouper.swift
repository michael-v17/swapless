import Foundation

public enum GroupKind: String, Sendable {
    case app, system, claude, simulator
}

/// What the owner calls an app: a coalition, a Claude Code session or a booted simulator.
public struct ProcessGroup: Sendable {
    /// `coal:<boot>:<cid>` for a coalition group, the root's `proc:` key otherwise (§ F).
    public var key: String
    public var label: String
    public var kind: GroupKind
    /// Bytes; nil when neither a coalition value nor any member value exists.
    public var footprint: UInt64?
    /// The resource coalition, for coalition groups.
    public var coalition: UInt64?
    /// The root process, for Claude session and simulator groups.
    public var rootPid: Int32?
    /// Indexes into `Snapshot.entries`, sorted by footprint, descending (nil last).
    public var members: [Int]
    /// Members without a number of their own (`+ N system processes`).
    public var unreadableCount: Int
    /// X in `+ N system processes: X MB` (total − Σ numbered members, floored at 0).
    public var unreadableBytes: UInt64

    public init(key: String, label: String, kind: GroupKind, footprint: UInt64?,
                coalition: UInt64?, rootPid: Int32? = nil, members: [Int], unreadableCount: Int,
                unreadableBytes: UInt64) {
        self.key = key
        self.label = label
        self.kind = kind
        self.footprint = footprint
        self.coalition = coalition
        self.rootPid = rootPid
        self.members = members
        self.unreadableCount = unreadableCount
        self.unreadableBytes = unreadableBytes
    }
}

/// § G grouping, pure over a `Snapshot`. Precedence: simulator, Claude Code session,
/// coalition; each process lands in exactly one group.
public struct Grouper: Sendable {
    public var labeler: Labeler
    public var home: String

    public init(labeler: Labeler, home: String = NSHomeDirectory()) {
        self.labeler = labeler
        self.home = home
    }

    public func group(_ s: Snapshot) -> [ProcessGroup] {
        let n = s.entries.count
        var children: [Int32: [Int]] = [:]
        var indexOfPid: [Int32: Int] = [:]
        for (i, e) in s.entries.enumerated() {
            indexOfPid[e.pid] = i
            if e.pid != e.ppid { children[e.ppid, default: []].append(i) }
        }
        var assigned = [Bool](repeating: false, count: n)
        var groups: [ProcessGroup] = []

        /// Every ppid-descendant of `root` (root included), in tree order.
        func subtree(_ root: Int) -> [Int] {
            var out: [Int] = []
            var stack = [root]
            var seen = Set<Int>()
            while let i = stack.popLast() {
                guard seen.insert(i).inserted else { continue }
                out.append(i)
                if let kids = children[s.entries[i].pid] { stack.append(contentsOf: kids) }
            }
            return out
        }

        // Step 1: simulators.
        for (i, e) in s.entries.enumerated() where SimulatorResolver.isLaunchdSim(name: e.name, path: e.path) {
            guard !assigned[i] else { continue }
            let members = subtree(i).filter { !assigned[$0] && s.entries[$0].readable }
            guard members.contains(i) else { continue }
            for m in members { assigned[m] = true }
            groups.append(movedGroup(root: i, members: members, kind: .simulator,
                                     label: SimulatorResolver.label(udid: e.simulatorUDID, home: home),
                                     in: s))
        }

        // Step 2: Claude Code sessions, outermost first.
        let isClaude = s.entries.map { ClaudeCode.isClaudeBinary(path: $0.path, home: home) }
        for (i, e) in s.entries.enumerated() where isClaude[i] && !assigned[i] && e.readable {
            // Outermost: no Claude ancestor on the ppid chain.
            var p = e.ppid
            var hops = 0
            var nested = false
            while p > 1, hops < 256, let j = indexOfPid[p] {
                if isClaude[j] {
                    nested = true
                    break
                }
                p = s.entries[j].ppid
                hops += 1
            }
            if nested { continue }
            let members = subtree(i).filter { !assigned[$0] && s.entries[$0].readable }
            for m in members { assigned[m] = true }
            groups.append(movedGroup(root: i, members: members, kind: .claude,
                                     label: ClaudeCode.label(cwdBasename: e.cwdBasename), in: s))
        }

        // Step 3: coalitions, net of the moved members.
        var byCoalition: [UInt64: [Int]] = [:]
        var movedByCoalition: [UInt64: UInt64] = [:]
        for (i, e) in s.entries.enumerated() {
            if assigned[i] {
                movedByCoalition[e.coalition, default: 0] += e.footprint ?? 0
            } else {
                byCoalition[e.coalition, default: []].append(i)
            }
        }
        for (cid, idx) in byCoalition {
            // A coalition group with no remaining members is not shown (it never gets here).
            groups.append(coalitionGroup(cid: cid, members: idx, movedBytes: movedByCoalition[cid] ?? 0,
                                         in: s, indexOfPid: indexOfPid))
        }
        return Self.sorted(groups)
    }

    /// A session or simulator group: the sum of its (readable) members.
    func movedGroup(root: Int, members: [Int], kind: GroupKind, label: String,
                    in s: Snapshot) -> ProcessGroup {
        let ms = members.map { s.entries[$0] }
        return ProcessGroup(
            key: s.entries[root].identity.seriesKey, label: label, kind: kind,
            footprint: Self.sumOfValues(ms), coalition: nil, rootPid: s.entries[root].pid,
            members: Self.sortedMembers(members, in: s), unreadableCount: 0, unreadableBytes: 0)
    }

    /// One coalition group (§ G step 3) from its remaining members.
    func coalitionGroup(cid: UInt64, members idx: [Int], movedBytes: UInt64, in s: Snapshot,
                        indexOfPid: [Int32: Int] = [:]) -> ProcessGroup {
        let members = idx.map { s.entries[$0] }
        let allSystem = members.allSatisfy { $0.euid != s.ownUid }
        let numberedSum = members.reduce(UInt64(0)) { $0 + ($1.footprint ?? 0) }
        let unnumbered = members.filter { $0.footprint == nil }
        var total: UInt64?
        switch s.source {
        case .coalition:
            if cid != 0, let c = s.coalitions[cid] {
                total = c.footprint > movedBytes ? c.footprint - movedBytes : 0
            } else {
                total = Self.sumOfValues(members)
            }
        case .top, .none:
            total = Self.sumOfValues(members)
        }
        let unreadableBytes: UInt64
        if let total {
            unreadableBytes = total > numberedSum ? total - numberedSum : 0
        } else {
            unreadableBytes = 0
        }
        let label = labeler.coalitionLabel(members: members, allSystem: allSystem,
                                           pathOfPid: { pid in indexOfPid[pid].map { s.entries[$0].path } })
        return ProcessGroup(
            key: cid != 0 ? s.coalitionKey(cid) : "coal:\(s.bootSessionUUID):unknown",
            label: label,
            kind: allSystem ? .system : .app,
            footprint: total,
            coalition: cid != 0 ? cid : nil,
            members: Self.sortedMembers(idx, in: s),
            unreadableCount: unnumbered.count,
            unreadableBytes: unreadableBytes)
    }

    /// Σ of the members that have a value; nil when none has one.
    static func sumOfValues(_ members: [ProcessSample]) -> UInt64? {
        var any = false
        var sum: UInt64 = 0
        for m in members {
            if let f = m.footprint {
                any = true
                sum += f
            }
        }
        return any ? sum : nil
    }

    static func sortedMembers(_ idx: [Int], in s: Snapshot) -> [Int] {
        idx.sorted { a, b in
            let fa = s.entries[a].footprint
            let fb = s.entries[b].footprint
            switch (fa, fb) {
            case let (x?, y?): return x != y ? x > y : s.entries[a].pid < s.entries[b].pid
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return s.entries[a].pid < s.entries[b].pid
            }
        }
    }

    /// Descending by footprint; null groups after every numbered group.
    public static func sorted(_ groups: [ProcessGroup]) -> [ProcessGroup] {
        groups.sorted { a, b in
            switch (a.footprint, b.footprint) {
            case let (x?, y?): return x != y ? x > y : a.key < b.key
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.key < b.key
            }
        }
    }

    /// The pids that root a Claude Code session group (for `--dump-snapshot`'s cwdBasename).
    public static func claudeRoots(_ groups: [ProcessGroup]) -> Set<Int32> {
        Set(groups.filter { $0.kind == .claude }.compactMap(\.rootPid))
    }
}
