import CSwaplessProc
import Darwin
import Foundation

/// Produces one `Snapshot` per call. Implementations are confined to the engine's queue.
public protocol FootprintSource: AnyObject {
    var kind: FootprintSourceKind { get }
    func sweep() -> Snapshot
}

/// Per-identity facts that don't change during a process's life (spec S1: paths are cached by
/// identity).
struct IdentityFacts {
    var path: String
    var name: String
    var responsiblePid: Int32
    var cwdBasename: String?
    var simulatorUDID: String?
}

/// Diagnostics from the last sweep, used for the runtime degrade rule (spec § A).
public struct SweepDiagnostics: Sendable {
    /// A negative return other than -ESRCH on an all-system coalition.
    public var allSystemCoalitionErrors: Int = 0
    /// The layout-drift return was seen.
    public var drift: Bool = false
    /// The coalition symbol was missing.
    public var symbolMissing: Bool = false
    public var firstError: String?
}

/// The shared sweep (S1 order): KERN_PROC_ALL → flavor 20 → coalitions (coalition mode) →
/// rusage for same-user pids → SystemMemory.
public final class ProcessSweeper: @unchecked Sendable {
    public let ownUid: UInt32
    public let bootSessionUUID: String
    public let hwMemsize: UInt64
    public let home: String
    public let systemMemory = SystemMemory()
    private var facts: [ProcessIdentity: IdentityFacts] = [:]
    /// Optional per-identity enrichers (P2: Claude cwd, simulator UDID).
    var enrich: ((ProcessEntry, inout IdentityFacts) -> Void)?
    public private(set) var lastDiagnostics = SweepDiagnostics()

    public init(ownUid: UInt32 = getuid(), home: String = NSHomeDirectory()) {
        self.ownUid = ownUid
        self.home = home
        self.bootSessionUUID = Sysctl.bootSessionUUID
        self.hwMemsize = Sysctl.hwMemsize
        self.enrich = { entry, facts in
            Enrichment.enrich(entry: entry, facts: &facts, home: home)
        }
    }

    /// One full sweep. `topValues` (top mode only) fills the unreadable pids.
    public func sweep(readCoalitions: Bool, topValues: [Int32: UInt64]?,
                      source: FootprintSourceKind, readSystem: Bool = true) -> Snapshot {
        var diag = SweepDiagnostics()
        let wall = Clock.wall()
        let table = ProcessTable.read()
        let uptime = Clock.uptime()

        // Step 2: flavor 20 for each pid, plus the cached per-identity facts.
        var entries: [ProcessSample] = []
        entries.reserveCapacity(table.count)
        var seen = Set<ProcessIdentity>()
        seen.reserveCapacity(table.count)
        for e in table {
            var res: UInt64 = 0
            var jet: UInt64 = 0
            let rc = sw_coalition_ids(e.pid, &res, &jet)
            if rc == -ESRCH { continue }  // exited mid-sweep
            let id = e.identity
            seen.insert(id)
            let f = facts(for: e, identity: id)
            entries.append(ProcessSample(
                pid: e.pid, ppid: e.ppid, euid: e.euid, startSec: e.startSec,
                startUsec: e.startUsec, name: f.name, path: f.path,
                coalition: rc == 0 ? res : 0, jetsamCoalition: rc == 0 ? jet : 0,
                footprint: nil, lifetimeMax: nil, readable: false,
                responsiblePid: f.responsiblePid, cwdBasename: f.cwdBasename,
                simulatorUDID: f.simulatorUDID))
        }
        if facts.count > seen.count + 64 {
            facts = facts.filter { seen.contains($0.key) }
        }

        // Step 3: one coalition read per distinct coalition, before any member's rusage.
        var coalitions: [UInt64: CoalitionSample] = [:]
        if readCoalitions {
            var allSystem: [UInt64: Bool] = [:]
            for e in entries where e.coalition != 0 {
                let sys = e.euid != ownUid
                allSystem[e.coalition] = (allSystem[e.coalition] ?? true) && sys
            }
            for (cid, isAllSystem) in allSystem {
                var fp: UInt64 = 0
                var started: UInt64 = 0
                var exited: UInt64 = 0
                let rc = sw_coalition_usage(cid, &fp, &started, &exited)
                if rc == 0 {
                    coalitions[cid] = CoalitionSample(cid: cid, footprint: fp, started: started,
                                                      exited: exited)
                } else if rc == -ESRCH {
                    continue
                } else if rc == SW_ERR_LAYOUT_DRIFT {
                    diag.drift = true
                    diag.firstError = diag.firstError ?? "coalition \(cid): layout drift"
                } else if rc == SW_ERR_SYMBOL_MISSING {
                    diag.symbolMissing = true
                    diag.firstError = diag.firstError ?? "coalition symbol missing"
                } else if isAllSystem {
                    diag.allSystemCoalitionErrors += 1
                    diag.firstError = diag.firstError ?? "coalition \(cid): rc \(rc)"
                }
            }
        }

        // Step 4: rusage for same-user pids.
        var out: [ProcessSample] = []
        out.reserveCapacity(entries.count)
        for var e in entries {
            if e.euid == ownUid {
                var ru = sw_rusage_t()
                let rc = sw_pid_rusage(e.pid, &ru)
                if rc == 0 {
                    e.footprint = ru.phys_footprint
                    e.lifetimeMax = ru.lifetime_max_phys_footprint
                    e.readable = true
                } else if rc == -ESRCH {
                    continue  // exited mid-sweep
                }
            }
            if !e.readable, let topValues {
                e.footprint = topValues[e.pid]
            }
            out.append(e)
        }

        // Step 5.
        let system = readSystem ? systemMemory.read(uptime: uptime) : .zero
        lastDiagnostics = diag
        return Snapshot(wallTime: wall, uptime: uptime, bootSessionUUID: bootSessionUUID,
                        hwMemsize: hwMemsize, ownUid: ownUid, entries: out,
                        coalitions: coalitions, system: system, source: source)
    }

    private func facts(for e: ProcessEntry, identity: ProcessIdentity) -> IdentityFacts {
        if let f = facts[identity] { return f }
        let path = ProcessTable.executablePath(pid: e.pid) ?? ""
        let name = path.isEmpty ? e.comm : ProcessTable.basename(path)
        var responsible: Int32 = -1
        if e.euid == ownUid {
            let r = sw_responsible_pid(e.pid)
            responsible = r > 0 ? r : -1
        }
        var f = IdentityFacts(path: path, name: name, responsiblePid: responsible)
        enrich?(e, &f)
        facts[identity] = f
        return f
    }
}

/// Coalition mode: the private coalition totals plus same-user rusage.
public final class LiveSource: FootprintSource, @unchecked Sendable {
    public let sweeper: ProcessSweeper
    public var kind: FootprintSourceKind { .coalition }

    public init(sweeper: ProcessSweeper) { self.sweeper = sweeper }

    public func sweep() -> Snapshot {
        sweeper.sweep(readCoalitions: true, topValues: nil, source: .coalition)
    }
}

/// `top` fallback: `top -l 1` fills only the unreadable pids; same-user pids keep rusage.
public final class TopFallbackSource: FootprintSource, @unchecked Sendable {
    public let sweeper: ProcessSweeper
    private let runTop: () -> Result<[Int32: UInt64], TopRunner.Failure>
    /// pid → the last `top` value. A pid absent from the last run has no value.
    public private(set) var topValues: [Int32: UInt64] = [:]
    public private(set) var topFailed = false
    public private(set) var lastTopUptime: Double?
    public private(set) var lastError: String?

    public init(sweeper: ProcessSweeper,
                runTop: @escaping () -> Result<[Int32: UInt64], TopRunner.Failure> = { TopRunner.run() }) {
        self.sweeper = sweeper
        self.runTop = runTop
    }

    public var kind: FootprintSourceKind { topFailed ? .none : .top }

    /// Runs `top` now. Returns the error message when it failed.
    @discardableResult
    public func refresh() -> String? {
        lastTopUptime = Clock.uptime()
        switch runTop() {
        case .success(let values):
            topValues = values
            topFailed = false
            lastError = nil
            return nil
        case .failure(let f):
            topValues = [:]
            topFailed = true
            lastError = f.description
            return f.description
        }
    }

    public func sweep() -> Snapshot {
        sweeper.sweep(readCoalitions: false, topValues: topFailed ? nil : topValues, source: kind)
    }
}

/// Reads one `--dump-snapshot` file (tests and fixtures).
public final class FixtureSource: FootprintSource, @unchecked Sendable {
    public let snapshot: Snapshot
    public var kind: FootprintSourceKind { snapshot.source }

    public init(snapshot: Snapshot) { self.snapshot = snapshot }

    public convenience init(data: Data, home: String = "/Users/fixture", ownUid: UInt32 = 501,
                            source: FootprintSourceKind = .coalition) throws {
        self.init(snapshot: try SnapshotDump.decode(data, home: home, ownUid: ownUid,
                                                    source: source))
    }

    public func sweep() -> Snapshot { snapshot }
}

/// The `--dump-snapshot` format (spec § K).
public enum SnapshotDump {
    public struct DecodeError: Error, CustomStringConvertible {
        public let description: String
    }

    public static func encode(_ s: Snapshot, home: String, claudeRoots: Set<Int32>) -> JSON {
        let entries: [JSON] = s.entries.map { e in
            .object([
                ("pid", .i(e.pid)),
                ("ppid", .i(e.ppid)),
                ("euid", .uint(UInt64(e.euid))),
                ("startSec", .int(e.startSec)),
                ("startUsec", .i(e.startUsec)),
                ("coalition", .uint(e.coalition)),
                ("jetsamCoalition", .uint(e.jetsamCoalition)),
                ("name", .string(e.name)),
                ("path", .string(PathSanitizer.sanitize(e.path, home: home))),
                ("footprint", .opt(e.footprint)),
                ("lifetimeMax", .opt(e.lifetimeMax)),
                ("responsiblePid", .i(e.responsiblePid)),
                ("cwdBasename", claudeRoots.contains(e.pid) ? .opt(e.cwdBasename) : .null),
                ("simulatorUDID", .opt(e.simulatorUDID)),
            ])
        }
        let coalitions: [JSON] = s.coalitions.values.sorted { $0.cid < $1.cid }.map { c in
            .object([
                ("cid", .uint(c.cid)),
                ("footprint", .uint(c.footprint)),
                ("started", .uint(c.started)),
                ("exited", .uint(c.exited)),
            ])
        }
        return .object([
            ("bootSessionUUID", .string(s.bootSessionUUID)),
            ("hwMemsize", .uint(s.hwMemsize)),
            ("t", .double(s.wallTime)),
            ("entries", .array(entries)),
            ("coalitions", .array(coalitions)),
            ("system", systemJSON(s.system)),
        ])
    }

    public static func systemJSON(_ sys: SystemSample) -> JSON {
        .object([
            ("freePct", .i(sys.freePct)),
            ("pressure", .i(sys.pressure)),
            ("swapUsedBytes", .uint(sys.swapUsedBytes)),
            ("swapinBytesPerSec", .opt(sys.swapinBytesPerSec)),
            ("swapinsTotal", .uint(sys.swapinsTotal)),
            ("compressedBytes", .uint(sys.compressedBytes)),
        ])
    }

    public static func decode(_ data: Data, home: String, ownUid: UInt32,
                              source: FootprintSourceKind) throws -> Snapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeError(description: "not an object")
        }
        func req<T>(_ v: T?, _ what: String) throws -> T {
            guard let v else { throw DecodeError(description: "bad or missing \(what)") }
            return v
        }
        let boot = try req(JSONRead.string(root["bootSessionUUID"]), "bootSessionUUID")
        let mem = try req(JSONRead.uint64(root["hwMemsize"]), "hwMemsize")
        let t = try req(JSONRead.double(root["t"]), "t")
        let rawEntries = try req(root["entries"] as? [[String: Any]], "entries")
        var entries: [ProcessSample] = []
        for r in rawEntries {
            let euid = UInt32(try req(JSONRead.int(r["euid"]), "euid"))
            let fp = JSONRead.uint64(r["footprint"])
            entries.append(ProcessSample(
                pid: Int32(try req(JSONRead.int(r["pid"]), "pid")),
                ppid: Int32(try req(JSONRead.int(r["ppid"]), "ppid")),
                euid: euid,
                startSec: Int64(try req(JSONRead.int(r["startSec"]), "startSec")),
                startUsec: Int32(try req(JSONRead.int(r["startUsec"]), "startUsec")),
                name: try req(JSONRead.string(r["name"]), "name"),
                path: PathSanitizer.expand(try req(JSONRead.string(r["path"]), "path"), home: home),
                coalition: try req(JSONRead.uint64(r["coalition"]), "coalition"),
                jetsamCoalition: JSONRead.uint64(r["jetsamCoalition"]) ?? 0,
                footprint: fp,
                lifetimeMax: JSONRead.uint64(r["lifetimeMax"]),
                readable: euid == ownUid && fp != nil,
                responsiblePid: Int32(JSONRead.int(r["responsiblePid"]) ?? -1),
                cwdBasename: JSONRead.string(r["cwdBasename"]),
                simulatorUDID: JSONRead.string(r["simulatorUDID"])))
        }
        var coalitions: [UInt64: CoalitionSample] = [:]
        for c in (root["coalitions"] as? [[String: Any]]) ?? [] {
            let cid = try req(JSONRead.uint64(c["cid"]), "cid")
            coalitions[cid] = CoalitionSample(
                cid: cid, footprint: JSONRead.uint64(c["footprint"]) ?? 0,
                started: JSONRead.uint64(c["started"]) ?? 0,
                exited: JSONRead.uint64(c["exited"]) ?? 0)
        }
        var system = SystemSample.zero
        if let s = root["system"] as? [String: Any] {
            system = SystemSample(
                freePct: JSONRead.int(s["freePct"]) ?? 0,
                pressure: JSONRead.int(s["pressure"]) ?? 1,
                swapUsedBytes: JSONRead.uint64(s["swapUsedBytes"]) ?? 0,
                swapinBytesPerSec: JSONRead.double(s["swapinBytesPerSec"]),
                swapinsTotal: JSONRead.uint64(s["swapinsTotal"]) ?? 0,
                compressedBytes: JSONRead.uint64(s["compressedBytes"]) ?? 0)
        }
        return Snapshot(wallTime: t, uptime: 0, bootSessionUUID: boot, hwMemsize: mem,
                        ownUid: ownUid, entries: entries, coalitions: coalitions,
                        system: system, source: source)
    }
}

/// Per-identity enrichment: the Claude cwd basename and the simulator UDID (same-user only).
enum Enrichment {
    static func enrich(entry: ProcessEntry, facts: inout IdentityFacts, home: String) {
        guard entry.euid == getuid() else { return }
        if ClaudeCode.isClaudeBinary(path: facts.path, home: home) {
            if let cwd = ProcessTable.workingDirectory(pid: entry.pid) {
                // Only the basename is ever kept.
                facts.cwdBasename = ProcessTable.basename(cwd)
            }
        }
        if SimulatorResolver.isLaunchdSim(name: facts.name, path: facts.path) {
            facts.simulatorUDID = SimulatorResolver.udid(pid: entry.pid)
        }
    }
}
