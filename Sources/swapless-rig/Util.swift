import CSwaplessProc
import Darwin
import Foundation
import SwaplessCore

let MiB = 1_048_576.0

/// Sizes print in MiB, the unit every rig limit is stated in.
func mb(_ bytes: Double) -> String { String(format: "%.1f MiB", bytes / MiB) }
func mb(_ bytes: UInt64) -> String { mb(Double(bytes)) }
func now() -> Double { Date().timeIntervalSince1970 }

func realpathString(_ p: String) -> String {
    guard let r = realpath(p, nil) else { return p }
    defer { free(r) }
    return String(cString: r)
}

/// Output: stdout plus `.build/rig/rig-<yyyymmdd-hhmmss>-<mode>.txt`.
final class Report: @unchecked Sendable {
    let path: String
    private let handle: FileHandle?
    private let lock = NSLock()
    private(set) var failures: [String] = []
    private(set) var skips: [String] = []

    init(dir: String, mode: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        path = "\(dir)/rig-\(f.string(from: Date()))-\(mode).txt"
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }

    func line(_ s: String) {
        lock.lock()
        defer { lock.unlock() }
        let text = PathSanitizer.sanitize(s, home: NSHomeDirectory()).replacingOccurrences(
            of: NSHomeDirectory() + "/", with: "~/")
        print(text)
        fflush(stdout)
        handle?.write(Data((text + "\n").utf8))
    }

    func result(_ check: String, _ outcome: Outcome) {
        switch outcome {
        case .pass(let why): line("\(check): PASS \(why)")
        case .fail(let why):
            failures.append("\(check): \(why)")
            line("\(check): FAIL \(why)")
        case .skip(let why):
            skips.append("\(check): \(why)")
            line("\(check): SKIP \(why)")
        }
    }
}

enum Outcome {
    case pass(String)
    case fail(String)
    case skip(String)

    var isFail: Bool {
        if case .fail = self { return true }
        return false
    }
}

/// Thrown by a check to stop it with a FAIL.
struct CheckFailure: Error {
    let why: String
}

/// Everything the checks share.
final class Rig: @unchecked Sendable {
    let debugBin: String
    let releaseBin: String
    let repoRoot: String
    let rigDir: String
    let report: Report
    let uid = getuid()
    var wallpaperBaseline: [ProcessIdentity] = []
    var tempDirs: [String] = []

    init(debugBin: String, releaseBin: String, repoRoot: String, rigDir: String, report: Report) {
        self.debugBin = debugBin
        self.releaseBin = releaseBin
        self.repoRoot = repoRoot
        self.rigDir = rigDir
        self.report = report
    }

    var debugEngine: String { "\(debugBin)/Swapless" }
    var releaseEngine: String { "\(releaseBin)/Swapless" }
    /// `realpath(<debug-bin>/swapless-leak-helper)`: spawned by this exact string, so it equals
    /// `proc_pidpath` (`.build/debug` is a symlink).
    var helperPath: String { realpathString("\(debugBin)/swapless-leak-helper") }

    /// The current environment minus every `SWAPLESS_*` variable.
    func baseEnv() -> [String: String] {
        ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("SWAPLESS_") }
    }

    /// A fresh temp state dir with `rules.json` written first.
    func tempStateDir(rules: String = "{\"version\":1,\"rules\":[]}") throws -> String {
        var template = Array((NSTemporaryDirectory() + "swapless-rig.XXXXXX").utf8CString)
        guard let p = mkdtemp(&template) else { throw CheckFailure(why: "mkdtemp failed") }
        let dir = String(cString: p)
        try rules.write(toFile: dir + "/rules.json", atomically: true, encoding: .utf8)
        tempDirs.append(dir)
        return dir
    }

    // MARK: engines and helpers

    struct EngineRun {
        let child: Child
        let stateDir: String
        let start: [String: Any]
        let rules: [String: Any]
    }

    /// Starts a headless engine and applies the start-line guard (S6).
    func startEngine(name: String, release: Bool = false, stateDir: String,
                     env extra: [String: String], duration: Double,
                     expectDryRun: Bool, expectRulesStatus: String = "ok",
                     arguments: [String]? = nil) throws -> EngineRun {
        var env = baseEnv()
        env["SWAPLESS_STATE_DIR"] = stateDir
        for (k, v) in extra { env[k] = v }
        let args = arguments ?? ["--headless", "--duration", String(Int(duration.rounded(.up)))]
        let child = Child(name: name, executable: release ? releaseEngine : debugEngine,
                          arguments: args, environment: env,
                          stderrPath: "\(rigDir)/\(name).stderr")
        try child.start()
        guard let s = child.waitEvent("start", timeout: 60) else {
            child.stop()
            throw CheckFailure(why: "\(name): no start line (exit \(child.isRunning ? -1 : child.exitStatus))")
        }
        guard let r = child.waitEvent("rules", from: s.index + 1, timeout: 30) else {
            child.stop()
            throw CheckFailure(why: "\(name): no rules line")
        }
        // Start-line guard: dryRun, stateDir and the rules status must be what we set up.
        let dry = (s.obj["dryRun"] as? Bool) ?? !expectDryRun
        let sd = (s.obj["stateDir"] as? String) ?? ""
        let status = (r.obj["status"] as? String) ?? ""
        var bad: [String] = []
        if dry != expectDryRun { bad.append("dryRun=\(dry), expected \(expectDryRun)") }
        if realpathString(sd) != realpathString(stateDir) { bad.append("stateDir=\(sd)") }
        if status != expectRulesStatus { bad.append("rules status=\(status), expected \(expectRulesStatus)") }
        if !bad.isEmpty {
            child.stop()
            throw CheckFailure(why: "\(name): start-line guard: " + bad.joined(separator: ", "))
        }
        return EngineRun(child: child, stateDir: stateDir, start: s.obj, rules: r.obj)
    }

    func startHelper(name: String, _ args: [String]) throws -> Child {
        let c = Child(name: name, executable: helperPath, arguments: args, environment: baseEnv(),
                      stderrPath: "\(rigDir)/\(name).stderr")
        try c.start()
        return c
    }

    // MARK: tools

    /// Runs a tool to completion; its pid joins the coverage exclusions.
    /// A short-lived tool, with a deadline: on timeout, status -2 and a recorded TIMEOUT.
    func run(_ exe: String, _ args: [String], timeout: Double = 300) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        Children.shared.addPid(p.processIdentifier)
        let what = ([(exe as NSString).lastPathComponent] + args.prefix(2)).joined(separator: " ")
        guard let data = ToolOutput.read(p, pipe, timeout: timeout, what: what) else { return (-2, "") }
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    struct TopRun {
        let t0: Double
        let t1: Double
        let values: [Int32: UInt64]
        let pid: Int32
    }

    /// `top -l 1 -stats pid,mem`, with the wall time before (T0) and after (T1).
    func top() throws -> TopRun {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        p.arguments = ["-l", "1", "-stats", "pid,mem"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let t0 = now()
        try p.run()
        Children.shared.addPid(p.processIdentifier)
        guard let data = ToolOutput.read(p, pipe, timeout: 60, what: "top -l 1") else {
            throw CheckFailure(why: "top -l 1 gave no result in 60 s")
        }
        let t1 = now()
        guard p.terminationStatus == 0 else { throw CheckFailure(why: "top exited \(p.terminationStatus)") }
        let values = try TopParser.parse(String(decoding: data, as: UTF8.self))
        return TopRun(t0: t0, t1: t1, values: values, pid: p.processIdentifier)
    }

    /// `footprint -p <pid> -f bytes --noCategories`: (phys_footprint, phys_footprint_peak).
    func footprintTool(pid: Int32) -> (phys: UInt64, peak: UInt64)? {
        let r = run("/usr/bin/footprint", ["-p", String(pid), "-f", "bytes", "--noCategories"], timeout: 60)
        guard r.status == 0 else { return nil }
        var phys: UInt64?
        var peak: UInt64?
        for line in r.out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("phys_footprint:") {
                phys = UInt64(t.dropFirst("phys_footprint:".count).trimmingCharacters(in: .whitespaces)
                    .split(separator: " ").first ?? "")
            } else if t.hasPrefix("phys_footprint_peak:") {
                peak = UInt64(t.dropFirst("phys_footprint_peak:".count).trimmingCharacters(in: .whitespaces)
                    .split(separator: " ").first ?? "")
            }
        }
        guard let phys, let peak else { return nil }
        return (phys, peak)
    }

    /// `ps -o time= -p <pid>` in seconds.
    func psTime(pid: Int32) -> Double? {
        let r = run("/bin/ps", ["-o", "time=", "-p", String(pid)], timeout: 60)
        guard r.status == 0 else { return nil }
        return parsePsTime(r.out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: processes

    /// Same-euid processes at an exact path.
    func processes(atPath path: String) -> [ProcessEntry] {
        ProcessTable.read().filter { $0.euid == uid && ProcessTable.executablePath(pid: $0.pid) == path }
    }

    /// The identities of the real WallpaperAgent and WallpaperImageExtension.
    func wallpaperIdentities() -> [ProcessIdentity] {
        let table = ProcessTable.read()
        var ids: [ProcessIdentity] = []
        for e in table where e.euid == uid {
            guard let p = ProcessTable.executablePath(pid: e.pid) else { continue }
            if p == RestartTarget.wallpaperAgentPath || p == RestartTarget.wallpaperExtensionPath {
                ids.append(e.identity)
            }
        }
        return ids.sorted { $0.pid < $1.pid }
    }

    func freePct() -> Int { Sysctl.int("kern.memorystatus_level") ?? 0 }

    func cleanup() {
        for d in tempDirs { try? FileManager.default.removeItem(atPath: d) }
        tempDirs.removeAll()
    }
}

/// `[[dd-]hh:]mm:ss.cc` → seconds.
func parsePsTime(_ s: String) -> Double? {
    var rest = Substring(s)
    var days = 0.0
    if let dash = rest.firstIndex(of: "-") {
        days = Double(rest[..<dash]) ?? 0
        rest = rest[rest.index(after: dash)...]
    }
    let parts = rest.split(separator: ":").map { Double($0) }
    guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
    let v = parts.map { $0! }
    var total = 0.0
    for x in v { total = total * 60 + x }
    return total + days * 86400
}

/// Helpers over parsed `sample` lines.
enum SampleView {
    static func members(_ sample: [String: Any]) -> [[String: Any]] {
        ((sample["groups"] as? [[String: Any]]) ?? []).flatMap { ($0["members"] as? [[String: Any]]) ?? [] }
    }

    static func member(_ sample: [String: Any], pid: Int32) -> [String: Any]? {
        members(sample).first { (JSONRead.int($0["pid"]) ?? -1) == Int(pid) }
    }

    static func footprint(_ m: [String: Any]?) -> UInt64? { JSONRead.uint64(m?["footprint"]) }

    static func t(_ sample: [String: Any]) -> Double { JSONRead.double(sample["t"]) ?? 0 }

    static func groups(_ sample: [String: Any]) -> [[String: Any]] {
        (sample["groups"] as? [[String: Any]]) ?? []
    }

    /// The group that contains `pid`.
    static func group(_ sample: [String: Any], containing pid: Int32) -> [String: Any]? {
        groups(sample).first { g in
            ((g["members"] as? [[String: Any]]) ?? []).contains { (JSONRead.int($0["pid"]) ?? -1) == Int(pid) }
        }
    }
}

func inRange(_ v: Double, _ a: Double, _ b: Double, tol: Double) -> Bool {
    v >= min(a, b) - tol && v <= max(a, b) + tol
}
