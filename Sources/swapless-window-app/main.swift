// swapless-window-app: the rig's test app for quit on last window close (spec v1-quit-on-close
// S6). The rig wraps it into one LSUIElement bundle per scenario. It never activates, and every
// window it creates sits 20,000 pt beyond the right edge of all displays. It never creates an
// NSPanel (owner, 2026-11-06: a floating panel once landed on a display). The self-guard orders
// every window out within ~200 ms if one ever touches a display, and writes a `guard` line.
//
//   swapless-window-app --mode <scenario> --ctl <fifo> --status <jsonl>
//
// Status lines (JSON): ready, windowOpened, windowClosed, shouldTerminate, willTerminate.
// Commands (FIFO lines): `close <n>` (performClose:, the ⌘W path), `open`, `exit`.
import AppKit
import Darwin

struct Args {
    var mode = "close-ax"
    var ctl = ""
    var status = ""
}

func parseArgs() -> Args {
    var a = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let k = it.next() {
        switch k {
        case "--mode": a.mode = it.next() ?? a.mode
        case "--ctl": a.ctl = it.next() ?? ""
        case "--status": a.status = it.next() ?? ""
        default: break
        }
    }
    return a
}

let args = parseArgs()
let launched = Date()

/// Appends one JSON line to the status file.
func status(_ event: String, _ extra: [String: Any] = [:]) {
    guard !args.status.isEmpty else { return }
    var d = extra
    d["event"] = event
    d["t"] = Date().timeIntervalSince1970
    d["pid"] = Int(getpid())
    guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) else { return }
    let fd = open(args.status, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { return }
    _ = (data + Data("\n".utf8)).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    close(fd)
}

/// Beyond the right edge of every display.
func offscreenOrigin(_ index: Int) -> NSPoint {
    let maxX = NSScreen.screens.map(\.frame.maxX).max() ?? 0
    return NSPoint(x: maxX + 20_000 + CGFloat(index) * 1_000, y: 0)
}

final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
}

/// 64 MiB, touched, so the footprint is measurable.
var ballast: UnsafeMutableRawPointer? = {
    let n = 64 << 20
    let p = malloc(n)
    if let p { memset(p, 0x5A, n) }
    return p
}()

@MainActor
final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var windows: [NSWindow] = []
    var extras: [NSWindow] = []
    var count = 0

    func makeWindow(_ size: NSSize = NSSize(width: 800, height: 600)) -> NSWindow {
        let w = OffscreenWindow(contentRect: NSRect(origin: offscreenOrigin(count), size: size),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                backing: .buffered, defer: false)
        count += 1
        w.isReleasedWhenClosed = false
        w.title = "swapless rig \(args.mode) \(count)"
        w.delegate = self
        w.setFrameOrigin(offscreenOrigin(count))
        return w
    }

    func show(_ w: NSWindow) {
        w.orderFrontRegardless()
        status("windowOpened", ["id": w.windowNumber, "frame": [w.frame.minX, w.frame.minY, w.frame.width, w.frame.height]])
        guardScreens()
    }

    // MARK: self-guard (owner, 2026-11-06)

    var guardTripped = false

    /// Any window of ours touching a display, by AppKit frame or by window-server bounds.
    func touchingDisplays() -> [String] {
        var hits: [String] = []
        let screens = NSScreen.screens.map(\.frame)
        for w in windows + extras where w.isVisible {
            if screens.contains(where: { $0.intersects(w.frame) }) { hits.append("\(w.windowNumber) frame \(w.frame)") }
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        let displays = ids.prefix(Int(n)).map { CGDisplayBounds($0) }
        let mine = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for d in mine where (d[kCGWindowOwnerPID as String] as? Int32) == getpid() {
            guard let b = d[kCGWindowBounds as String] as? [String: Double] else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if r.width > 0, r.height > 0, displays.contains(where: { $0.intersects(r) }) {
                hits.append("\(d[kCGWindowNumber as String] ?? "?") bounds \(r)")
            }
        }
        return hits
    }

    /// Orders every window out at once if one touches a display.
    func guardScreens() {
        let hits = touchingDisplays()
        guard !hits.isEmpty else { return }
        for w in windows + extras { w.orderOut(nil) }
        if !guardTripped {
            guardTripped = true
            status("guard", ["hits": hits])
        }
    }

    func startGuard() {
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated { delegate.guardScreens() }
        }
    }

    func open() {
        let w = makeWindow()
        windows.append(w)
        show(w)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        switch args.mode {
        case "windowless":
            break
        case "two-windows":
            open()
            open()
        case "helpers":
            open()
            // Notes-like helpers: created, ordered in once (off-screen) so the window server has
            // them, then ordered out, so they sit on no Space.
            let sizes = [NSSize(width: 500, height: 500)] + Array(repeating: NSSize(width: 1920, height: 30), count: 13)
            for s in sizes {
                let h = makeWindow(s)
                h.delegate = nil
                h.orderFrontRegardless()
                h.orderOut(nil)
                extras.append(h)
            }
        case "tabs":
            let a = makeWindow()
            a.tabbingMode = .preferred
            let b = makeWindow()
            b.tabbingMode = .preferred
            windows += [a, b]
            show(a)
            a.addTabbedWindow(b, ordered: .above)
            status("windowOpened", ["id": b.windowNumber, "frame": [b.frame.minX, b.frame.minY, b.frame.width, b.frame.height]])
        default:
            open()
        }
        startGuard()
        status("ready", ["mode": args.mode, "windows": windows.map(\.windowNumber), "extras": extras.map(\.windowNumber)])
        if args.mode == "young" {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                self.windows.first?.close()
            }
        }
        startControl()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if args.mode == "hide-on-close" {
            // Electron-style: hide, keep the window (and its Space).
            sender.orderOut(nil)
            status("windowClosed", ["id": sender.windowNumber, "hidden": true])
            return false
        }
        return true
    }

    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow else { return }
        status("windowClosed", ["id": w.windowNumber, "hidden": false])
        if args.mode == "swap" {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                self.open()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let refuse = args.mode == "refuse"
        status("shouldTerminate", ["answer": refuse ? "cancel" : "now"])
        return refuse ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ n: Notification) {
        status("willTerminate")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: control FIFO

    func startControl() {
        guard !args.ctl.isEmpty else { return }
        let path: String = args.ctl
        Thread.detachNewThread {
            // O_RDWR keeps the FIFO open when the rig's writer closes it.
            let fd = Darwin.open(path, O_RDWR)
            guard fd >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            var pending = ""
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { return }
                pending += String(decoding: buf[0..<n], as: UTF8.self)
                while let nl = pending.firstIndex(of: "\n") {
                    let line = String(pending[..<nl]).trimmingCharacters(in: .whitespaces)
                    pending = String(pending[pending.index(after: nl)...])
                    Task { @MainActor in controlCommand(line) }
                }
            }
        }
    }

    func command(_ line: String) {
        let parts = line.split(separator: " ")
        switch parts.first {
        case "close":
            let i = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            if i < windows.count { windows[i].performClose(nil) }
        case "open":
            open()
            guardScreens()
        case "exit":
            status("willTerminate", ["via": "exit"])
            exit(0)
        default:
            break
        }
    }
}

let app = NSApplication.shared
let delegate = Delegate()

@MainActor func controlCommand(_ line: String) { delegate.command(line) }
app.delegate = delegate
app.run()
