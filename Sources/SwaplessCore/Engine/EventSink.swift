import Foundation
import os

/// `os_log` categories (§ K).
public enum LogCategory: String, Sendable, CaseIterable {
    case sampler, grouping, detector, rules, actions, `self`, history
}

/// os_log + JSON-lines emitter. Every interpolated value is `privacy: .public`, with `$HOME`
/// replaced by `~` in paths (callers sanitize paths before building messages).
public final class EventSink: @unchecked Sendable {
    public static let subsystem = "com.michaelv.swapless"

    private let lock = NSLock()
    private let loggers: [LogCategory: Logger]
    /// Which JSON line types go to stdout; nil = all, empty = none.
    public var jsonTypes: Set<String>?
    private let out: FileHandle

    public init(jsonTypes: Set<String>?, out: FileHandle = .standardOutput) {
        var l: [LogCategory: Logger] = [:]
        for c in LogCategory.allCases { l[c] = Logger(subsystem: Self.subsystem, category: c.rawValue) }
        self.loggers = l
        self.jsonTypes = jsonTypes
        self.out = out
    }

    /// A `.default` (persisted) log line.
    public func log(_ category: LogCategory, _ message: String) {
        loggers[category]?.log("\(message, privacy: .public)")
    }

    /// A `.debug` log line (per-sweep detail).
    public func debug(_ category: LogCategory, _ message: String) {
        loggers[category]?.debug("\(message, privacy: .public)")
    }

    /// Emits one JSON line when its type is enabled.
    public func emit(_ type: String, _ json: @autoclosure () -> JSON) {
        if let jsonTypes, !jsonTypes.contains(type) { return }
        var s = json().serialized
        s += "\n"
        lock.lock()
        defer { lock.unlock() }
        out.write(Data(s.utf8))
    }

    public func wantsJSON(_ type: String) -> Bool {
        guard let jsonTypes else { return true }
        return jsonTypes.contains(type)
    }

    /// An `error` line plus a `.default` log line.
    public func error(where w: String, _ message: String, category: LogCategory = .sampler) {
        log(category, "error where=\(w) message=\(message)")
        emit("error", .object([
            ("type", .string("error")),
            ("where", .string(w)),
            ("message", .string(message)),
        ]))
    }
}
