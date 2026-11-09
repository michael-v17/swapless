import Foundation

/// One `apps` entry in `rules.json` v2 (spec v1-quit-on-close T1, S1). Slice 3 adds more
/// per-app fields to this same entry.
public struct AppEntry: Sendable, Equatable {
    public var bundleId: String
    public var name: String
    /// No Swapless quit of any kind, now or in later slices.
    public var neverQuit: Bool
    public var note: String?

    public init(bundleId: String, name: String, neverQuit: Bool, note: String? = nil) {
        self.bundleId = bundleId
        self.name = name
        self.neverQuit = neverQuit
        self.note = note
    }
}

/// `ok`: a v2 file with a valid quit section. `default`: a v1 file (switch off, the seed list in
/// memory). `invalid`: the file or the quit section is invalid. `missing`: no file.
public enum QuitSettingsStatus: String, Sendable {
    case ok
    case `default`
    case invalid
    case missing
}

/// The quit-on-last-window switch plus the `apps` table (T1).
public struct QuitSettings: Sendable, Equatable {
    public var status: QuitSettingsStatus
    /// The quit section's first error (`apps[3]: missing key 'neverQuit'`); nil for file-level
    /// errors, which `RulesLoad.fileError` carries.
    public var error: String?
    public var enabled: Bool
    /// Sorted by name (`localizedCaseInsensitiveCompare`), then bundle id.
    public var apps: [AppEntry]

    public init(status: QuitSettingsStatus, error: String? = nil, enabled: Bool, apps: [AppEntry]) {
        self.status = status
        self.error = error
        self.enabled = enabled
        self.apps = QuitSettings.sorted(apps)
    }

    public static let finderBundleId = "com.apple.finder"
    public static let seedNote = "Owner's seed 2026-11-06 (DECISIONS.md)"
    public static let maxApps = 500

    /// The owner's list (2026-11-06), bundle ids read from the installed apps' Info.plist.
    /// Finder is protected in code (`QuitGate`), not here.
    public static let seedApps: [AppEntry] = [
        ("com.anthropic.claudefordesktop", "Claude"),
        ("com.googlecode.iterm2", "iTerm2"),
        ("com.apple.mail", "Mail"),
        ("com.apple.MobileSMS", "Messages"),
        ("com.apple.Music", "Music"),
        ("com.openmausbot.app", "OpenMausBot"),
        ("app.portal.ios.v1", "Portal"),
        ("io.tailscale.ipn.macsys", "Tailscale"),
        ("dev.warp.Warp-Stable", "Warp"),
        ("net.whatsapp.WhatsApp", "WhatsApp"),
        ("com.zerotier.ZeroTier-UI", "ZeroTier"),
    ].map { AppEntry(bundleId: $0.0, name: $0.1, neverQuit: true, note: seedNote) }

    /// A v1 file: the switch off and the seed list, in memory only.
    public static let defaults = QuitSettings(status: .default, enabled: false, apps: seedApps)
    /// What a fresh v2 seed file holds.
    public static let seed = QuitSettings(status: .ok, enabled: false, apps: seedApps)
    public static let missing = QuitSettings(status: .missing, enabled: false, apps: [])

    public static func invalid(_ error: String?) -> QuitSettings {
        QuitSettings(status: .invalid, error: error, enabled: false, apps: [])
    }

    /// The entries with `neverQuit` true. Finder is not added here; the gate adds it.
    public var neverQuitIds: Set<String> { Set(apps.filter(\.neverQuit).map(\.bundleId)) }

    /// The switch is on in a valid v2 file.
    public var isActive: Bool { status == .ok && enabled }

    /// The section may be written back (through the whole model).
    public var writable: Bool { status == .ok || status == .default }

    public func name(for bundleId: String) -> String? {
        apps.first { $0.bundleId == bundleId }?.name
    }

    public static func sorted(_ apps: [AppEntry]) -> [AppEntry] {
        apps.sorted { a, b in
            switch a.name.localizedCaseInsensitiveCompare(b.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.bundleId < b.bundleId
            }
        }
    }

    /// The `quit` object in the `rules` line.
    public var json: JSON {
        .object([
            ("status", .string(status.rawValue)),
            ("enabled", .bool(enabled)),
            ("neverQuit", .array(neverQuitIds.sorted().map { .string($0) })),
            ("error", .opt(error)),
        ])
    }

    // MARK: decoding (S1)

    static let sectionKeys: Set<String> = ["enabled"]
    static let appKeys: Set<String> = ["bundleId", "name", "neverQuit", "note"]
    static let requiredAppKeys = ["bundleId", "name", "neverQuit"]

    /// The quit section of a v2 file. Any error makes only this section invalid.
    static func decode(top: [String: Any]) -> QuitSettings {
        guard let rawSection = top["quitOnLastWindow"] else { return .invalid("missing key 'quitOnLastWindow'") }
        guard let section = rawSection as? [String: Any] else {
            return .invalid("'quitOnLastWindow' must be an object")
        }
        if let unknown = section.keys.sorted().first(where: { !sectionKeys.contains($0) }) {
            return .invalid("quitOnLastWindow: unknown key '\(unknown)'")
        }
        guard section["enabled"] != nil else { return .invalid("quitOnLastWindow: missing key 'enabled'") }
        guard let enabled = JSONRead.bool(section["enabled"]) else {
            return .invalid("quitOnLastWindow: 'enabled' must be a boolean")
        }
        guard let rawApps = top["apps"] else { return .invalid("missing key 'apps'") }
        guard let list = rawApps as? [Any] else { return .invalid("'apps' must be an array") }
        guard list.count <= maxApps else { return .invalid("'apps' has more than \(maxApps) entries") }
        var apps: [AppEntry] = []
        var seen = Set<String>()
        for (i, raw) in list.enumerated() {
            switch decodeApp(raw) {
            case .failure(let e): return .invalid("apps[\(i)]: \(e.m)")
            case .success(let a):
                if seen.contains(a.bundleId) { return .invalid("apps[\(i)]: duplicate bundleId") }
                seen.insert(a.bundleId)
                apps.append(a)
            }
        }
        return QuitSettings(status: .ok, enabled: enabled, apps: apps)
    }

    static func decodeApp(_ raw: Any) -> Result<AppEntry, RuleError> {
        guard let d = raw as? [String: Any] else { return .failure(RuleError(m: "not an object")) }
        if let unknown = d.keys.sorted().first(where: { !appKeys.contains($0) }) {
            return .failure(RuleError(m: "unknown key '\(unknown)'"))
        }
        if let missing = requiredAppKeys.first(where: { d[$0] == nil }) {
            return .failure(RuleError(m: "missing key '\(missing)'"))
        }
        guard let id = d["bundleId"] as? String, (1...255).contains(id.count),
              !id.contains(where: { $0.isWhitespace }) else {
            return .failure(RuleError(m: "'bundleId' must be 1…255 characters with no whitespace"))
        }
        guard let name = d["name"] as? String, (1...255).contains(name.count) else {
            return .failure(RuleError(m: "'name' must be 1…255 characters"))
        }
        guard let never = JSONRead.bool(d["neverQuit"]) else {
            return .failure(RuleError(m: "'neverQuit' must be a boolean"))
        }
        if let note = d["note"], !(note is String) { return .failure(RuleError(m: "'note' must be a string")) }
        return .success(AppEntry(bundleId: id, name: name, neverQuit: never, note: d["note"] as? String))
    }

    // MARK: encoding

    var encodedSection: [String: Any] { ["enabled": enabled] }

    var encodedApps: [[String: Any]] {
        QuitSettings.sorted(apps).map { a in
            var d: [String: Any] = ["bundleId": a.bundleId, "name": a.name, "neverQuit": a.neverQuit]
            if let n = a.note { d["note"] = n }
            return d
        }
    }
}
