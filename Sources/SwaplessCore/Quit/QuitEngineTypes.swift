import Foundation

/// App names by bundle id (the app target: LaunchServices + the bundle's Info.plist).
public protocol AppNameByBundleId: Sendable {
    func name(forBundleId bundleId: String) -> String?
}

/// What the watcher knows and the engine doesn't (S3, `setWatcherStatus`).
public struct WatcherStatus: Sendable, Equatable {
    public var trusted: Bool
    public var available: Bool
    public var unavailableReason: String?
    public var stageManager: Bool
    public var tracked: Int
    public var armed: Int

    public init(trusted: Bool, available: Bool, unavailableReason: String?, stageManager: Bool,
                tracked: Int, armed: Int) {
        self.trusted = trusted
        self.available = available
        self.unavailableReason = unavailableReason
        self.stageManager = stageManager
        self.tracked = tracked
        self.armed = armed
    }
}

/// The engine facts the watcher needs, pushed on every publish and read fresh at decisions.
public struct QuitEngineView: Sendable, Equatable {
    public var settings: QuitSettings
    public var observeOnly: Bool
    public var historyOn: Bool
    public var dryRun: Bool
    public var rigPrefix: String?

    public init(settings: QuitSettings, observeOnly: Bool, historyOn: Bool, dryRun: Bool, rigPrefix: String?) {
        self.settings = settings
        self.observeOnly = observeOnly
        self.historyOn = historyOn
        self.dryRun = dryRun
        self.rigPrefix = rigPrefix
    }
}

/// The newest quit row, for the menu's `Last quit` status.
public struct QuitActionDisplay: Sendable, Equatable {
    public var ts: Double
    public var bundleId: String
    public var name: String
    public var beforeMB: Double
    public var outcome: String

    public init(ts: Double, bundleId: String, name: String, beforeMB: Double, outcome: String) {
        self.ts = ts
        self.bundleId = bundleId
        self.name = name
        self.beforeMB = beforeMB
        self.outcome = outcome
    }
}

/// `EngineState.quit`: what the menu's quit rows show (S3, S5).
public struct QuitDisplay: Sendable, Equatable {
    public static let ruleId = "quit-on-last-window"

    public var settings: QuitSettings
    /// `needs Accessibility`, `unavailable on this macOS`, `Stage Manager is on`, `another
    /// Swapless is acting`, `history off`, `rules.json invalid`, `not watched by --print-menu`.
    public var paused: String?
    /// Armed apps.
    public var watching: Int
    /// The newest non-dry quit row ≤ 30 min old.
    public var lastQuit: QuitActionDisplay?

    public init(settings: QuitSettings = .missing, paused: String? = nil, watching: Int = 0,
                lastQuit: QuitActionDisplay? = nil) {
        self.settings = settings
        self.paused = paused
        self.watching = watching
        self.lastQuit = lastQuit
    }

    /// The paused reason, first that applies (the gate's order, T6). `oneShot` is `--print-menu`.
    public static func pausedReason(settings: QuitSettings, oneShot: Bool, observeOnly: Bool, historyOn: Bool,
                                    watcher: WatcherStatus?) -> String? {
        if settings.status == .invalid { return "rules.json invalid" }
        if oneShot { return settings.isActive ? "not watched by --print-menu" : nil }
        if observeOnly { return "another Swapless is acting" }
        if !historyOn { return "history off" }
        guard let w = watcher else { return nil }
        if !w.trusted { return "needs Accessibility" }
        if !w.available { return "unavailable on this macOS" }
        if w.stageManager { return "Stage Manager is on" }
        return nil
    }
}

/// Thread CPU time in ms (`CLOCK_THREAD_CPUTIME_ID`), for `cpuMs` (S6).
public func threadCpuMs() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000
}
