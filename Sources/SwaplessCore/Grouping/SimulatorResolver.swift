import Darwin
import Foundation

/// launchd_sim → UDID (UUID only) → device.plist name (§ G step 1).
public enum SimulatorResolver {
    /// `launchd_sim` whose path contains `/RuntimeRoot/`.
    public static func isLaunchdSim(name: String, path: String) -> Bool {
        name == "launchd_sim" && path.contains("/RuntimeRoot/")
    }

    /// Reads the UDID from launchd_sim's `KERN_PROCARGS2` (same-user is allowed). Extracts
    /// **only** a UUID that matches `Devices/<UUID>/` or `SIMULATOR_UDID=<UUID>`; the buffer is
    /// discarded immediately and never logged, stored or emitted.
    public static func udid(pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        let found = extractUDID(buf.prefix(size))
        // Discard the arguments and environment right away.
        for i in buf.indices { buf[i] = 0 }
        return found
    }

    /// Pure: the first UUID after `Devices/` (followed by `/`) or `SIMULATOR_UDID=`.
    public static func extractUDID<C: Collection>(_ bytes: C) -> String? where C.Element == UInt8 {
        let a = Array(bytes)
        for marker in [Array("SIMULATOR_UDID=".utf8), Array("Devices/".utf8)] {
            var i = 0
            while i + marker.count + 36 <= a.count {
                if a[i] == marker[0] && Array(a[i..<(i + marker.count)]) == marker {
                    let start = i + marker.count
                    let candidate = a[start..<(start + 36)]
                    if isUUID(candidate) {
                        let isDevices = marker.count == 8
                        if !isDevices || (start + 36 < a.count && a[start + 36] == UInt8(ascii: "/")) {
                            return String(decoding: candidate, as: UTF8.self).uppercased()
                        }
                    }
                }
                i += 1
            }
        }
        return nil
    }

    static func isUUID<C: Collection>(_ c: C) -> Bool where C.Element == UInt8 {
        guard c.count == 36 else { return false }
        for (i, b) in c.enumerated() {
            if [8, 13, 18, 23].contains(i) {
                if b != UInt8(ascii: "-") { return false }
            } else {
                let isHex = (b >= 48 && b <= 57) || (b >= 65 && b <= 70) || (b >= 97 && b <= 102)
                if !isHex { return false }
            }
        }
        return true
    }

    /// `~/Library/Developer/CoreSimulator/Devices/<UDID>/device.plist`, key `name`.
    public static func deviceName(udid: String, home: String) -> String? {
        let url = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)/device.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = plist["name"] as? String, !name.isEmpty else { return nil }
        return name
    }

    public static func label(udid: String?, home: String) -> String {
        guard let udid, let name = deviceName(udid: udid, home: home) else {
            return "Simulator (unknown device)"
        }
        return "Simulator · \(name)"
    }
}

/// Claude Code recognition (copied from TypeFlow's ProcessWatcher, adapted).
public enum ClaudeCode {
    /// The native installer's `~/.local/share/claude/versions/<ver>`, or a binary named `claude`
    /// (npm / Homebrew).
    public static func isClaudeBinary(path: String, home: String) -> Bool {
        if !path.isEmpty && path.hasPrefix(home + "/.local/share/claude/versions/") { return true }
        return ProcessTable.basename(path) == "claude"
    }

    public static func label(cwdBasename: String?) -> String {
        guard let cwdBasename, !cwdBasename.isEmpty else { return "Claude Code" }
        return "Claude Code · \(cwdBasename)"
    }
}
