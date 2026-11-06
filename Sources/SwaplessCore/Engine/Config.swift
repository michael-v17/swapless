import Darwin
import Foundation

/// Which binary flavour and mode is asking. Only `main.swift` passes the real values (§ C).
public struct Flavour: Sendable, Equatable {
    public enum Mode: String, Sendable {
        case menuApp, headless, printMenu, dumpSnapshot
    }

    public var isRelease: Bool
    public var mode: Mode

    public init(isRelease: Bool, mode: Mode) {
        self.isRelease = isRelease
        self.mode = mode
    }

    /// Only the release menu app may use the default state dir.
    public var mayUseDefaultStateDir: Bool { isRelease && mode == .menuApp }
}

public struct ConfigError: Error, CustomStringConvertible, Equatable {
    public let where_: String
    public let message: String
    public var description: String { "\(where_): \(message)" }

    public init(_ where_: String, _ message: String) {
        self.where_ = where_
        self.message = message
    }
}

/// Every § K environment seam, validated at start.
public struct Config: Sendable {
    public var stateDir: URL
    /// `SWAPLESS_STATE_DIR` exactly as received (nil when unset).
    public var stateDirEnv: String?
    /// True only for the release menu app with `SWAPLESS_STATE_DIR` unset.
    public var usesDefaultStateDir: Bool
    public var sampleInterval: Double
    public var dryRun: Bool
    public var detectorConfig: DetectorConfig
    public var detectorConfigPath: String?
    public var forceTop: Bool
    public var rigMenuCycles: Int?
    /// `SWAPLESS_RIG_MENU_SHOWS=N` (app mode): open the real status-item menu N times, then
    /// keep running so the rig can measure the idle footprint after it closed. On screen: only
    /// `leak-rig.sh --on-screen-menu` sets it, in an announced session the owner approved.
    public var rigMenuShows: Int?
    /// `SWAPLESS_RIG_MENU_DRAWS=N` (app mode): no status item; build the real menu and draw it
    /// N times, 2 s apart, into a window never ordered on screen, then keep running so the rig
    /// can measure the idle footprint (check 5's menu test).
    public var rigMenuDraws: Int?
    /// `SWAPLESS_RIG_MENU_OPEN=S` (app mode, 50…600): no status item; simulate the menu open
    /// for S seconds on never-shown menus, then print `menuOpen` and `menuOpenTail` lines
    /// (v1-menu-today S5, check 5's offscreen menu-open test).
    public var rigMenuOpen: Int?
    /// DEBUG builds only.
    public var rigHelperPath: String?
    /// A release build saw `SWAPLESS_RIG_HELPER_PATH` and ignored it (one log line).
    public var rigHelperIgnored: Bool
    public var duration: Double?
    public var flavour: Flavour
    /// As injected by `main.swift` (never computed here).
    public var defaultStateDir: URL

    public static let defaultInterval = 30.0
    public static let minInterval = 0.25

    /// `SWAPLESS_STATE_DIR` refusal and every seam. Decided before any mkdir, flock, file
    /// open or SQLite open.
    public static func load(env: [String: String], defaultStateDir: URL, flavour: Flavour,
                            duration: Double? = nil, cwd: String = FileManager.default.currentDirectoryPath)
        -> Result<Config, ConfigError> {
        // State dir (§ C).
        let rawDir = env["SWAPLESS_STATE_DIR"]
        let stateDir: URL
        var usesDefault = false
        if let rawDir {
            if rawDir.isEmpty {
                return .failure(ConfigError("SWAPLESS_STATE_DIR", "is empty"))
            }
            let abs = rawDir.hasPrefix("/") ? rawDir : (cwd as NSString).appendingPathComponent(rawDir)
            let url = URL(fileURLWithPath: abs).standardizedFileURL
            if StatePaths.sameLocation(url, defaultStateDir) && !flavour.mayUseDefaultStateDir {
                return .failure(ConfigError(
                    "SWAPLESS_STATE_DIR",
                    "refusing the default state dir in \(flavour.isRelease ? "release" : "debug") \(flavour.mode.rawValue) mode"))
            }
            stateDir = url
        } else {
            guard flavour.mayUseDefaultStateDir else {
                return .failure(ConfigError(
                    "SWAPLESS_STATE_DIR",
                    "required in \(flavour.isRelease ? "release" : "debug") \(flavour.mode.rawValue) mode"))
            }
            stateDir = defaultStateDir
            usesDefault = true
        }

        // Interval.
        var interval = defaultInterval
        if let raw = env["SWAPLESS_SAMPLE_INTERVAL"] {
            guard let v = Double(raw.trimmingCharacters(in: .whitespaces)), v.isFinite,
                  v >= minInterval else {
                return .failure(ConfigError("SWAPLESS_SAMPLE_INTERVAL", "must be a number ≥ 0.25, got '\(raw)'"))
            }
            interval = v
        }

        // Dry run: exactly 0 or 1.
        var dryRun = false
        if let raw = env["SWAPLESS_DRY_RUN"] {
            switch raw {
            case "0": dryRun = false
            case "1": dryRun = true
            default:
                return .failure(ConfigError("SWAPLESS_DRY_RUN", "must be 0 or 1, got '\(raw)'"))
            }
        }

        // Force top.
        var forceTop = false
        if let raw = env["SWAPLESS_FORCE_TOP"] {
            switch raw {
            case "0": forceTop = false
            case "1": forceTop = true
            default:
                return .failure(ConfigError("SWAPLESS_FORCE_TOP", "must be 0 or 1, got '\(raw)'"))
            }
        }

        // Menu cycles (app mode only; ignored by --headless).
        var cycles: Int?
        if let raw = env["SWAPLESS_RIG_MENU_CYCLES"], flavour.mode == .menuApp {
            guard let n = Int(raw), n >= 1 else {
                return .failure(ConfigError("SWAPLESS_RIG_MENU_CYCLES", "must be an integer ≥ 1, got '\(raw)'"))
            }
            cycles = n
        }

        // Menu shows (app mode only; ignored by --headless). Not together with menu cycles,
        // which run without a status item.
        var shows: Int?
        if let raw = env["SWAPLESS_RIG_MENU_SHOWS"], flavour.mode == .menuApp {
            guard let n = Int(raw), n >= 1 else {
                return .failure(ConfigError("SWAPLESS_RIG_MENU_SHOWS", "must be an integer ≥ 1, got '\(raw)'"))
            }
            guard cycles == nil else {
                return .failure(ConfigError("SWAPLESS_RIG_MENU_SHOWS", "can't be combined with SWAPLESS_RIG_MENU_CYCLES"))
            }
            shows = n
        }

        // Offscreen menu draws (app mode only; ignored by --headless). Exclusive with the others.
        var draws: Int?
        if let raw = env["SWAPLESS_RIG_MENU_DRAWS"], flavour.mode == .menuApp {
            guard let n = Int(raw), n >= 1 else {
                return .failure(ConfigError("SWAPLESS_RIG_MENU_DRAWS", "must be an integer ≥ 1, got '\(raw)'"))
            }
            guard cycles == nil, shows == nil else {
                return .failure(ConfigError("SWAPLESS_RIG_MENU_DRAWS", "can't be combined with SWAPLESS_RIG_MENU_CYCLES or SWAPLESS_RIG_MENU_SHOWS"))
            }
            draws = n
        }

        // Simulated menu open (app mode only; ignored by --headless). Exclusive with the others.
        var menuOpen: Int?
        if let raw = env["SWAPLESS_RIG_MENU_OPEN"], flavour.mode == .menuApp {
            guard let n = Int(raw), (50...600).contains(n) else {
                return .failure(ConfigError("SWAPLESS_RIG_MENU_OPEN", "must be an integer 50…600, got '\(raw)'"))
            }
            guard cycles == nil, shows == nil, draws == nil else {
                return .failure(ConfigError("SWAPLESS_RIG_MENU_OPEN", "can't be combined with SWAPLESS_RIG_MENU_CYCLES, SWAPLESS_RIG_MENU_SHOWS or SWAPLESS_RIG_MENU_DRAWS"))
            }
            menuOpen = n
        }

        // Rig helper path (DEBUG only).
        var helperPath: String?
        var helperIgnored = false
        if let raw = env["SWAPLESS_RIG_HELPER_PATH"] {
            if flavour.isRelease {
                helperIgnored = true
            } else {
                guard raw.hasPrefix("/") else {
                    return .failure(ConfigError("SWAPLESS_RIG_HELPER_PATH", "must be an absolute path"))
                }
                helperPath = raw
            }
        }

        // Detector config file (all 15 keys).
        var detector = DetectorConfig.defaults
        var detectorPath: String?
        if let raw = env["SWAPLESS_DETECTOR_CONFIG"] {
            let path = raw.hasPrefix("/") ? raw : (cwd as NSString).appendingPathComponent(raw)
            guard let data = FileManager.default.contents(atPath: path) else {
                return .failure(ConfigError("SWAPLESS_DETECTOR_CONFIG", "can't read '\(raw)'"))
            }
            switch DetectorConfig.decodeStrict(data) {
            case .success(let c): detector = c
            case .failure(let e): return .failure(ConfigError("SWAPLESS_DETECTOR_CONFIG", e.message))
            }
            detectorPath = raw
        }

        if let duration, !(duration.isFinite && duration > 0) {
            return .failure(ConfigError("--duration", "must be a positive number of seconds"))
        }

        return .success(Config(
            stateDir: stateDir, stateDirEnv: rawDir, usesDefaultStateDir: usesDefault,
            sampleInterval: interval, dryRun: dryRun, detectorConfig: detector,
            detectorConfigPath: detectorPath, forceTop: forceTop, rigMenuCycles: cycles,
            rigMenuShows: shows, rigMenuDraws: draws, rigMenuOpen: menuOpen,
            rigHelperPath: helperPath, rigHelperIgnored: helperIgnored, duration: duration,
            flavour: flavour, defaultStateDir: defaultStateDir))
    }

    /// The code allowlist this binary knows (§ I).
    public var allowedTargets: Set<String> {
        var s: Set<String> = [RestartTarget.wallpaper.rawValue]
        #if DEBUG
        if !flavour.isRelease && rigHelperPath != nil { s.insert(RestartTarget.rigHelper.rawValue) }
        #endif
        return s
    }

    /// Leeway for the base timer: min(3 s, 10 % of the interval).
    public var leeway: Double { min(3.0, sampleInterval * 0.1) }
}

/// Path comparison for the state-dir refusal: standardized, symlinks resolved (through the
/// longest existing prefix), case-insensitive (APFS default).
public enum StatePaths {
    public static func resolved(_ url: URL) -> String {
        var components = url.standardizedFileURL.pathComponents
        var tail: [String] = []
        while !components.isEmpty {
            let prefix = NSString.path(withComponents: components)
            if let real = realpath(prefix, nil) {
                defer { free(real) }
                let base = String(cString: real)
                let joined = tail.reversed().reduce(base) { ($0 as NSString).appendingPathComponent($1) }
                return joined
            }
            tail.append(components.removeLast())
        }
        return url.standardizedFileURL.path
    }

    public static func sameLocation(_ a: URL, _ b: URL) -> Bool {
        normalize(resolved(a)) == normalize(resolved(b))
    }

    static func normalize(_ p: String) -> String {
        var s = p.lowercased()
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
