import CSwaplessProc
import Darwin
import Foundation

/// What the menu needs, published after every sweep as a Sendable value.
public struct EngineState: Sendable {
    public var snapshot: Snapshot?
    public var groups: [ProcessGroup]
    public var rules: RulesLoad
    public var source: FootprintSourceKind
    public var selfCheck: SelfCheckResult?
    public var selfReading: SelfReading?
    public var dryRun: Bool
    public var observeOnly: Bool
    public var historyError: String?
    public var overBudget: Bool
    public var seq: Int
    /// Flagged series, newest state (P3).
    public var flags: [FlagInfo]
    /// The wallpaper rule's live status (P4).
    public var ruleDisplays: [RuleDisplay]
    /// Bumped whenever something should light the menu-bar dot (owner call 5).
    public var dotGeneration: Int
    /// The Today row (v1-menu-today S3).
    public var activity: ActivityState = .notRecorded(reason: "history off")
    /// Quit on last window close (v1-quit-on-close S3).
    public var quit = QuitDisplay()

    public init() {
        flags = []
        ruleDisplays = []
        dotGeneration = 0
        snapshot = nil
        groups = []
        rules = .missing
        source = .coalition
        selfCheck = nil
        selfReading = nil
        dryRun = false
        observeOnly = false
        historyError = nil
        overBudget = false
        seq = -1
    }
}

/// The engine: base timer + menu-open display sweeps, self-check schedule, rules reload,
/// JSON lines. All state is confined to `queue`.
public final class Engine: @unchecked Sendable {
    public let config: Config
    public let sink: EventSink
    public let queue = DispatchQueue(label: "com.michaelv.swapless.engine", qos: .utility)
    private let sweeper: ProcessSweeper
    private let live: LiveSource
    private let topSource: TopFallbackSource
    private var source: FootprintSource
    private let grouper: Grouper
    private let selfMeter = SelfMeter()
    private let probe: SelfCheckProbe
    private let terminate: @Sendable (Int32) -> Void

    private var baseTimer: DispatchSourceTimer?
    private var displayTimer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var nextBaseDue: Double = 0
    private var seq = 0
    private var selfCheck: SelfCheckResult?
    private var lastSelfCheckUptime: Double = 0
    private var degradeStreak = 0
    private var lastTopRunUptime: Double = -1
    private var rules: RulesLoad = .missing
    private var menuOpen = false
    private var menuOpenSince: Double?
    private var menuOpenAccum: Double = 0
    private var state = EngineState()
    private var exiting = false

    // P3: history, detector, engine.lock.
    private var detector: LeakDetector
    private(set) var history: HistoryStore?
    private var historyError: String?
    private var lockFd: Int32 = -1
    private var observeOnly = false
    private var lastFlushWall: Double = 0

    // P4: rules, actuator, verification.
    private let actuator: Actuator
    private var evalState = EvaluatorState()
    /// rule id → paused reason. The in-memory copy holds for this run even if history fails.
    private var pauses: [String: String] = [:]
    /// Actions of the last 9 days (T7): cooldown and maxPerDay filter on 24 h themselves;
    /// the Today row reads all of them. A row is here only after its insert succeeded.
    private var recentActions: [ActionRow] = []
    static let actionsKeptSeconds = 9 * 86400.0
    /// The `yyyy-MM-dd` of past local days with a `system_samples` row (T11).
    private var coverage: Set<String> = []
    /// Local start of today at the last successful coverage probe.
    private var coverageProbeDay: Double?
    private var coverageErrorLogged = false
    /// History opened successfully at least once in this run.
    private var historyOpened = false
    /// `--print-menu` / `--dump-snapshot`.
    private var oneShotMode = false
    /// The last `activity` line emitted, without `t`.
    private var lastActivityLine: String?
    private var verifies: [String: (plan: VerifyPlan, start: Double, timer: DispatchSourceTimer)] = [:]
    private var lastSnapshot: Snapshot?
    private var lastGroups: [ProcessGroup] = []
    private var draining = false

    // v1-quit-on-close S3: the watcher's status, quit rows still waiting for their outcome, and
    // the names the watcher saw at quit time.
    private var watcherStatus: WatcherStatus?
    private var openQuits: Set<Int64> = []
    private var quitNames: [Int64: String] = [:]
    private var lastQuitView: QuitEngineView?
    /// App names by bundle id for the `Last quit` row. Set before `start()`.
    public var appNameProvider: AppNameByBundleId?
    /// Called on the engine queue whenever the facts the watcher needs change. Set before
    /// `start()`.
    public var onQuitView: (@Sendable (QuitEngineView) -> Void)?

    /// Called on the engine queue after every sweep.
    public var onState: (@Sendable (EngineState) -> Void)?

    /// The open menu's display sweeps: the first right at open, then every 5 s (T2).
    public static let displayInterval = 5.0
    /// Display-timer firings that swept (either branch). Read on the engine queue.
    public private(set) var displaySweeps = 0
    /// `onState` calls. Read on the engine queue.
    public private(set) var publishes = 0

    private func sendState() {
        publishes += 1
        state.quit = quitDisplay(now: Clock.wall())
        let view = quitView()
        if view != lastQuitView {
            lastQuitView = view
            onQuitView?(view)
        }
        onState?(state)
    }

    public init(config: Config, sink: EventSink, labeler: Labeler, signalSender: SignalSender,
                inspector: ProcessInspector = LiveProcessInspector(),
                probe: SelfCheckProbe = .live, sweeper: ProcessSweeper = ProcessSweeper(),
                terminate: @escaping @Sendable (Int32) -> Void = { exit($0) }) {
        self.config = config
        self.sink = sink
        self.sweeper = sweeper
        self.live = LiveSource(sweeper: sweeper)
        self.topSource = TopFallbackSource(sweeper: sweeper)
        self.source = live
        self.grouper = Grouper(labeler: labeler, home: sweeper.home)
        self.probe = probe
        self.terminate = terminate
        self.detector = LeakDetector(config: config.detectorConfig, hwMemsize: sweeper.hwMemsize)
        self.actuator = Actuator(inspector: inspector, sender: signalSender, ownUid: sweeper.ownUid,
                                 dryRun: config.dryRun, sink: sink)
        state.dryRun = config.dryRun
    }

    // MARK: - Start

    /// Runs the start sequence on the engine queue: self-check, `start` + `rules` lines, the
    /// synchronous `top` (fallback), then the first base tick.
    public func start() {
        installSignalHandlers()
        queue.async { [self] in
            if config.rigHelperIgnored {
                sink.log(.rules, "SWAPLESS_RIG_HELPER_PATH is set but ignored: release build")
            }
            seedIfFirstLaunch()
            prepareState()
            runSelfCheck(initial: true)
            emitStart()
            reloadRules(force: true)
            markInterrupted()
            if source !== live { refreshTopIfDue(force: true) }
            if let d = config.duration {
                queue.asyncAfter(deadline: .now() + d) { [self] in finish(exitCode: 0, waitForVerify: true) }
            }
            nextBaseDue = Clock.uptime()
            baseTick()
        }
    }

    // MARK: - State dir, lock, history

    /// mkdir -p the state dir, take `engine.lock`, open history and preload the detector. A
    /// second engine on the same dir runs observe-only: it never acts and never writes
    /// `history.sqlite` or `rules.json`.
    private func prepareState() {
        let dir = config.stateDir
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            historyError = "state dir: \(error.localizedDescription)"
            sink.error(where: "history", historyError!, category: .history)
            return
        }
        if !takeLock() {
            observeOnly = true
            state.observeOnly = true
            sink.log(.history, "another Swapless holds engine.lock in \(PathSanitizer.sanitize(dir.path)); observe-only")
            return
        }
        openHistory()
    }

    /// Owner call 1: the release menu app seeds `rules.json` on its own first launch.
    private func seedIfFirstLaunch() {
        let r = RulesFile.seedIfFirstLaunch(defaultStateDir: config.defaultStateDir, flavour: config.flavour,
                                            stateDirEnv: config.stateDirEnv)
        switch r {
        case .seeded:
            sink.log(.rules, "seeded rules.json with wallpaper-leak-guard (owner decision 2026-11-05) in \(PathSanitizer.sanitize(config.defaultStateDir.path))")
        case .failed(let e):
            sink.error(where: "seed", e, category: .rules)
        case .notEligible, .dirExisted:
            break
        }
    }

    /// At engine start, every `pending` row (a crash or SIGTERM mid-verify) becomes
    /// `interrupted`. It counts for cooldown and maxPerDay and doesn't pause the rule.
    private func markInterrupted() {
        guard let h = history else { return }
        let now = Clock.wall()
        let pending = h.pendingActions().count
        let changed = h.markPendingInterrupted()
        if changed.count != pending { historyOff(h.error ?? "update failed") }
        for row in changed {
            sink.log(.actions, "actionOutcome id=\(row.id) rule=\(row.ruleId) outcome=interrupted (pending at engine start)")
            sink.emit("actionOutcome", Actuator.outcomeJSON(t: now, actionId: row.id, outcome: "interrupted",
                                                            afterMB: nil, wsBeforeMB: nil, wsAfterMB: nil))
            if let i = recentActions.firstIndex(where: { $0.id == row.id }) { recentActions[i].outcome = "interrupted" }
        }
        recomputeActivity()
    }

    /// true when this engine holds the lock (or the lock can't exist: then history is off).
    private func takeLock() -> Bool {
        if lockFd < 0 {
            lockFd = open(config.stateDir.appendingPathComponent("engine.lock").path, O_RDWR | O_CREAT, 0o644)
            if lockFd < 0 {
                historyError = "engine.lock: \(String(cString: strerror(errno)))"
                return true
            }
        }
        return flock(lockFd, LOCK_EX | LOCK_NB) == 0
    }

    private func openHistory() {
        let ruleIds = RulesFile.load(url: RulesFile.url(in: config.stateDir),
                                     allowedTargets: config.allowedTargets).entries.map(\.id).filter { !$0.isEmpty }
        let now = Clock.wall()
        let h = HistoryStore(stateDir: config.stateDir, currentRuleIds: ruleIds, now: now)
        if let bak = h.resetBackup {
            sink.log(.history, "history schema reset: old file moved to \(PathSanitizer.sanitize(bak)); every rule paused (history-reset)")
        }
        if let e = h.error {
            historyError = e
            sink.error(where: "history", e, category: .history)
            history = nil
            return
        }
        history = h
        lastFlushWall = now
        for (id, p) in h.pauses() { pauses[id] = p.reason }
        recentActions = h.actions(since: now - Self.actionsKeptSeconds)
        let recent = h.loadRecent(now: now)
        detector.preload(meta: recent.meta, buckets: recent.buckets)
        h.pruneIfDue(now: now)
        historyOpened = true
        probeCoverage()
        recomputeActivity()
    }

    /// Observe-only engines retry the lock on every base tick and take over once they get it.
    private func retryLock() {
        guard observeOnly, takeLock() else { return }
        observeOnly = false
        state.observeOnly = false
        sink.log(.history, "took over engine.lock; acting from now on")
        openHistory()
        recomputeActivity()
    }

    private func flushHistory(now: Double, force: Bool) {
        guard let h = history else { return }
        if force || now - lastFlushWall >= HistoryStore.flushSeconds {
            lastFlushWall = now
            if !h.flush(now: now) || !h.isOn {
                historyOff(h.error ?? "flush failed")
            } else {
                probeCoverage()
            }
            h.pruneIfDue(now: now)
        }
    }

    // MARK: - Activity (the Today row, v1-menu-today S3)

    /// Probes the 6 past local days for samples. On an error the previous coverage is kept,
    /// and one line is logged (again only after a successful probe).
    private func probeCoverage() {
        guard let h = history else { return }
        let tz = TimeZone.autoupdatingCurrent
        let all = ActivitySummary.dayRanges(now: Clock.wall(), timeZone: tz)
        let past = all.dropFirst()
        guard let found = h.daysWithSamples(past.map { ($0.start, $0.end) }) else {
            if !coverageErrorLogged {
                coverageErrorLogged = true
                sink.log(.history, "coverage probe failed; keeping the previous days")
            }
            return
        }
        coverageErrorLogged = false
        coverage = Set(past.filter { found.contains($0.start) }.map(\.key))
        coverageProbeDay = all.first?.start
    }

    /// Re-probes coverage when the local day changed since the last probe.
    private func probeCoverageIfNewDay() {
        guard history != nil else { return }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .autoupdatingCurrent
        let today = cal.startOfDay(for: Date(timeIntervalSince1970: Clock.wall())).timeIntervalSince1970
        if today != coverageProbeDay { probeCoverage() }
    }

    /// Read-only: reads `recentActions` and coverage, writes `state.activity`.
    private func recomputeActivity() {
        if oneShotMode {
            state.activity = .notRecorded(reason: "not read by --print-menu")
        } else if observeOnly {
            state.activity = .notRecorded(reason: "another Swapless is acting")
        } else if !historyOpened {
            state.activity = .notRecorded(reason: "history off")
        } else {
            state.activity = .summary(ActivitySummary.summarize(actions: recentActions, sampleDays: coverage,
                                                                now: Clock.wall(), timeZone: .autoupdatingCurrent))
        }
    }

    /// The headless `activity` line: on the first base tick, then whenever its content changes.
    private func emitActivity(t: Double) {
        guard sink.wantsJSON("activity") else { return }
        recomputeActivity()
        let body = JSON.object(state.activity.jsonFields).serialized
        guard body != lastActivityLine else { return }
        lastActivityLine = body
        sink.emit("activity", .object([("type", .string("activity")), ("t", .double(t))] + state.activity.jsonFields))
    }

    private func historyOff(_ why: String) {
        guard history != nil else { return }
        historyError = why
        history = nil
        sink.error(where: "history", "history off: \(why)", category: .history)
    }

    private func emitStart() {
        let sc = selfCheck ?? SelfCheck.skipped(probe: probe)
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        sink.emit("start", .object([
            ("type", .string("start")),
            ("pid", .i(getpid())),
            ("version", .string(version)),
            ("stateDir", .string(config.stateDirEnv ?? config.stateDir.path)),
            ("intervalSeconds", .double(config.sampleInterval)),
            ("dryRun", .bool(config.dryRun)),
            ("observeOnly", .bool(state.observeOnly)),
            ("source", .string(source.kind.rawValue)),
            ("selfCheck", sc.json),
            ("quit", .object([
                ("enabled", .bool(RulesFile.load(url: RulesFile.url(in: config.stateDir),
                                                 allowedTargets: config.allowedTargets).quit.isActive)),
                ("rigPrefix", .opt(config.rigQuitBundlePrefix)),
            ])),
        ]))
    }

    // MARK: - Self-check

    private func runSelfCheck(initial: Bool) {
        lastSelfCheckUptime = Clock.uptime()
        if config.forceTop {
            selfCheck = SelfCheck.skipped(probe: probe)
            if initial { sink.log(.sampler, "self-check skipped (SWAPLESS_FORCE_TOP=1); source=top") }
            source = topSource
            return
        }
        let snap = sweeper.sweep(readCoalitions: false, topValues: nil, source: .coalition,
                                 readSystem: false)
        let r = SelfCheck.run(entries: snap.entries, ownUid: sweeper.ownUid, ownPid: getpid(),
                              probe: probe)
        selfCheck = r
        let previous = source.kind
        source = r.coalitionUsable ? live : topSource
        let why = r.reason.map { " reason=\($0)" } ?? ""
        sink.log(.sampler, "self-check coalition=\(r.coalition.rawValue) checked=\(r.checked) passed=\(r.passed) windowServer=\(r.windowServer.rawValue) responsibility=\(r.responsibility.rawValue) source=\(source.kind.rawValue)\(why)")
        if !initial && previous != source.kind {
            sink.log(.sampler, "source changed \(previous.rawValue) → \(source.kind.rawValue)")
            if source !== live { refreshTopIfDue(force: true) }
        }
    }

    /// The injected wake signal: re-run the self-check, null the next swap-in delta.
    public func wake() {
        queue.async { [self] in
            sweeper.systemMemory.resetRate()
            runSelfCheck(initial: false)
        }
    }

    private func refreshTopIfDue(force: Bool) {
        guard source === topSource else { return }
        let now = Clock.uptime()
        let every = max(60, config.sampleInterval)
        guard force || lastTopRunUptime < 0 || now - lastTopRunUptime >= every else { return }
        lastTopRunUptime = now
        if let err = topSource.refresh() {
            sink.error(where: "top", err)
        }
    }

    // MARK: - Ticks

    private func armBaseTimer() {
        baseTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let delay = max(0, nextBaseDue - Clock.uptime())
        t.schedule(deadline: .now() + delay, leeway: .milliseconds(Int(config.leeway * 1000)))
        t.setEventHandler { [weak self] in self?.baseTimerFired() }
        t.resume()
        baseTimer = t
    }

    private func baseTimerFired() {
        // A display sweep may already have consumed this tick.
        if Clock.uptime() + 0.001 < nextBaseDue - config.leeway {
            armBaseTimer()
            return
        }
        baseTick()
    }

    private func baseTick() {
        guard !exiting, !draining else { return }
        let now = Clock.uptime()
        nextBaseDue += config.sampleInterval
        if nextBaseDue < now { nextBaseDue = now + config.sampleInterval }
        armBaseTimer()

        if now - lastSelfCheckUptime >= 3600 { runSelfCheck(initial: false) }
        reloadRules(force: false)
        retryLock()
        refreshTopIfDue(force: false)
        let snap = source.sweep()
        checkDegrade()
        let groups = grouper.group(snap)
        history?.bufferSystem(SystemRow(t: snap.wallTime, system: snap.system,
                                        intervalSeconds: config.sampleInterval))
        recentActions.removeAll { $0.ts < snap.wallTime - Self.actionsKeptSeconds }
        runDetector(snap, groups: groups)
        lastSnapshot = snap
        lastGroups = groups
        if !observeOnly { evaluateRules(snap) }
        state.ruleDisplays = ruleDisplays(snap)
        flushHistory(now: snap.wallTime, force: false)
        let reading = selfMeter.read(uptime: now, menuOpenDuringInterval: menuOpen)
        if seq % 10 == 0 {
            sink.log(.`self`, SelfMeter.logLine(reading, menuOpenSeconds: menuOpenSeconds(now),
                                                displaySweeps: displaySweeps))
        }
        emitSample(snap, groups: groups, reading: reading)
        emitActivity(t: snap.wallTime)
        publish(snap, groups: groups, reading: reading)
        seq += 1
    }

    /// A display-only sweep while the menu is open (every 5 s). A sweep that lands on a due
    /// base tick counts as that tick.
    private func displaySweep() {
        guard !exiting, !draining else { return }
        displaySweeps += 1
        let now = Clock.uptime()
        if now + 1.0 >= nextBaseDue {
            baseTick()
            return
        }
        let snap = source.sweep()
        let groups = grouper.group(snap)
        publish(snap, groups: groups, reading: selfMeter.last)
    }

    // MARK: - Detector

    /// One observation per readable process and per all-system coalition (§ H).
    static func observations(_ s: Snapshot, groups: [ProcessGroup], home: String) -> [SeriesObservation] {
        var out: [SeriesObservation] = []
        for g in groups {
            for i in g.members {
                let e = s.entries[i]
                guard e.readable, let fp = e.footprint else { continue }
                let label = g.members.count == 1 ? g.label : "\(g.label) · \(Labeler.memberName(e))"
                out.append(SeriesObservation(key: e.identity.seriesKey, kind: "process", pid: e.pid,
                                             label: label, path: PathSanitizer.sanitize(e.path, home: home),
                                             groupLabel: g.label, footprint: fp, lifetimeMax: e.lifetimeMax))
            }
            if g.kind == .system, g.coalition != nil, let fp = g.footprint {
                out.append(SeriesObservation(key: g.key, kind: "coalition", pid: nil, label: g.label,
                                             path: "", groupLabel: g.label, footprint: fp, lifetimeMax: nil))
            }
        }
        return out
    }

    private func runDetector(_ s: Snapshot, groups: [ProcessGroup]) {
        let events = detector.tick(t: s.wallTime, observations: Self.observations(s, groups: groups, home: sweeper.home))
        for e in events {
            switch e {
            case .flag(let f):
                sink.log(.detector, "flag \(f.reason) series=\(f.seriesKey) label=\(f.label) footprint=\(f.footprint) slopeMBPerHour=\(f.slopeMBPerHour.map { String(format: "%.0f", $0) } ?? "null") baselineMB=\(f.baselineMB.map { String(format: "%.0f", $0) } ?? "null")")
                sink.emit("flag", f.json(type: "flag"))
                if coveredThreshold(seriesKey: f.seriesKey, in: s) == nil { state.dotGeneration += 1 }
            case .unflag(let f):
                sink.log(.detector, "unflag \(f.reason) series=\(f.seriesKey) label=\(f.label) footprint=\(f.footprint)")
                sink.emit("unflag", f.json(type: "unflag"))
            case .bucketClosed(let key, let bucket):
                history?.bufferBucket(key: key, bucket: bucket, meta: detector.meta(key))
            }
        }
        state.flags = detector.flags.map { f in
            FlagInfo(seriesKey: f.key, pid: f.pid, label: f.label, footprint: f.footprint,
                     slopeMBPerHour: f.flag.slopeMBPerHour, baselineMB: f.flag.baselineMB, reason: f.flag.reason,
                     coveredByRuleThresholdMB: coveredThreshold(seriesKey: f.key, in: s))
        }.sorted { $0.footprint > $1.footprint }
    }

    /// The threshold of the enabled, valid rule that handles this series (P4), else nil.
    private func coveredThreshold(seriesKey: String, in s: Snapshot) -> Int? {
        guard seriesKey.hasPrefix("proc:"),
              let e = s.entries.first(where: { $0.identity.seriesKey == seriesKey }),
              e.euid == sweeper.ownUid else { return nil }
        for r in rules.validRules where r.enabled && pauses[r.id] == nil {
            switch r.target {
            case .wallpaper:
                if e.path == RestartTarget.wallpaperExtensionPath { return r.footprintAboveMB }
            #if DEBUG
            case .rigHelper:
                if let p = config.rigHelperPath, e.path == p { return r.footprintAboveMB }
            #endif
            }
        }
        return nil
    }

    // MARK: - Rules and actions (§ I, § J)

    private func emitDecision(_ ruleId: String, _ reason: String, t: Double) {
        sink.log(.rules, "decision rule=\(ruleId) reason=\(reason)")
        sink.emit("decision", .object([
            ("type", .string("decision")),
            ("t", .double(t)),
            ("ruleId", .string(ruleId)),
            ("reason", .string(reason)),
        ]))
    }

    private func evaluateRules(_ s: Snapshot) {
        let now = s.wallTime
        let ctx = EvaluationContext(now: now, ownUid: sweeper.ownUid,
                                    actions: recentActions.filter { now - $0.ts < 86400 },
                                    pauses: pauses, verifying: Set(verifies.keys),
                                    rigHelperPath: config.rigHelperPath)
        let (intents, decisions) = RuleEvaluator.evaluate(snapshot: s, rules: rules, ctx: ctx, state: &evalState)
        for d in decisions { emitDecision(d.ruleId, d.reason, t: now) }
        for intent in intents { act(intent, snapshot: s) }
    }

    private func act(_ intent: Intent, snapshot s: Snapshot) {
        let now = Clock.wall()
        let wsBefore = intent.target == .wallpaper ? wsFootprintMB(s) : nil
        let result = actuator.execute(intent, now: now, recorder: history, wsBeforeMB: wsBefore)
        func record(_ id: Int64, outcome: String, dry: Bool) {
            recentActions.append(ActionRow(id: id, ts: now, ruleId: intent.ruleId, target: intent.target.rawValue,
                                           pids: intent.restartSet.map(\.pid), beforeMB: intent.beforeMB,
                                           afterMB: nil, outcome: outcome, dryRun: dry,
                                           wsBeforeMB: wsBefore, wsAfterMB: nil))
            maxPerDayCheck(ruleId: intent.ruleId, now: now)
            recomputeActivity()
        }
        switch result {
        case .identityChanged:
            if evalState.emitted(ruleId: intent.ruleId, reason: "identity-changed") {
                emitDecision(intent.ruleId, "identity-changed", t: now)
            }
        case .historyOff:
            if let h = history, !h.isOn { historyOff(h.error ?? "insert failed") }
            if evalState.emitted(ruleId: intent.ruleId, reason: "history-off") {
                emitDecision(intent.ruleId, "history-off", t: now)
            }
        case .dryRun(let id):
            record(id, outcome: "dry-run", dry: true)
        case .signalled(let id):
            record(id, outcome: "signalled", dry: false)
            state.dotGeneration += 1
        case .verifying(let plan):
            record(plan.actionId, outcome: "pending", dry: false)
            state.dotGeneration += 1
            startVerify(plan)
        }
    }

    /// The action that reaches maxPerDay also writes a `max-per-day` pause.
    private func maxPerDayCheck(ruleId: String, now: Double) {
        guard let rule = rules.validRules.first(where: { $0.id == ruleId }) else { return }
        if RuleEvaluator.reachesMaxPerDay(rule: rule, actions: recentActions, now: now) && pauses[ruleId] == nil {
            pause(ruleId, reason: "max-per-day", at: now)
        }
    }

    private func pause(_ ruleId: String, reason: String, at now: Double) {
        pauses[ruleId] = reason
        state.dotGeneration += 1
        sink.log(.rules, "rule \(ruleId) paused: \(reason)")
        if let h = history, !h.setPause(ruleId: ruleId, reason: reason, at: now) {
            historyOff(h.error ?? "rule_state write failed")
        }
    }

    private func startVerify(_ plan: VerifyPlan) {
        let start = Clock.uptime()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + VerifyPlan.cadence, repeating: VerifyPlan.cadence, leeway: .milliseconds(100))
        let ruleId = plan.ruleId
        t.setEventHandler { [weak self] in self?.verifyTick(ruleId) }
        verifies[ruleId] = (plan, start, t)
        t.resume()
    }

    private func verifyTick(_ ruleId: String) {
        guard var v = verifies[ruleId] else { return }
        let elapsed = Clock.uptime() - v.start
        let result = actuator.poll(&v.plan, elapsed: elapsed, wsNowMB: { [self] in wsFootprintNowMB() })
        verifies[ruleId] = v
        guard let result else { return }
        v.timer.cancel()
        verifies.removeValue(forKey: ruleId)
        let now = Clock.wall()
        if !actuator.finish(actionId: v.plan.actionId, ruleId: ruleId, result: result,
                            wsBeforeMB: v.plan.wsBeforeMB, recorder: history, now: now) {
            if let h = history { historyOff(h.error ?? "outcome write failed") }
        }
        if let i = recentActions.firstIndex(where: { $0.id == v.plan.actionId }) {
            recentActions[i].outcome = result.outcome
            recentActions[i].afterMB = result.afterMB
            recentActions[i].wsAfterMB = result.wsAfterMB
        }
        if result.outcome != "ok" {
            // No retry: the rule is paused with that reason.
            pause(ruleId, reason: result.outcome, at: now)
        }
        state.ruleDisplays = lastSnapshot.map(ruleDisplays) ?? state.ruleDisplays
        recomputeActivity()
        sendState()
        if draining && verifies.isEmpty && openQuits.isEmpty { reallyFinish(exitCode: pendingExitCode) }
    }

    /// WindowServer's coalition footprint in a snapshot (its group's total).
    private func wsFootprintMB(_ s: Snapshot) -> Double? {
        guard let ws = s.entries.first(where: { $0.path.hasSuffix("/WindowServer") }) else { return nil }
        if ws.coalition != 0, let c = s.coalitions[ws.coalition] { return Double(c.footprint) / 1_048_576 }
        let g = lastGroups.first { $0.coalition == ws.coalition }
        return g?.footprint.map { Double($0) / 1_048_576 }
    }

    /// WindowServer's coalition footprint right now (verify).
    private func wsFootprintNowMB() -> Double? {
        guard let s = lastSnapshot, let ws = s.entries.first(where: { $0.path.hasSuffix("/WindowServer") }),
              ws.coalition != 0 else { return nil }
        if source === live {
            var fp: UInt64 = 0, st: UInt64 = 0, ex: UInt64 = 0
            if sw_coalition_usage(ws.coalition, &fp, &st, &ex) == 0 { return Double(fp) / 1_048_576 }
        }
        return wsFootprintMB(s)
    }

    private func ruleDisplays(_ s: Snapshot) -> [RuleDisplay] {
        rules.validRules.filter { $0.target == .wallpaper }.map { r in
            let trig = RuleEvaluator.resolve(s, path: RestartTarget.wallpaperExtensionPath, ownUid: sweeper.ownUid)
            let last = recentActions.filter { $0.ruleId == r.id && !$0.dryRun }.max { $0.id < $1.id }
            return RuleDisplay(ruleId: r.id, enabled: r.enabled, thresholdMB: r.footprintAboveMB,
                               pausedReason: pauses[r.id],
                               lastAction: last.map { ActionDisplay(id: $0.id, ts: $0.ts, beforeMB: $0.beforeMB,
                                                                    afterMB: $0.afterMB, outcome: $0.outcome,
                                                                    dryRun: $0.dryRun) },
                               triggerFootprint: trig.isEmpty ? nil : trig.reduce(UInt64(0)) { $0 + $1.footprint })
        }
    }

    // MARK: - Menu actions

    /// The menu toggle (only when the file parsed and every rule is valid).
    public func setRuleEnabled(_ ruleId: String, enabled: Bool) {
        queue.async { [self] in
            guard !observeOnly else { return }
            let url = RulesFile.url(in: config.stateDir)
            switch RulesFile.writeEnabled(url: url, load: rules, ruleId: ruleId, enabled: enabled) {
            case .written: sink.log(.rules, "rule \(ruleId) enabled=\(enabled) written")
            case .skippedChanged: sink.log(.rules, "rules.json changed on disk; write skipped")
            case .notAllowed: sink.log(.rules, "rules.json has invalid rules; toggle not written")
            case .failed(let e): sink.error(where: "rules", "write failed: \(e)", category: .rules)
            }
            reloadRules(force: true)
            republish()
        }
    }

    /// v1-quit-on-close S5: the menu's quit toggle and the Never-quit list, written like the
    /// wallpaper toggle (whole file valid, unchanged on disk since the load, atomic v2 write).
    public func setQuitEnabled(_ enabled: Bool) {
        writeQuit("quit-on-last-window enabled=\(enabled)") { url, load in
            RulesFile.writeQuitEnabled(url: url, load: load, enabled: enabled)
        }
    }

    public func addNeverQuit(bundleId: String, name: String) {
        writeQuit("never quit + \(bundleId)") { url, load in
            RulesFile.addNeverQuit(url: url, load: load, bundleId: bundleId, name: name, now: Clock.wall(),
                                   timeZone: .autoupdatingCurrent)
        }
    }

    public func removeNeverQuit(bundleId: String) {
        writeQuit("never quit − \(bundleId)") { url, load in
            RulesFile.removeNeverQuit(url: url, load: load, bundleId: bundleId)
        }
    }

    private func writeQuit(_ what: String, _ write: @escaping (URL, RulesLoad) -> WriteResult) {
        queue.async { [self] in
            guard !observeOnly else { return }
            let url = RulesFile.url(in: config.stateDir)
            switch write(url, rules) {
            case .written: sink.log(.rules, "\(what) written")
            case .skippedChanged: sink.log(.rules, "rules.json changed on disk; write skipped")
            case .notAllowed: sink.log(.rules, "rules.json has invalid parts; \(what) not written")
            case .failed(let e): sink.error(where: "rules", "write failed: \(e)", category: .rules)
            }
            reloadRules(force: true)
            republish()
        }
    }

    public func restoreDefaultRules() {
        queue.async { [self] in
            guard !observeOnly else { return }
            switch RulesFile.restoreDefault(url: RulesFile.url(in: config.stateDir)) {
            case .written: sink.log(.rules, "default rules restored")
            case .skippedChanged: sink.log(.rules, "rules.json changed on disk; write skipped")
            case .notAllowed: break
            case .failed(let e): sink.error(where: "rules", "restore failed: \(e)", category: .rules)
            }
            reloadRules(force: true)
            republish()
        }
    }

    /// `Resume`: clears a pause (the circuit breaker clears only here).
    public func resumeRule(_ ruleId: String) {
        queue.async { [self] in
            guard !observeOnly, pauses[ruleId] != nil else { return }
            pauses.removeValue(forKey: ruleId)
            sink.log(.rules, "rule \(ruleId) resumed by the owner")
            if let h = history, !h.clearPause(ruleId: ruleId) { historyOff(h.error ?? "rule_state delete failed") }
            republish()
        }
    }

    private func republish() {
        state.rules = rules
        if let s = lastSnapshot { state.ruleDisplays = ruleDisplays(s) }
        recomputeActivity()
        sendState()
    }

    private func checkDegrade() {
        guard source === live else { return }
        let d = sweeper.lastDiagnostics
        if d.drift || d.symbolMissing {
            degrade(reason: d.firstError ?? "coalition read failed")
            return
        }
        if d.allSystemCoalitionErrors > 0 {
            degradeStreak += 1
            if degradeStreak >= 2 { degrade(reason: d.firstError ?? "coalition errors") }
        } else {
            degradeStreak = 0
        }
    }

    private func degrade(reason: String) {
        sink.log(.sampler, "source degraded to top: \(reason)")
        source = topSource
        degradeStreak = 0
        selfCheck?.coalition = .fail
        refreshTopIfDue(force: true)
    }

    // MARK: - Menu

    public func setMenuOpen(_ open: Bool) {
        queue.async { [self] in
            guard open != menuOpen else { return }
            let now = Clock.uptime()
            // T6: a reading at every transition, labelled with the state before it, so each
            // interval between two readings is entirely open or entirely closed.
            _ = selfMeter.read(uptime: now, menuOpenDuringInterval: menuOpen)
            menuOpen = open
            if open {
                menuOpenSince = now
                reloadRules(force: false)
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now(), repeating: Self.displayInterval, leeway: .milliseconds(500))
                t.setEventHandler { [weak self] in self?.displaySweep() }
                t.resume()
                displayTimer = t
            } else {
                if let since = menuOpenSince { menuOpenAccum += now - since }
                menuOpenSince = nil
                displayTimer?.cancel()
                displayTimer = nil
            }
        }
    }

    private func menuOpenSeconds(_ now: Double) -> Double {
        menuOpenAccum + (menuOpenSince.map { now - $0 } ?? 0)
    }

    /// The menu has been open at least once (the budget's "after use").
    private var menuEverShown: Bool { menuOpenSince != nil || menuOpenAccum > 0 }

    // MARK: - Rules

    private func reloadRules(force: Bool) {
        let url = RulesFile.url(in: config.stateDir)
        let st = RulesFile.fileStat(url)
        if !force {
            let same: Bool
            switch (st, rules.mtime) {
            case (nil, nil): same = rules.status == .missing
            case let ((m, s)?, old?):
                same = m.tv_sec == old.tv_sec && m.tv_nsec == old.tv_nsec && s == rules.size
            default: same = false
            }
            if same { return }
        }
        rules = RulesFile.load(url: url, allowedTargets: config.allowedTargets)
        sink.log(.rules, rules.logLine)
        sink.emit("rules", rules.json)
    }

    // MARK: - Output

    private func emitSample(_ s: Snapshot, groups: [ProcessGroup], reading: SelfReading) {
        guard sink.wantsJSON("sample") else { return }
        let home = sweeper.home
        sink.emit("sample", .object([
            ("type", .string("sample")),
            ("t", .double(s.wallTime)),
            ("seq", .i(seq)),
            ("system", .object([
                ("freePct", .i(s.system.freePct)),
                ("pressure", .i(s.system.pressure)),
                ("swapUsedBytes", .uint(s.system.swapUsedBytes)),
                ("swapinBytesPerSec", .opt(s.system.swapinBytesPerSec)),
                ("compressedBytes", .uint(s.system.compressedBytes)),
            ])),
            ("groups", .array(groups.map { g in
                .object([
                    ("key", .string(g.key)),
                    ("label", .string(g.label)),
                    ("kind", .string(g.kind.rawValue)),
                    ("footprint", .opt(g.footprint)),
                    ("members", .array(g.members.map { i in
                        let e = s.entries[i]
                        return .object([
                            ("pid", .i(e.pid)),
                            ("ppid", .i(e.ppid)),
                            ("startTime", .double(e.startTime)),
                            ("name", .string(e.name)),
                            ("path", .string(PathSanitizer.sanitize(e.path, home: home))),
                            ("footprint", .opt(e.footprint)),
                            ("readable", .bool(e.readable)),
                            ("coalition", .uint(e.coalition)),
                        ])
                    })),
                ])
            })),
            ("self", reading.json),
        ]))
    }

    private func publish(_ s: Snapshot, groups: [ProcessGroup], reading: SelfReading?) {
        state.snapshot = s
        state.groups = groups
        state.rules = rules
        state.source = source.kind
        state.selfCheck = selfCheck
        state.selfReading = reading
        state.seq = seq
        state.historyError = historyError
        state.observeOnly = observeOnly
        probeCoverageIfNewDay()
        recomputeActivity()
        if let reading { state.overBudget = SelfMeter.overBudget(reading, topMode: source !== live, menuShown: menuEverShown) }
        sendState()
    }

    // MARK: - Exit

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            src.setEventHandler { [weak self] in self?.reallyFinish(exitCode: 0) }
            src.resume()
            signalSources.append(src)
        }
    }

    private var pendingExitCode: Int32 = 0

    /// Menu Quit (and the rig's menu cycles): flush history, then exit 0.
    public func requestQuit() {
        queue.async { [self] in reallyFinish(exitCode: 0) }
    }

    /// `--duration` waits for an in-flight verify (at most 180 s more) and for open quit
    /// outcomes (at most 35 s more, T11b) so no action is left `pending`; SIGTERM / SIGINT flush
    /// and exit right away.
    public func finish(exitCode: Int32, waitForVerify: Bool = false) {
        guard !exiting else { return }
        if waitForVerify && (!verifies.isEmpty || !openQuits.isEmpty) {
            guard !draining else { return }
            draining = true
            pendingExitCode = exitCode
            baseTimer?.cancel()
            displayTimer?.cancel()
            sink.log(.actions, "duration reached with \(verifies.count) verify and \(openQuits.count) quit outcome(s) in flight; finishing them first")
            let wait: Double = verifies.isEmpty ? QuitTiming.outcome + 5 : 180
            queue.asyncAfter(deadline: .now() + wait) { [self] in reallyFinish(exitCode: exitCode) }
            return
        }
        reallyFinish(exitCode: exitCode)
    }

    private func reallyFinish(exitCode: Int32) {
        guard !exiting else { return }
        exiting = true
        baseTimer?.cancel()
        displayTimer?.cancel()
        for v in verifies.values { v.timer.cancel() }
        flushHistory(now: Clock.wall(), force: true)
        history?.close()
        terminate(exitCode)
    }

    /// `--print-menu` / `--dump-snapshot`: the self-check, one sample, no rules evaluation, no
    /// lock, no writes. Runs synchronously on the engine queue.
    public func oneShot() -> (snapshot: Snapshot, groups: [ProcessGroup], state: EngineState) {
        queue.sync {
            oneShotMode = true
            recomputeActivity()
            runSelfCheck(initial: true)
            if source !== live { refreshTopIfDue(force: true) }
            let url = RulesFile.url(in: config.stateDir)
            rules = RulesFile.load(url: url, allowedTargets: config.allowedTargets)
            _ = selfMeter.read()
            let snap = source.sweep()
            let groups = grouper.group(snap)
            let reading = selfMeter.read()
            state.snapshot = snap
            state.groups = groups
            state.rules = rules
            state.source = source.kind
            state.selfCheck = selfCheck
            state.selfReading = reading
            state.overBudget = SelfMeter.overBudget(reading, topMode: source !== live, menuShown: menuEverShown)
            lastGroups = groups
            state.ruleDisplays = ruleDisplays(snap)
            state.quit = quitDisplay(now: Clock.wall())
            return (snap, groups, state)
        }
    }

    /// Runs `body` on the engine queue (tests and the app).
    public func sync<T>(_ body: () -> T) -> T { queue.sync(execute: body) }

    // MARK: - Quit on last window close (v1-quit-on-close S3)

    private var historyOn: Bool { history?.isOn ?? false }

    /// Tests: the start sequence's state dir, lock, history and rules, with no timer, no sweep
    /// and no signal handler.
    func prepareForTests() {
        queue.sync {
            prepareState()
            reloadRules(force: true)
        }
    }

    /// Tests: the current state, read on the engine queue.
    var stateForTests: EngineState { queue.sync { state } }

    private func quitView() -> QuitEngineView {
        QuitEngineView(settings: rules.quit, observeOnly: observeOnly, historyOn: historyOn,
                       dryRun: config.dryRun, rigPrefix: config.rigQuitBundlePrefix)
    }

    private func quitDisplay(now: Double) -> QuitDisplay {
        let settings = rules.quit
        let paused = QuitDisplay.pausedReason(settings: settings, oneShot: oneShotMode, observeOnly: observeOnly,
                                              historyOn: historyOn, watcher: watcherStatus)
        let last = recentActions.filter { $0.ruleId == QuitDisplay.ruleId && !$0.dryRun && now - $0.ts <= QuitTiming.lastQuitRow }
            .max { $0.id < $1.id }
        let lastQuit = last.map { r in
            QuitActionDisplay(ts: r.ts, bundleId: r.target, name: quitName(r), beforeMB: r.beforeMB, outcome: r.outcome)
        }
        return QuitDisplay(settings: settings, paused: paused, watching: watcherStatus?.armed ?? 0, lastQuit: lastQuit)
    }

    /// The `apps` entry's name, then the name seen at quit time, then LaunchServices, then the id.
    private func quitName(_ r: ActionRow) -> String {
        rules.quit.name(for: r.target) ?? quitNames[r.id] ?? appNameProvider?.name(forBundleId: r.target) ?? r.target
    }

    /// The watcher's view: re-stats `rules.json` (reloading it when its mtime or size changed),
    /// so a menu or hand edit applies to the very next decision. Called from the watcher thread.
    public func currentQuitView() -> QuitEngineView {
        queue.sync {
            reloadRules(force: false)
            return quitView()
        }
    }

    /// The footprint of the app's group (the coalition group holding `pid`, the number its menu
    /// row shows), from a fresh sweep; the last snapshot's value when the sweep has no group for
    /// it. `cpuMs` is this call's thread CPU on the engine queue.
    public func groupFootprintMB(pid: Int32) -> (mb: Double?, cpuMs: Double) {
        queue.sync {
            let c0 = threadCpuMs()
            func find(_ s: Snapshot, _ groups: [ProcessGroup]) -> Double? {
                guard let g = groups.first(where: { g in g.members.contains { s.entries[$0].pid == pid } }),
                      let fp = g.footprint else { return nil }
                return Double(fp) / 1_048_576
            }
            let snap = source.sweep()
            var mb = find(snap, grouper.group(snap))
            if mb == nil, let s = lastSnapshot { mb = find(s, lastGroups) }
            return (mb, threadCpuMs() - c0)
        }
    }

    /// Writes the quit row first (no row, no quit: T6 `history-off`). nil when history is off,
    /// the engine is observe-only, or the insert failed.
    public func recordQuit(pid: Int32, bundleId: String, name: String, beforeMB: Double, dryRun: Bool,
                           at now: Double) -> Int64? {
        queue.sync {
            guard !observeOnly, let h = history, h.isOn else { return nil }
            let outcome = dryRun ? "dry-run" : "pending"
            guard let id = h.insertAction(ts: now, ruleId: QuitDisplay.ruleId, target: bundleId, pids: [pid],
                                          beforeMB: beforeMB, outcome: outcome, dryRun: dryRun) else {
                historyOff(h.error ?? "insert failed")
                return nil
            }
            sink.log(.actions, "action id=\(id) rule=\(QuitDisplay.ruleId) target=\(bundleId) app=\"\(name)\" pids=[\(pid)] beforeMB=\(String(format: "%.1f", beforeMB)) dryRun=\(dryRun) outcome=\(outcome)")
            sink.emit("action", .object([
                ("type", .string("action")),
                ("t", .double(now)),
                ("actionId", .int(id)),
                ("ruleId", .string(QuitDisplay.ruleId)),
                ("target", .string(bundleId)),
                ("pids", .array([.i(pid)])),
                ("beforeMB", .double(beforeMB)),
                ("dryRun", .bool(dryRun)),
                ("outcome", .string(outcome)),
                ("app", .string(name)),
            ]))
            recentActions.append(ActionRow(id: id, ts: now, ruleId: QuitDisplay.ruleId, target: bundleId, pids: [pid],
                                           beforeMB: beforeMB, afterMB: nil, outcome: outcome, dryRun: dryRun,
                                           wsBeforeMB: nil, wsAfterMB: nil))
            quitNames[id] = name
            if !dryRun { openQuits.insert(id) }
            recomputeActivity()
            sendState()
            return id
        }
    }

    /// `ok`, `refused` or `not-sent` (T9).
    public func updateQuitOutcome(id: Int64, outcome: String) {
        queue.async { [self] in
            let now = Clock.wall()
            if let h = history, !h.updateOutcome(id: id, outcome: outcome, afterMB: nil, wsBeforeMB: nil, wsAfterMB: nil) {
                historyOff(h.error ?? "outcome write failed")
            }
            sink.log(.actions, "actionOutcome id=\(id) rule=\(QuitDisplay.ruleId) outcome=\(outcome)")
            sink.emit("actionOutcome", Actuator.outcomeJSON(t: now, actionId: id, outcome: outcome, afterMB: nil,
                                                            wsBeforeMB: nil, wsAfterMB: nil))
            if let i = recentActions.firstIndex(where: { $0.id == id }) { recentActions[i].outcome = outcome }
            openQuits.remove(id)
            recomputeActivity()
            sendState()
            if draining && verifies.isEmpty && openQuits.isEmpty { reallyFinish(exitCode: pendingExitCode) }
        }
    }

    /// The watcher reports trust, availability, Stage Manager and its counts; a change emits a
    /// `quitStatus` line and republishes.
    public func setWatcherStatus(_ status: WatcherStatus) {
        queue.async { [self] in
            guard status != watcherStatus else { return }
            watcherStatus = status
            let paused = QuitDisplay.pausedReason(settings: rules.quit, oneShot: oneShotMode, observeOnly: observeOnly,
                                                  historyOn: historyOn, watcher: status)
            sink.emit("quitStatus", .object([
                ("type", .string("quitStatus")),
                ("t", .double(Clock.wall())),
                ("enabled", .bool(rules.quit.isActive)),
                ("trusted", .bool(status.trusted)),
                ("available", .bool(status.available)),
                ("paused", .opt(paused)),
                ("tracked", .i(status.tracked)),
                ("armed", .i(status.armed)),
            ]))
            sink.log(.quit, "quit status enabled=\(rules.quit.isActive) trusted=\(status.trusted) available=\(status.available) unavailable=\(status.unavailableReason ?? "null") stageManager=\(status.stageManager) tracked=\(status.tracked) armed=\(status.armed)")
            sendState()
        }
    }
}
