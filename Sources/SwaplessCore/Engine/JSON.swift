import Foundation

/// A tiny ordered JSON writer: key order is kept and `null`s are written explicitly, which the
/// JSON-lines contract (S6) needs and `JSONEncoder` doesn't give.
public indirect enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([(String, JSON)])

    public static func == (a: JSON, b: JSON) -> Bool { a.serialized == b.serialized }

    public static func opt(_ v: UInt64?) -> JSON { v.map { .uint($0) } ?? .null }
    public static func opt(_ v: Int?) -> JSON { v.map { .int(Int64($0)) } ?? .null }
    public static func opt(_ v: Int32?) -> JSON { v.map { .int(Int64($0)) } ?? .null }
    public static func opt(_ v: Double?) -> JSON { v.map { .double($0) } ?? .null }
    public static func opt(_ v: String?) -> JSON { v.map { .string($0) } ?? .null }
    public static func i(_ v: Int) -> JSON { .int(Int64(v)) }
    public static func i(_ v: Int32) -> JSON { .int(Int64(v)) }

    public var serialized: String {
        var s = ""
        s.reserveCapacity(256)
        write(into: &s)
        return s
    }

    public func write(into s: inout String) {
        switch self {
        case .null: s += "null"
        case .bool(let b): s += b ? "true" : "false"
        case .int(let i): s += String(i)
        case .uint(let u): s += String(u)
        case .double(let d):
            if d.isFinite {
                if d == d.rounded(), abs(d) < 1e15 {
                    s += String(Int64(d))
                } else {
                    s += String(d)
                }
            } else {
                s += "null"
            }
        case .string(let str): JSON.escape(str, into: &s)
        case .array(let items):
            s += "["
            for (i, item) in items.enumerated() {
                if i > 0 { s += "," }
                item.write(into: &s)
            }
            s += "]"
        case .object(let pairs):
            s += "{"
            for (i, (k, v)) in pairs.enumerated() {
                if i > 0 { s += "," }
                JSON.escape(k, into: &s)
                s += ":"
                v.write(into: &s)
            }
            s += "}"
        }
    }

    static func escape(_ str: String, into s: inout String) {
        s += "\""
        for u in str.unicodeScalars {
            switch u {
            case "\"": s += "\\\""
            case "\\": s += "\\\\"
            case "\n": s += "\\n"
            case "\r": s += "\\r"
            case "\t": s += "\\t"
            default:
                if u.value < 0x20 {
                    let hex = String(u.value, radix: 16)
                    s += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    s.unicodeScalars.append(u)
                }
            }
        }
        s += "\""
    }
}

/// Strict reading helpers over `JSONSerialization` output.
public enum JSONRead {
    /// True when the value is a JSON boolean (NSNumber backed by CFBoolean).
    public static func isBool(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    public static func bool(_ v: Any?) -> Bool? {
        guard let v, isBool(v), let n = v as? NSNumber else { return nil }
        return n.boolValue
    }

    /// An integral JSON number (not a boolean, no fractional part).
    public static func int(_ v: Any?) -> Int? {
        guard let v, !isBool(v), let n = v as? NSNumber else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d == d.rounded(), abs(d) < 9e15 else { return nil }
        return Int(d)
    }

    /// Any JSON number (not a boolean).
    public static func double(_ v: Any?) -> Double? {
        guard let v, !isBool(v), let n = v as? NSNumber else { return nil }
        return n.doubleValue
    }

    public static func uint64(_ v: Any?) -> UInt64? {
        guard let v, !isBool(v), let n = v as? NSNumber else { return nil }
        return n.uint64Value
    }

    public static func string(_ v: Any?) -> String? { v as? String }
}
