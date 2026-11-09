import Foundation

/// T5's constants. Not in `rules.json`.
public enum QuitTiming {
    public static let settle = 0.3
    public static let grace = 5.0
    public static let confirm = 0.5
    public static let young = 10.0
    public static let outcome = 30.0
    public static let rateLimitCount = 3
    public static let rateLimitWindow = 600.0
    public static let trustRecheck = 10.0
    public static let displayChange = 10.0
    public static let axTimeout: Float = 0.3
    public static let lastQuitRow = 30 * 60.0
}

/// Facts that don't belong to one app, read fresh for every gate evaluation.
public struct QuitEnvironment: Sendable, Equatable {
    public var settings: QuitSettings
    public var observeOnly: Bool
    public var historyOn: Bool
    public var trusted: Bool
    public var available: Bool
    public var stageManager: Bool
    /// `asleep`, `locked` or `display-change`.
    public var pause: String?
    /// `SWAPLESS_RIG_QUIT_BUNDLE_PREFIX`.
    public var rigPrefix: String?
    public var selfBundleId: String?
    public var selfPid: Int32
    public var dryRun: Bool

    public init(settings: QuitSettings, observeOnly: Bool = false, historyOn: Bool = true, trusted: Bool = true,
                available: Bool = true, stageManager: Bool = false, pause: String? = nil, rigPrefix: String? = nil,
                selfBundleId: String? = "com.michaelv.swapless", selfPid: Int32 = 1, dryRun: Bool = false) {
        self.settings = settings
        self.observeOnly = observeOnly
        self.historyOn = historyOn
        self.trusted = trusted
        self.available = available
        self.stageManager = stageManager
        self.pause = pause
        self.rigPrefix = rigPrefix
        self.selfBundleId = selfBundleId
        self.selfPid = selfPid
        self.dryRun = dryRun
    }
}

/// One app as the watcher sees it at the moment of a reading.
public struct AppFacts: Sendable, Equatable {
    public var pid: Int32
    public var bundleId: String?
    public var name: String
    /// `activationPolicy == .regular`.
    public var regular: Bool
    public var hidden: Bool
    /// Unix time: `launchDate`, or the process start time when LaunchServices has none.
    public var launchTime: Double
    public var finishedLaunching: Bool

    public init(pid: Int32, bundleId: String?, name: String, regular: Bool = true, hidden: Bool = false,
                launchTime: Double, finishedLaunching: Bool = true) {
        self.pid = pid
        self.bundleId = bundleId
        self.name = name
        self.regular = regular
        self.hidden = hidden
        self.launchTime = launchTime
        self.finishedLaunching = finishedLaunching
    }
}

public struct GateInput: Sendable, Equatable {
    public var env: QuitEnvironment
    public var app: AppFacts
    public var disarmed: Bool
    /// Unix times of this bundle id's earlier `terminate()` calls.
    public var recentQuits: [Double]
    public var now: Double

    public init(env: QuitEnvironment, app: AppFacts, disarmed: Bool = false, recentQuits: [Double] = [], now: Double) {
        self.env = env
        self.app = app
        self.disarmed = disarmed
        self.recentQuits = recentQuits
        self.now = now
    }
}

public enum GateResult: Sendable, Equatable {
    case quit
    case dryRun
    case skip(String)
}

/// T6: the only judgement before a quit. The first failing check is the reason logged.
public enum QuitGate {
    /// The rig prefix must start with this (S6), or Config refuses it.
    public static let rigPrefixRoot = "com.michaelv.swapless.rig."

    public static func rigAdmits(_ bundleId: String?, prefix: String?) -> Bool {
        guard let prefix, let bundleId else { return false }
        return bundleId.hasPrefix(prefix)
    }

    public static func evaluate(_ g: GateInput) -> GateResult {
        let e = g.env
        let a = g.app
        if e.settings.status == .invalid { return .skip("rules-invalid") }
        if !e.settings.isActive { return .skip("option-off") }
        if e.observeOnly { return .skip("observe-only") }
        if !e.historyOn { return .skip("history-off") }
        if !e.trusted { return .skip("untrusted") }
        if !e.available { return .skip("unavailable") }
        if e.stageManager { return .skip("stage-manager") }
        if let p = e.pause { return .skip(p) }
        if e.rigPrefix != nil && !rigAdmits(a.bundleId, prefix: e.rigPrefix) { return .skip("rig-scope") }
        guard let bundleId = a.bundleId, !bundleId.isEmpty else { return .skip("no-bundle-id") }
        if bundleId == QuitSettings.finderBundleId { return .skip("finder") }
        if e.settings.neverQuitIds.contains(bundleId) { return .skip("never-quit") }
        if bundleId == e.selfBundleId || a.pid == e.selfPid { return .skip("self") }
        if !a.regular && !rigAdmits(bundleId, prefix: e.rigPrefix) { return .skip("not-regular") }
        if a.hidden { return .skip("hidden") }
        if !a.finishedLaunching || g.now - a.launchTime < QuitTiming.young { return .skip("young") }
        if g.disarmed { return .skip("disarmed") }
        let recent = g.recentQuits.filter { g.now - $0 < QuitTiming.rateLimitWindow }.count
        if recent >= QuitTiming.rateLimitCount { return .skip("rate-limit") }
        if e.dryRun { return .dryRun }
        return .quit
    }
}

/// The only way a quit leaves the core (T6). The live sender is the one `terminate()`.
public protocol QuitSending: Sendable {
    func terminate(pid: Int32) -> Bool
}
