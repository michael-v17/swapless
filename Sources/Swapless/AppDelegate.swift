import AppKit
import CSwaplessProc
import IOKit
import SwaplessCore

/// The menu-bar app (default mode).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let config: Config
    fileprivate var sink: EventSink!
    private var engine: Engine!
    fileprivate var menuController: MenuController!
    fileprivate var statusItem: StatusItemController?
    private var wake: WakeObserver?
    private var cyclesStarted = false
    private var cyclesDone = 0
    private var cyclesTimer: Timer?
    private var drawsStarted = false
    private var drawsDone = 0
    private var drawsRows = 0
    private var drawsVisible = 0
    private var drawsFootprintBefore: UInt64 = 0
    fileprivate var showsStarted = false
    fileprivate var showsDone = 0
    fileprivate var showOpened = false
    fileprivate var showAttempts = 0
    fileprivate var extraClicks = 0
    fileprivate var submenusHeld = 0
    fileprivate var missedSubmenus = 0
    fileprivate var unexpectedSubmenuCloses = 0
    fileprivate var holding = false
    fileprivate var submenuOpens = 0
    fileprivate var disturbedShows = 0
    fileprivate var showToken = 0
    fileprivate var showStart: TimeInterval = 0
    fileprivate var showCounters = (held: 0, missed: 0, unexpected: 0)
    /// Group submenus opened per show, and how long each stays open.
    static let showSubmenus = 3
    static let showSubmenuHold: TimeInterval = 6
    static let showGap: TimeInterval = 2
    static let showOpenTimeout: TimeInterval = 5
    static let showClickAttempts = 3
    static let showStepTimeout: TimeInterval = 3
    /// Keyboard and mouse idle before each show, how long to wait for that, and how many
    /// shows may be redone because input arrived during them.
    static let showIdleBefore: TimeInterval = 3
    static let showIdleWait: TimeInterval = 120
    static let maxDisturbedShows = 10

    init(config: Config) {
        self.config = config
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Normal app mode prints nothing; the rig's menu-cycle mode prints its contract lines.
        let rig = config.rigMenuCycles != nil || config.rigMenuShows != nil || config.rigMenuDraws != nil
            || config.rigMenuOpen != nil
        let types: Set<String> = rig ? ["start", "rules", "menuCycles", "menuShows", "menuDraws", "menuOpen",
                                        "menuOpenTail", "error"] : []
        sink = EventSink(jsonTypes: types)
        engine = Engine(config: config, sink: sink, labeler: Labeler(appNames: RunningAppNameProvider()),
                        signalSender: LiveSignalSender(sink: sink))
        menuController = MenuController(engine: engine, stateDir: config.stateDir)
        if config.rigMenuCycles == nil && config.rigMenuDraws == nil && config.rigMenuOpen == nil {
            let si = StatusItemController(menu: menuController.menu)
            statusItem = si
            menuController.onDot = { [weak si] on in si?.setDot(on) }
        }
        let engineRef = engine!
        wake = WakeObserver { engineRef.wake() }
        let controller = menuController!
        engine.onState = { [weak self] st in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    controller.update(st)
                    self?.maybeStartCycles(st)
                    self?.maybeStartShows(st)
                    self?.maybeStartDraws(st)
                    self?.maybeStartOpen(st)
                }
            }
        }
        engine.start()
    }

    /// `SWAPLESS_RIG_MENU_DRAWS=N` (check 5's menu test): no status item. After the first sample
    /// and a 30 s settle, act as if the menu were open (the engine's 5 s display sweeps run) and
    /// draw the real menu N times, 2 s apart, into a window that is never ordered on screen
    /// (`MenuController.drawOffscreen`); then close it, print one `menuDraws` line, and keep
    /// running for the rig's idle measurement. Nothing is shown on screen.
    private func maybeStartDraws(_ st: EngineState) {
        guard config.rigMenuDraws != nil, !drawsStarted, st.snapshot != nil else { return }
        drawsStarted = true
        menuController.actionsDisabled = true
        // Settle first, so the line can report the footprint of the same no-UI process before
        // any drawing (the "never shown" reference).
        let t = Timer(timeInterval: Self.drawSettle, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                var ru = sw_rusage_t()
                _ = sw_pid_rusage(getpid(), &ru)
                self.drawsFootprintBefore = ru.phys_footprint
                self.engine.setMenuOpen(true)
                self.drawStep()
            }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    static let drawSettle: TimeInterval = 30

    // MARK: - SWAPLESS_RIG_MENU_OPEN (check 5's offscreen menu-open test)

    /// Off the 30 s base-tick grid.
    static let openSettle: TimeInterval = 32.5
    static let openTail: TimeInterval = 120
    private var openStarted = false

    /// Own CPU (user + system + reaped children), in mach ticks × timebase.
    static func ownCpuSeconds() -> Double {
        var ru = sw_rusage_t()
        _ = sw_pid_rusage(getpid(), &ru)
        var n: UInt32 = 1, d: UInt32 = 1
        sw_timebase(&n, &d)
        return SelfMeter.ticksToSeconds(ru.user_time &+ ru.system_time &+ ru.child_user_time &+ ru.child_system_time,
                                        numer: n == 0 ? 1 : n, denom: d == 0 ? 1 : d)
    }

    /// No status item, menus never shown. After the first sample and a settle, simulate the menu
    /// open for S seconds with three group submenus opened in turn, then print `menuOpen`;
    /// 120 s later print `menuOpenTail`. Keeps running until `--duration`.
    private func maybeStartOpen(_ st: EngineState) {
        guard let seconds = config.rigMenuOpen, !openStarted, st.snapshot != nil else { return }
        openStarted = true
        menuController.actionsDisabled = true
        after(Self.openSettle) { [weak self] in
            guard let self else { return }
            let engine = self.engine!
            let cpu0 = Self.ownCpuSeconds()
            let c0 = engine.sync { (engine.displaySweeps, engine.publishes) }
            let r0 = self.menuController.refreshCount
            let b0 = self.menuController.compressedReadBatches
            self.menuController.simulateOpen(seconds: Double(seconds)) { [weak self] opened in
                guard let self else { return }
                let cpu1 = Self.ownCpuSeconds()
                let c1 = engine.sync { (engine.displaySweeps, engine.publishes) }
                let d = cpu1 - cpu0
                self.sink.emit("menuOpen", .object([
                    ("type", .string("menuOpen")),
                    ("seconds", .i(seconds)),
                    ("refreshes", .i(self.menuController.refreshCount - r0)),
                    ("displaySweeps", .i(c1.0 - c0.0)),
                    ("publishes", .i(c1.1 - c0.1)),
                    ("compressedReadBatches", .i(self.menuController.compressedReadBatches - b0)),
                    ("submenusOpened", .i(opened)),
                    ("cpuSecondsOpen", .double(d)),
                    ("cpuPercentOpen", .double(d / Double(seconds) * 100)),
                    ("windows", .i(NSApp.windows.count)),
                ]))
                self.after(Self.openTail) { [weak self] in
                    let dt = Self.ownCpuSeconds() - cpu1
                    self?.sink.emit("menuOpenTail", .object([
                        ("type", .string("menuOpenTail")),
                        ("seconds", .i(Int(Self.openTail))),
                        ("cpuSeconds", .double(dt)),
                        ("cpuPercent", .double(dt / Self.openTail * 100)),
                    ]))
                }
            }
        }
    }

    private func drawStep() {
        guard let n = config.rigMenuDraws else { return }
        let r = menuController.drawOffscreen()
        drawsRows += r.rows
        if r.visible { drawsVisible += 1 }
        drawsDone += 1
        if drawsDone < n {
            let t = Timer(timeInterval: 2.0, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.drawStep() } }
            RunLoop.main.add(t, forMode: .common)
            return
        }
        engine.setMenuOpen(false)
        var ru = sw_rusage_t()
        _ = sw_pid_rusage(getpid(), &ru)
        sink.emit("menuDraws", .object([
            ("type", .string("menuDraws")),
            ("n", .i(drawsDone)),
            ("rows", .i(drawsRows)),
            ("visibleDraws", .i(drawsVisible)),
            ("footprintBefore", .uint(drawsFootprintBefore)),
            ("footprint", .uint(ru.phys_footprint)),
            ("peakFootprint", .uint(ru.lifetime_max_phys_footprint)),
            ("windows", .i(NSApp.windows.count)),
        ]))
    }

    /// `SWAPLESS_RIG_MENU_CYCLES=N`: after the first sample, build and fill the real NSMenu N
    /// times, 2 s apart, without a status item and without showing it; then print the peak.
    private func maybeStartCycles(_ st: EngineState) {
        guard let n = config.rigMenuCycles, !cyclesStarted, st.snapshot != nil else { return }
        cyclesStarted = true
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let mc = MenuController(engine: self.engine, stateDir: self.config.stateDir)
                mc.update(self.menuController.state)
                mc.fillEverything()
                self.cyclesDone += 1
                if self.cyclesDone >= n {
                    self.cyclesTimer?.invalidate()
                    var ru = sw_rusage_t()
                    _ = sw_pid_rusage(getpid(), &ru)
                    self.sink.emit("menuCycles", .object([
                        ("type", .string("menuCycles")),
                        ("n", .i(n)),
                        ("peakFootprint", .uint(ru.lifetime_max_phys_footprint)),
                    ]))
                    self.engine.requestQuit()
                }
            }
        }
        cyclesTimer = t
        RunLoop.main.add(t, forMode: .common)
    }
}

extension AppDelegate {
    /// `SWAPLESS_RIG_MENU_SHOWS=N`: after the first sample, open the real status-item menu N
    /// times through its button, walk a few group submenus (see `showDidOpen`), close it with
    /// `cancelTracking`, then print one `menuShows` line and keep running, so the rig can
    /// measure the idle footprint after the menu closed (check 5's menu test).
    fileprivate func maybeStartShows(_ st: EngineState) {
        guard config.rigMenuShows != nil, !showsStarted, st.snapshot != nil, statusItem != nil else { return }
        showsStarted = true
        menuController.actionsDisabled = true
        menuController.onOpen = { [weak self] in self?.showDidOpen() }
        menuController.onClose = { [weak self] in self?.showClosed() }
        menuController.onSubmenuOpen = { [weak self] in self?.submenuOpens += 1 }
        menuController.onSubmenuClose = { [weak self] in
            // The walk closes a submenu only by moving on; a close during a hold came from elsewhere.
            guard let self, self.holding else { return }
            self.holding = false
            self.unexpectedSubmenuCloses += 1
        }
        scheduleShow(after: Self.showGap)
    }

    private func scheduleShow(after delay: TimeInterval) {
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showOnce() }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    /// Clicks the real status-item button once the keyboard and mouse have been idle for
    /// `showIdleBefore` s: an open menu takes the keyboard, so the owner's input would drive
    /// it. A click that doesn't open the menu within `showOpenTimeout` is repeated, up to
    /// `showClickAttempts` clicks; the extra clicks are counted in the `menuShows` line.
    private func showOnce() {
        showToken += 1
        let token = showToken
        waitUntil(Self.showIdleWait) { (Self.hidIdleSeconds() ?? .infinity) >= Self.showIdleBefore } then: { [weak self] idle in
            guard let self, self.showToken == token else { return }
            guard idle else {
                return self.finishShows(error: "disturbed: keyboard or mouse input kept coming for \(Int(Self.showIdleWait)) s")
            }
            self.showOpened = false
            self.holding = false
            self.showAttempts = 0
            self.showStart = ProcessInfo.processInfo.systemUptime
            self.showCounters = (self.submenusHeld, self.missedSubmenus, self.unexpectedSubmenuCloses)
            self.clickShow()
        }
    }

    /// Seconds since the last keyboard or mouse input (IOHIDSystem's `HIDIdleTime`; no
    /// permission needed). Events this app posts to itself don't count.
    static func hidIdleSeconds() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let v = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        if let n = v as? NSNumber { return n.doubleValue / 1e9 }
        if let d = v as? Data, d.count >= 8 { return Double(d.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }) / 1e9 }
        return nil
    }

    private func clickShow() {
        guard let button = statusItem?.item.button else { return }
        showAttempts += 1
        if showAttempts > 1 { extraClicks += 1 }
        let n = showsDone
        let token = showToken
        let attempt = showAttempts
        let watchdog = Timer(timeInterval: Self.showOpenTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.showOpened, self.showToken == token, self.showAttempts == attempt else { return }
                if attempt < Self.showClickAttempts {
                    self.clickShow()
                } else {
                    self.finishShows(error: "show \(n + 1): the menu did not open after \(attempt) clicks, \(Int(Self.showOpenTimeout)) s apart")
                }
            }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        button.performClick(nil)
    }

    /// While the menu is open, walk it like a person would: a down arrow highlights the next
    /// group, which closes the previous group's submenu and makes AppKit open this one; hold it
    /// through a 5 s refresh; then close the menu. Arrow keys go to this app's own event
    /// queue (no Accessibility). Focus stays on the top level (a left arrow there closes a
    /// status-item menu), and each step waits for the submenu to open (AppKit sometimes handles
    /// posted keys late). A submenu that closes during its hold is unexpected.
    private func showDidOpen() {
        showOpened = true
        let token = showToken
        after(0.5) { [weak self] in self?.walk(0, token) }
    }

    /// `token`: the show this step belongs to; a step left over from a redone show stops.
    private func walk(_ i: Int, _ token: Int) {
        guard menuController.isOpen, showToken == token else { return }
        guard i < Self.showSubmenus else {
            holding = false
            after(0.5) { [weak self] in self?.menuController.menu.cancelTracking() }
            return
        }
        holding = false
        let opensBefore = submenuOpens
        Self.postDownArrow()
        waitUntil(Self.showStepTimeout) { [weak self] in (self?.submenuOpens ?? 0) > opensBefore } then: { [weak self] opened in
            guard let self, self.menuController.isOpen, self.showToken == token else { return }
            guard opened else {
                self.missedSubmenus += 1
                self.walk(i + 1, token)
                return
            }
            self.submenusHeld += 1
            self.holding = true
            self.after(Self.showSubmenuHold) { [weak self] in self?.walk(i + 1, token) }
        }
    }

    fileprivate func after(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        let t = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { body() } }
        RunLoop.main.add(t, forMode: .common)
    }

    /// Polls `cond` every 0.1 s until it holds or `timeout` passes, then calls `then(held)`.
    private func waitUntil(_ timeout: TimeInterval, _ cond: @escaping @MainActor () -> Bool,
                           then: @escaping @MainActor (Bool) -> Void) {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func poll() {
            if cond() {
                then(true)
            } else if ProcessInfo.processInfo.systemUptime >= deadline {
                then(false)
            } else {
                after(0.1) { poll() }
            }
        }
        after(0.1) { poll() }
    }

    /// A down-arrow key press, posted to this app's own event queue.
    private static func postDownArrow() {
        let chars = String(Character(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!))
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.numericPad, .function],
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                        context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                        isARepeat: false, keyCode: 125) {
                NSApp.postEvent(e, atStart: false)
            }
        }
    }

    private func showClosed() {
        holding = false
        // Input during the show (the menu had the keyboard): discard its counts and redo it.
        let duration = ProcessInfo.processInfo.systemUptime - showStart
        if let idle = Self.hidIdleSeconds(), idle < duration {
            disturbedShows += 1
            (submenusHeld, missedSubmenus, unexpectedSubmenuCloses) = showCounters
            showToken += 1
            if disturbedShows > Self.maxDisturbedShows {
                return finishShows(error: "disturbed: keyboard or mouse input during \(disturbedShows) shows")
            }
            return scheduleShow(after: Self.showGap)
        }
        showsDone += 1
        if showsDone < (config.rigMenuShows ?? 0) {
            scheduleShow(after: Self.showGap)
        } else {
            finishShows(error: nil)
        }
    }

    private func finishShows(error: String?) {
        menuController.onOpen = nil
        menuController.onClose = nil
        menuController.onSubmenuOpen = nil
        menuController.onSubmenuClose = nil
        emitShows(error: error)
    }

    private func emitShows(error: String?) {
        var ru = sw_rusage_t()
        _ = sw_pid_rusage(getpid(), &ru)
        var fields: [(String, JSON)] = [
            ("type", .string("menuShows")),
            ("n", .i(showsDone)),
            ("footprint", .uint(ru.phys_footprint)),
            ("peakFootprint", .uint(ru.lifetime_max_phys_footprint)),
            ("windows", .i(NSApp.windows.count)),
            ("extraClicks", .i(extraClicks)),
            ("disturbedShows", .i(disturbedShows)),
            ("submenusPlanned", .i(showsDone * Self.showSubmenus)),
            ("submenusOpened", .i(submenusHeld)),
            ("missedSubmenus", .i(missedSubmenus)),
            ("unexpectedSubmenuCloses", .i(unexpectedSubmenuCloses)),
        ]
        if let error { fields.append(("error", .string(error))) }
        sink.emit("menuShows", .object(fields))
    }
}

func runApp(config: Config) -> Never {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate(config: config)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
    exit(0)
}
