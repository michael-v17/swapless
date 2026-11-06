import Darwin
import Foundation

/// A child process the rig owns: engines, helpers, `log stream`. Stdout is captured line by
/// line with the wall time each line arrived.
final class Child: @unchecked Sendable {
    let name: String
    let process = Process()
    private let cond = NSCondition()
    private var _lines: [(t: Double, text: String)] = []
    private var _eof = false
    private var reader: Thread?
    private var parsedCache: [Int: [String: Any]] = [:]

    init(name: String, executable: String, arguments: [String], environment: [String: String],
         stderrPath: String? = nil) {
        self.name = name
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        if let stderrPath {
            FileManager.default.createFile(atPath: stderrPath, contents: nil)
            process.standardError = FileHandle(forWritingAtPath: stderrPath) ?? FileHandle.nullDevice
        } else {
            process.standardError = FileHandle.nullDevice
        }
    }

    func start() throws {
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        Children.shared.add(self)
        let handle = pipe.fileHandleForReading
        let t = Thread { [weak self] in
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[buffer.startIndex..<nl]
                    buffer = Data(buffer[buffer.index(after: nl)...])
                    self?.append(String(decoding: lineData, as: UTF8.self))
                }
            }
            if !buffer.isEmpty { self?.append(String(decoding: buffer, as: UTF8.self)) }
            self?.markEOF()
        }
        t.stackSize = 1 << 20
        t.start()
        reader = t
    }

    private func append(_ line: String) {
        let now = Date().timeIntervalSince1970
        cond.lock()
        _lines.append((now, line))
        cond.broadcast()
        cond.unlock()
    }

    private func markEOF() {
        cond.lock()
        _eof = true
        cond.broadcast()
        cond.unlock()
    }

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    var lineCount: Int {
        cond.lock()
        defer { cond.unlock() }
        return _lines.count
    }

    func lines() -> [(t: Double, text: String)] {
        cond.lock()
        defer { cond.unlock() }
        return _lines
    }

    /// Parsed JSON object of line `i` (cached).
    func json(_ i: Int) -> [String: Any]? {
        cond.lock()
        if let c = parsedCache[i] {
            cond.unlock()
            return c
        }
        guard i < _lines.count else {
            cond.unlock()
            return nil
        }
        let text = _lines[i].text
        cond.unlock()
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        cond.lock()
        parsedCache[i] = obj
        cond.unlock()
        return obj
    }

    /// All parsed JSON lines (with arrival times) of the given type.
    func events(_ type: String) -> [(t: Double, obj: [String: Any])] {
        let ls = lines()
        var out: [(Double, [String: Any])] = []
        for (i, l) in ls.enumerated() where l.text.contains("\"type\":\"\(type)\"") {
            if let o = json(i), (o["type"] as? String) == type { out.append((l.t, o)) }
        }
        return out
    }

    /// Waits until a line from index `from` on satisfies `match`; returns its index.
    @discardableResult
    func waitLine(from: Int = 0, timeout: Double, _ match: (Int, String) -> Bool) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        var next = from
        cond.lock()
        defer { cond.unlock() }
        while true {
            while next < _lines.count {
                let idx = next
                let text = _lines[idx].text
                next += 1
                cond.unlock()
                let ok = match(idx, text)
                cond.lock()
                if ok { return idx }
            }
            if _eof { return nil }
            if !cond.wait(until: deadline) { return nil }
        }
    }

    /// Waits for the next JSON event of `type` (from line index `from`) that satisfies `match`.
    func waitEvent(_ type: String, from: Int = 0, timeout: Double,
                   _ match: ([String: Any]) -> Bool = { _ in true }) -> (index: Int, obj: [String: Any])? {
        var found: [String: Any]?
        let idx = waitLine(from: from, timeout: timeout) { i, text in
            guard text.contains("\"type\":\"\(type)\"") else { return false }
            guard let o = self.json(i), (o["type"] as? String) == type, match(o) else { return false }
            found = o
            return true
        }
        guard let idx, let found else { return nil }
        return (idx, found)
    }

    /// SIGTERM (never SIGKILL).
    func terminate() {
        if process.isRunning { kill(process.processIdentifier, SIGTERM) }
    }

    /// Waits for exit; true if it exited within the timeout. Every caller expects the exit,
    /// so running out records a TIMEOUT, which fails the check.
    @discardableResult
    func waitExit(timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                Timeouts.shared.record("\(name) (pid \(pid)) still running \(Int(timeout)) s after it was due to exit")
                return false
            }
            usleep(50_000)
        }
        // Let the reader drain.
        cond.lock()
        let end = Date().addingTimeInterval(2)
        while !_eof { if !cond.wait(until: end) { break } }
        cond.unlock()
        return true
    }

    /// SIGTERM, then wait.
    func stop(timeout: Double = 10) {
        terminate()
        waitExit(timeout: timeout)
    }

    var exitStatus: Int32 { process.terminationStatus }
    var exitedNormally: Bool { process.terminationReason == .exit }
    /// "Exits on its own" = exit status 0, not 143, not a death by signal.
    var exitedOnItsOwn: Bool { !process.isRunning && exitedNormally && exitStatus == 0 }
}

/// Waits that ran out (owner, 2026-11-05: a run never hangs silently). Recorded where they
/// happen, printed to stderr at once, and turned into a FAIL of the check they happened in.
final class Timeouts: @unchecked Sendable {
    static let shared = Timeouts()
    private let lock = NSLock()
    private var list: [String] = []

    func record(_ what: String) {
        lock.lock()
        list.append(what)
        lock.unlock()
        FileHandle.standardError.write(Data("rig: TIMEOUT: \(what)\n".utf8))
    }

    func drain() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let out = list
        list.removeAll()
        return out
    }
}

/// Stdout of a short-lived tool, read to EOF with a deadline (the rig never signals tools,
/// so on timeout it stops waiting and records it).
final class ToolOutput: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var data = Data()

    /// nil if `process` gave no EOF and exit within `timeout` s.
    static func read(_ process: Process, _ pipe: Pipe, timeout: Double, what: String) -> Data? {
        let box = ToolOutput()
        let handle = pipe.fileHandleForReading
        DispatchQueue.global().async {
            box.data = handle.readDataToEndOfFile()
            box.done.signal()
        }
        let deadline = Date().addingTimeInterval(timeout)
        let gotEOF = box.done.wait(timeout: .now() + timeout) == .success
        while gotEOF, process.isRunning, Date() < deadline { usleep(20_000) }
        if !gotEOF || process.isRunning {
            Timeouts.shared.record("\(what) (pid \(process.processIdentifier)) gave no result in \(Int(timeout)) s (left running; the rig never signals tools)")
            return nil
        }
        return box.data
    }
}

/// Every child the rig spawned, for cleanup on every exit path.
final class Children: @unchecked Sendable {
    static let shared = Children()
    private let lock = NSLock()
    private var all: [Child] = []
    private var extraPids: Set<Int32> = []

    func add(_ c: Child) {
        lock.lock()
        all.append(c)
        lock.unlock()
    }

    /// Short-lived tools the rig ran (top, footprint, ps…), for coverage exclusions.
    func addPid(_ pid: Int32) {
        lock.lock()
        extraPids.insert(pid)
        lock.unlock()
    }

    var pids: Set<Int32> {
        lock.lock()
        defer { lock.unlock() }
        return Set(all.map(\.pid)).union(extraPids)
    }

    /// SIGTERM every live child and wait a little.
    func stopAll() {
        lock.lock()
        let live = all.filter(\.isRunning)
        lock.unlock()
        for c in live { c.terminate() }
        for c in live { c.waitExit(timeout: 10) }
    }
}
