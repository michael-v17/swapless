import AppKit
import ApplicationServices
import Darwin
import SwaplessCore

/// The AX observer's refcon: which pid an event belongs to.
private final class ObserverBox {
    weak var watcher: WindowWatcher?
    let pid: Int32

    init(watcher: WindowWatcher, pid: Int32) {
        self.watcher = watcher
        self.pid = pid
    }
}

/// Runs on the watcher thread (the observer's source is on its run loop).
private let axCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let box = Unmanaged<ObserverBox>.fromOpaque(refcon).takeUnretainedValue()
    box.watcher?.axEvent(pid: box.pid, element: element, note: notification as String)
}

private let displayCallback: CGDisplayReconfigurationCallBack = { _, flags, refcon in
    guard let refcon, !flags.contains(.beginConfigurationFlag) else { return }
    let w = Unmanaged<WindowWatcher>.fromOpaque(refcon).takeUnretainedValue()
    w.perform { w.displayChanged() }
}

/// Quit on last window close (spec v1-quit-on-close S3, T2–T13). One dedicated thread with its
/// own `CFRunLoop` carries every `AXObserver` and does every AX, CG and SkyLight call; the main
/// thread never calls AX. All mutable state below is confined to that thread; other threads
/// reach it only through `perform`.
final class WindowWatcher: @unchecked Sendable {
    private let engine: Engine
    private let sink: EventSink
    private let sender: QuitSending
    private let api = PrivateWindowAPI()
    private var unavailableReason: String?

    private var thread: Thread?
    private var runLoop: CFRunLoop?

    // Watcher-thread state.
    private var view: QuitEngineView?
    private var trusted = false
    private var watching = false
    private var tracker = QuitTracker()
    private var generation = 0
    private var observers: [Int32: (observer: AXObserver, box: Unmanaged<ObserverBox>, app: AXUIElement)] = [:]
    private var apps: [Int32: NSRunningApplication] = [:]
    private var cpu: [Int32: Double] = [:]
    private var heldQuit: [Int32: QuitDecision] = [:]
    private var outcomes: [Int64: NSRunningApplication] = [:]
    private var pauses: Set<String> = []
    private var displayUntil: Double = 0
    private var trustTimer: CFRunLoopTimer?
    private var lastStatus: WatcherStatus?

    // Main-thread observers.
    private var kvo: NSKeyValueObservation?
    private var tokens: [NSObjectProtocol] = []

    init(engine: Engine, sink: EventSink, dryRun: Bool) {
        self.engine = engine
        self.sink = sink
        self.sender = dryRun ? DryRunQuitSender(sink: sink) : LiveQuitSender()
    }

    private static func now() -> Double { Date().timeIntervalSince1970 }

    // MARK: - Thread

    /// Call on the main thread, before `engine.start()`.
    func start() {
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [unowned self] in
            runLoop = CFRunLoopGetCurrent()
            // A port keeps the run loop alive with no other source.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            unavailableReason = api.checkedReason()
            trusted = AXIsProcessTrusted()
            ready.signal()
            CFRunLoopRun()
        }
        t.name = "com.michaelv.swapless.quit-watcher"
        t.qualityOfService = .utility
        thread = t
        t.start()
        ready.wait()

        engine.onQuitView = { [weak self] v in self?.perform { self?.apply(v) } }
        engine.appNameProvider = LaunchServicesAppNames()

        // KVO on runningApplications: NSWorkspace never posts didLaunch / didTerminate for
        // LSUIElement apps, and KVO reaches a CFRunLoopRun headless process too (P3 finding).
        kvo = NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new]) { [weak self] _, change in
            let added = change.newValue ?? []
            let removed = change.oldValue ?? []
            self?.perform { self?.appsChanged(added: added, removed: removed) }
        }
        let wnc = NSWorkspace.shared.notificationCenter
        tokens.append(wnc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.perform { self?.reenumerate() }
        })
        tokens.append(wnc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.perform { self?.setPause("asleep") }
        })
        tokens.append(wnc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.perform { self?.clearPause("asleep") }
        })
        let dnc = DistributedNotificationCenter.default()
        tokens.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: nil) { [weak self] _ in
            self?.perform { self?.setPause("locked") }
        })
        tokens.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil) { [weak self] _ in
            self?.perform { self?.clearPause("locked") }
        })
        CGDisplayRegisterReconfigurationCallback(displayCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Runs `block` on the watcher thread.
    func perform(_ block: @escaping () -> Void) {
        guard let rl = runLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(rl)
    }

    /// At wall time `at` on the watcher thread, unless the watcher reset since.
    private func schedule(at: Double, _ block: @escaping () -> Void) {
        guard let rl = runLoop else { return }
        let gen = generation
        let delay = max(0, at - Self.now())
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + delay, 0, 0, 0) { [weak self] _ in
            guard let self, self.generation == gen else { return }
            block()
        }
        CFRunLoopAddTimer(rl, timer, .commonModes)
    }

    /// Like `schedule`, but survives a reset (quit outcomes, pause ends).
    private func scheduleAlways(after delay: Double, _ block: @escaping () -> Void) {
        guard let rl = runLoop else { return }
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + delay, 0, 0, 0) { _ in block() }
        CFRunLoopAddTimer(rl, timer, .commonModes)
    }

    // MARK: - Settings, trust

    /// The menu opened: re-read trust and Stage Manager.
    func recheck() {
        perform { [self] in
            checkTrust()
            pushStatus()
        }
    }

    private func apply(_ v: QuitEngineView) {
        view = v
        reconcile()
    }

    private var shouldWatch: Bool {
        (view?.settings.isActive ?? false) && trusted && unavailableReason == nil
    }

    private func reconcile() {
        if shouldWatch && !watching {
            enableAll()
        } else if !shouldWatch && watching {
            disableAll()
            if let v = view, v.settings.isActive == false {
                handle(tracker.cancelAll(reason: "option-off", at: Self.now()))
            }
        }
        updateTrustTimer()
        pushStatus()
    }

    private func checkTrust() {
        let t = AXIsProcessTrusted()
        guard t != trusted else { return }
        trusted = t
        sink.log(.quit, "accessibility trusted=\(t)")
        reconcile()
    }

    private func lostTrust() {
        guard trusted else { return }
        trusted = false
        sink.log(.quit, "accessibility revoked (kAXErrorAPIDisabled); observers dropped")
        reconcile()
    }

    /// Every 10 s while the option is on and Swapless isn't trusted.
    private func updateTrustTimer() {
        let need = (view?.settings.isActive ?? false) && !trusted
        if need && trustTimer == nil, let rl = runLoop {
            let t = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + QuitTiming.trustRecheck,
                                                    QuitTiming.trustRecheck, 0, 0) { [weak self] _ in self?.checkTrust() }
            CFRunLoopAddTimer(rl, t, .commonModes)
            trustTimer = t
        } else if !need, let t = trustTimer {
            CFRunLoopTimerInvalidate(t)
            trustTimer = nil
        }
    }

    // MARK: - Tracking

    private func eligible(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier, !id.isEmpty, app.processIdentifier != getpid(), !app.isTerminated else {
            return false
        }
        return app.activationPolicy == .regular || QuitGate.rigAdmits(id, prefix: view?.rigPrefix)
    }

    private func enableAll() {
        watching = true
        sink.log(.quit, "watching: registering observers on running apps")
        for app in NSWorkspace.shared.runningApplications where eligible(app) { track(app) }
    }

    private func disableAll() {
        watching = false
        generation += 1
        for (_, o) in observers {
            CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(o.observer), .commonModes)
            o.box.release()
        }
        observers.removeAll()
        apps.removeAll()
        cpu.removeAll()
        heldQuit.removeAll()
        tracker = QuitTracker()
        sink.log(.quit, "not watching: observers dropped")
    }

    private func appsChanged(added: [NSRunningApplication], removed: [NSRunningApplication]) {
        let now = Self.now()
        for app in removed {
            let pid = app.processIdentifier
            // A quit we asked for: its outcome is `ok`.
            for (id, a) in outcomes where a.processIdentifier == pid && a.launchDate == app.launchDate {
                outcomes.removeValue(forKey: id)
                engine.updateQuitOutcome(id: id, outcome: "ok")
            }
            guard apps[pid] != nil else { continue }
            for o in tracker.untrack(pid, at: now) {
                if case .decision(let d) = o { emit(d) }
            }
            if let o = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(o.observer), .commonModes)
                o.box.release()
            }
            apps.removeValue(forKey: pid)
            cpu.removeValue(forKey: pid)
        }
        if watching {
            for app in added where eligible(app) { track(app) }
        }
        pushStatus()
    }

    /// How many times an app that isn't AX-ready yet (just launched) is retried, 1 s apart.
    private static let registerAttempts = 10

    private func track(_ app: NSRunningApplication, attempt: Int = 1) {
        let pid = app.processIdentifier
        guard observers[pid] == nil, watching, !app.isTerminated else { return }
        var obs: AXObserver?
        guard AXObserverCreate(pid, axCallback, &obs) == .success, let obs else { return }
        let box = Unmanaged.passRetained(ObserverBox(watcher: self, pid: pid))
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, QuitTiming.axTimeout)
        var failed: AXError?
        for n in [kAXWindowCreatedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                  kAXApplicationDeactivatedNotification, kAXApplicationHiddenNotification, kAXApplicationShownNotification] {
            let r = AXObserverAddNotification(obs, el, n as CFString, box.toOpaque())
            if r == .apiDisabled {
                box.release()
                lostTrust()
                return
            }
            if r != .success && r != .notificationAlreadyRegistered { failed = r }
        }
        if let failed {
            // A just-launched app isn't AX-ready yet: drop this observer and retry.
            box.release()
            if attempt < Self.registerAttempts {
                schedule(at: Self.now() + 1) { [weak self] in self?.track(app, attempt: attempt + 1) }
            } else {
                sink.log(.quit, "can't observe pid \(pid) (\(app.bundleIdentifier ?? "?")): AX error \(failed.rawValue) after \(attempt) attempts")
            }
            return
        }
        CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(obs), .commonModes)
        observers[pid] = (obs, box, el)
        apps[pid] = app
        registerWindows(pid)
        let now = Self.now()
        handle(tracker.track(facts(app), at: now))
        // A window created between launch and registration fired no event: read again.
        schedule(at: now + 2) { [weak self] in
            self?.registerWindows(pid)
            self?.read(pid, purpose: .arm)
        }
    }

    /// `AXUIElementDestroyed` on every window element (−25209, already registered, is fine).
    private func registerWindows(_ pid: Int32) {
        guard let o = observers[pid] else { return }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(o.app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for w in windows {
            _ = AXObserverAddNotification(o.observer, w, kAXUIElementDestroyedNotification as CFString, o.box.toOpaque())
        }
    }

    /// Space change, wake, unlock, display settled: register new windows and re-read every app.
    private func reenumerate() {
        guard watching else { return }
        for pid in observers.keys.sorted() {
            registerWindows(pid)
            read(pid, purpose: .arm)
        }
        pushStatus()
    }

    fileprivate func axEvent(pid: Int32, element: AXUIElement, note: String) {
        guard watching, observers[pid] != nil else { return }
        let now = Self.now()
        switch note {
        case kAXUIElementDestroyedNotification:
            cpu[pid] = 0
            handle(tracker.trigger(pid, .destroyed, at: now))
        case kAXApplicationDeactivatedNotification:
            cpu[pid] = 0
            handle(tracker.trigger(pid, .deactivated, at: now))
        case kAXWindowCreatedNotification, kAXWindowDeminiaturizedNotification:
            if let o = observers[pid] {
                _ = AXObserverAddNotification(o.observer, element, kAXUIElementDestroyedNotification as CFString, o.box.toOpaque())
            }
            handle(tracker.windowCreated(pid, at: now))
        default:
            break
        }
    }

    // MARK: - Pauses (T7)

    private var currentPause: String? {
        if pauses.contains("asleep") { return "asleep" }
        if pauses.contains("locked") { return "locked" }
        return Self.now() < displayUntil ? "display-change" : nil
    }

    private func setPause(_ reason: String) {
        pauses.insert(reason)
        handle(tracker.cancelAll(reason: reason, at: Self.now()))
    }

    private func clearPause(_ reason: String) {
        guard pauses.remove(reason) != nil else { return }
        reenumerate()
    }

    fileprivate func displayChanged() {
        displayUntil = Self.now() + QuitTiming.displayChange
        handle(tracker.cancelAll(reason: "display-change", at: Self.now()))
        scheduleAlways(after: QuitTiming.displayChange + 0.1) { [weak self] in self?.reenumerate() }
    }

    // MARK: - Readings and decisions

    private static func stageManagerOn() -> Bool {
        let v = CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString)
        return (v as? Bool) ?? ((v as? NSNumber)?.boolValue ?? false)
    }

    private func environment(_ v: QuitEngineView?) -> QuitEnvironment {
        QuitEnvironment(settings: v?.settings ?? .missing, observeOnly: v?.observeOnly ?? false,
                        historyOn: v?.historyOn ?? false, trusted: trusted, available: unavailableReason == nil,
                        stageManager: Self.stageManagerOn(), pause: currentPause, rigPrefix: v?.rigPrefix,
                        selfBundleId: Bundle.main.bundleIdentifier, selfPid: getpid(), dryRun: v?.dryRun ?? false)
    }

    private func facts(_ app: NSRunningApplication) -> AppFacts {
        let pid = app.processIdentifier
        return AppFacts(pid: pid, bundleId: app.bundleIdentifier,
                        name: app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)",
                        regular: app.activationPolicy == .regular, hidden: app.isHidden,
                        launchTime: app.launchDate?.timeIntervalSince1970 ?? Self.processStart(pid) ?? 0,
                        finishedLaunching: app.isFinishedLaunching)
    }

    /// `kinfo_proc.p_starttime`, when LaunchServices has no launch date.
    private static func processStart(_ pid: Int32) -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
    }

    /// One reading of one app (T2).
    private func reading(_ pid: Int32) -> WindowReading {
        var ax: [AXWin]?
        if let o = observers[pid] {
            var value: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(o.app, kAXWindowsAttribute as CFString, &value)
            switch err {
            case .success:
                let windows = (value as? [AXUIElement]) ?? []
                ax = windows.map { w in
                    func attr<T>(_ name: String) -> T? {
                        var v: CFTypeRef?
                        guard AXUIElementCopyAttributeValue(w, name as CFString, &v) == .success else { return nil }
                        return v as? T
                    }
                    return AXWin(id: api.windowId(w) ?? 0, role: attr(kAXRoleAttribute) ?? "?",
                                 subrole: attr(kAXSubroleAttribute),
                                 minimized: (attr(kAXMinimizedAttribute) as Bool?) ?? false)
                }
            case .noValue:
                ax = []
            case .apiDisabled:
                lostTrust()
                ax = nil
            default:
                ax = nil
            }
        }
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let cg: [CGWin] = list.compactMap { d in
            guard (d[kCGWindowOwnerPID as String] as? Int32) == pid,
                  let n = d[kCGWindowNumber as String] as? NSNumber else { return nil }
            let layer = (d[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            let id = n.uint32Value
            return CGWin(id: id, layer: layer, spaces: layer == 0 ? api.spaces(id) : [])
        }
        return WindowReading(ax: ax, cg: cg, visibleSpaces: api.visibleSpaces())
    }

    private func read(_ pid: Int32, purpose: ReadPurpose) {
        guard let app = apps[pid] else { return }
        if app.isTerminated {
            appsChanged(added: [], removed: [app])
            return
        }
        let c0 = threadCpuMs()
        let r = reading(pid)
        guard watching else { return }  // trust lost during the read
        let env: QuitEnvironment
        switch purpose {
        case .decide, .confirm:
            let v = engine.currentQuitView()
            view = v
            env = environment(v)
        default:
            env = environment(view)
        }
        let out = tracker.reading(pid, r, facts: facts(app), env: env, purpose: purpose, at: Self.now())
        cpu[pid, default: 0] += threadCpuMs() - c0
        handle(out)
        if case .decide = purpose, !env.settings.isActive { reconcile() }
        pushStatus()
    }

    private func handle(_ outputs: [TrackerOutput]) {
        for o in outputs {
            switch o {
            case let .read(pid, at, purpose):
                schedule(at: at) { [weak self] in self?.read(pid, purpose: purpose) }
            case .decision(let d):
                switch d.verdict {
                case .quit:
                    heldQuit[d.pid] = d  // emitted once its row is written
                case .dryRun:
                    recordDryRun(d)
                default:
                    emit(d)
                }
            case let .terminate(pid, bundleId, name):
                quit(pid: pid, bundleId: bundleId, name: name)
            }
        }
    }

    private func emit(_ d: QuitDecision) {
        let ms = cpu[d.pid] ?? 0
        cpu[d.pid] = 0
        let cpuText = String(format: "%.1f", ms)
        sink.info(.quit, "quit decision pid=\(d.pid) app=\(d.bundleId ?? "null") trigger=\(d.trigger?.rawValue ?? "null") verdict=\(d.verdict.rawValue) reason=\(d.reason) ax=\(d.ax) elsewhere=\(d.elsewhere) closed=\(d.closed) cpuMs=\(cpuText)")
        sink.emit("quitDecision", .object([
            ("type", .string("quitDecision")),
            ("t", .double(d.at)),
            ("pid", .i(d.pid)),
            ("bundleId", .opt(d.bundleId)),
            ("trigger", .opt(d.trigger?.rawValue)),
            ("verdict", .string(d.verdict.rawValue)),
            ("reason", .string(d.reason)),
            ("alive", .i(d.alive)),
            ("ax", .i(d.ax)),
            ("elsewhere", .i(d.elsewhere)),
            ("closed", .i(d.closed)),
            ("cpuMs", .double((ms * 10).rounded() / 10)),
        ]))
    }

    private func recordDryRun(_ d: QuitDecision) {
        let (mb, fpCpu) = engine.groupFootprintMB(pid: d.pid)
        cpu[d.pid, default: 0] += fpCpu
        _ = engine.recordQuit(pid: d.pid, bundleId: d.bundleId ?? "", name: d.name, beforeMB: mb ?? 0,
                              dryRun: true, at: d.at)
        emit(d)
    }

    /// The row first, then the app's own Quit on the main thread (T6, T9).
    private func quit(pid: Int32, bundleId: String, name: String) {
        guard var d = heldQuit.removeValue(forKey: pid) else { return }
        guard let app = apps[pid], app.bundleIdentifier == bundleId, !app.isTerminated else {
            d.verdict = .skip
            d.reason = "gone"
            emit(d)
            return
        }
        let (mb, fpCpu) = engine.groupFootprintMB(pid: pid)
        cpu[pid, default: 0] += fpCpu
        guard let id = engine.recordQuit(pid: pid, bundleId: bundleId, name: name, beforeMB: mb ?? 0,
                                         dryRun: false, at: Self.now()) else {
            d.verdict = .skip
            d.reason = "history-off"
            emit(d)
            return
        }
        emit(d)
        let launch = app.launchDate
        let sender = self.sender
        DispatchQueue.main.async { [weak self] in
            // Same app still (pid reuse can't match: bundle id and launch date).
            let current = NSRunningApplication(processIdentifier: pid)
            let same = current?.bundleIdentifier == bundleId && current?.launchDate == launch && current?.isTerminated == false
            let sent = same ? sender.terminate(pid: pid) : false
            self?.perform { self?.quitSent(id: id, app: app, sent: sent) }
        }
    }

    private func quitSent(id: Int64, app: NSRunningApplication, sent: Bool) {
        sink.log(.actions, "terminate id=\(id) pid=\(app.processIdentifier) sent=\(sent)")
        guard sent else {
            engine.updateQuitOutcome(id: id, outcome: "not-sent")
            return
        }
        if app.isTerminated {
            engine.updateQuitOutcome(id: id, outcome: "ok")
            return
        }
        outcomes[id] = app
        scheduleAlways(after: QuitTiming.outcome) { [weak self] in
            guard let self, let a = self.outcomes.removeValue(forKey: id) else { return }
            self.engine.updateQuitOutcome(id: id, outcome: a.isTerminated ? "ok" : "refused")
        }
    }

    // MARK: - Status

    private func pushStatus() {
        let s = WatcherStatus(trusted: trusted, available: unavailableReason == nil, unavailableReason: unavailableReason,
                              stageManager: Self.stageManagerOn(), tracked: tracker.trackedCount, armed: tracker.armedCount)
        guard s != lastStatus else { return }
        lastStatus = s
        engine.setWatcherStatus(s)
    }
}
