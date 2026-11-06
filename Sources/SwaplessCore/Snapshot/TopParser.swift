import Foundation

/// Parses `top -l 1 -stats pid,mem` (spec § A): header-agnostic, B/K/M/G in powers of 1024,
/// trailing `+`/`-` accepted and ignored.
public enum TopParser {
    public enum ParseError: Error, Equatable {
        case noHeader
    }

    /// pid → bytes. Throws `.noHeader` when no line starts with `PID`.
    public static func parse(_ text: String) throws -> [Int32: UInt64] {
        var result: [Int32: UInt64] = [:]
        var inRows = false
        var pidCol = 0
        var memCol = 1
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if !inRows {
                if line.hasPrefix("PID") {
                    let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                    pidCol = cols.firstIndex(of: "PID") ?? 0
                    memCol = cols.firstIndex(of: "MEM") ?? 1
                    inRows = true
                }
                continue
            }
            if line.isEmpty { continue }
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard cols.count > max(pidCol, memCol), let pid = Int32(cols[pidCol]) else { continue }
            guard let bytes = parseMem(String(cols[memCol])) else { continue }
            result[pid] = bytes
        }
        guard inRows else { throw ParseError.noHeader }
        return result
    }

    /// `5936K`, `97M`, `12G`, `512B`, with an optional trailing `+` / `-`.
    public static func parseMem(_ token: String) -> UInt64? {
        var s = Substring(token)
        while let last = s.last, last == "+" || last == "-" { s = s.dropLast() }
        guard let unit = s.last else { return nil }
        let multiplier: UInt64
        switch unit {
        case "B": multiplier = 1
        case "K": multiplier = 1024
        case "M": multiplier = 1024 * 1024
        case "G": multiplier = 1024 * 1024 * 1024
        default:
            // A bare number is bytes.
            if let n = UInt64(s) { return n }
            return nil
        }
        let digits = s.dropLast()
        guard !digits.isEmpty, let n = UInt64(digits) else { return nil }
        return n &* multiplier
    }
}

/// Runs `/usr/bin/top -l 1 -stats pid,mem` and parses it.
public enum TopRunner {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public static func run(executable: String = "/usr/bin/top") -> Result<[Int32: UInt64], Failure> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["-l", "1", "-stats", "pid,mem"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return .failure(Failure(description: "top: \(error.localizedDescription)"))
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationReason == .exit, p.terminationStatus == 0 else {
            return .failure(Failure(description: "top exited with status \(p.terminationStatus)"))
        }
        do {
            return .success(try TopParser.parse(String(decoding: data, as: UTF8.self)))
        } catch {
            return .failure(Failure(description: "top output has no PID header"))
        }
    }
}
