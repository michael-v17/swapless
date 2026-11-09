// Quit-on-last-window probe (2026-11-06). Read-only: it never presses, closes or quits
// anything, and it shows no UI (activation policy .prohibited).
//   winprobe snapshot <bundle-id|all>
//   winprobe watch <bundle-id> <seconds>    (hard deadline; exits 2 on timeout)
import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ e: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

typealias CGSCopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
typealias CGSMainConnectionIDFn = @convention(c) () -> Int32
let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
let cgsSpaces = dlsym(sky, "CGSCopySpacesForWindows").map { unsafeBitCast($0, to: CGSCopySpacesForWindowsFn.self) }
let cgsConn = dlsym(sky, "CGSMainConnectionID").map { unsafeBitCast($0, to: CGSMainConnectionIDFn.self) }
typealias CGSCopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
let cgsDisplays = dlsym(sky, "CGSCopyManagedDisplaySpaces").map { unsafeBitCast($0, to: CGSCopyManagedDisplaySpacesFn.self) }
func visibleSpaces() -> String {
    guard let f = cgsDisplays, let c = cgsConn, let arr = f(c())?.takeRetainedValue() as? [[String: Any]] else { return "n/a" }
    return arr.compactMap { d in ((d["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int).map(String.init) }.joined(separator: ",")
}

let t0 = Date()
func ts() -> String { String(format: "%7.3f", Date().timeIntervalSince(t0)) }

func attr<T>(_ e: AXUIElement, _ a: String) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success else { return nil }
    return v as? T
}

func spaces(_ wid: CGWindowID) -> String {
    guard let f = cgsSpaces, let c = cgsConn else { return "n/a" }
    guard let arr = f(c(), 7, [NSNumber(value: wid)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return "nil" }
    return arr.isEmpty ? "none" : arr.map { "\($0)" }.joined(separator: ",")
}

struct AXW { var id: CGWindowID; var role: String; var sub: String; var min: Bool; var size: CGSize; var hasTitle: Bool; var hasClose: Bool }

func axWindows(_ pid: pid_t) -> [AXW]? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.3)
    guard let ws: [AXUIElement] = attr(app, kAXWindowsAttribute) else { return nil }
    return ws.map { w in
        var id: CGWindowID = 0
        _ = _AXUIElementGetWindow(w, &id)
        var size = CGSize.zero
        if let v: AXValue = attr(w, kAXSizeAttribute) { AXValueGetValue(v, .cgSize, &size) }
        let title: String? = attr(w, kAXTitleAttribute)
        let close: AXUIElement? = attr(w, kAXCloseButtonAttribute)
        return AXW(id: id, role: attr(w, kAXRoleAttribute) ?? "?", sub: attr(w, kAXSubroleAttribute) ?? "-",
                   min: (attr(w, kAXMinimizedAttribute) as Bool?) ?? false, size: size,
                   hasTitle: !(title ?? "").isEmpty, hasClose: close != nil)
    }
}

struct CGW { var id: CGWindowID; var layer: Int; var onscreen: Bool; var alpha: Double; var w: Int; var h: Int; var spaces: String }

func cgWindows(_ pid: pid_t) -> [CGW] {
    let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    return all.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }.map { d in
        let b = d[kCGWindowBounds as String] as? [String: Double] ?? [:]
        let id = CGWindowID(d[kCGWindowNumber as String] as? Int ?? 0)
        return CGW(id: id, layer: d[kCGWindowLayer as String] as? Int ?? -1,
                   onscreen: d[kCGWindowIsOnscreen as String] as? Bool ?? false,
                   alpha: d[kCGWindowAlpha as String] as? Double ?? -1,
                   w: Int(b["Width"] ?? 0), h: Int(b["Height"] ?? 0), spaces: spaces(id))
    }
}

func describe(_ app: NSRunningApplication) -> String {
    let pid = app.processIdentifier
    var out = "APP \(app.bundleIdentifier ?? "?") pid=\(pid) policy=\(app.activationPolicy.rawValue) hidden=\(app.isHidden) active=\(app.isActive) finished=\(app.isFinishedLaunching)\n"
    if let ax = axWindows(pid) {
        out += "  AX windows: \(ax.count)\n"
        for w in ax { out += "    ax id=\(w.id) \(w.role)/\(w.sub) min=\(w.min) size=\(Int(w.size.width))x\(Int(w.size.height)) title=\(w.hasTitle) closeBtn=\(w.hasClose) spaces=\(spaces(w.id))\n" }
    } else { out += "  AX windows: unreadable\n" }
    let cg = cgWindows(pid)
    let l0 = cg.filter { $0.layer == 0 }
    out += "  CG windows: \(cg.count) (layer0: \(l0.count), layer0 onscreen: \(l0.filter(\.onscreen).count), layer0 with a space: \(l0.filter { $0.spaces != "none" && $0.spaces != "nil" }.count))\n"
    for w in cg { out += "    cg id=\(w.id) layer=\(w.layer) onscreen=\(w.onscreen) alpha=\(w.alpha) \(w.w)x\(w.h) spaces=\(w.spaces)\n" }
    return out
}

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: winprobe snapshot <bundle|all> | watch <bundle> <seconds>"); exit(64) }
print("AXIsProcessTrusted=\(AXIsProcessTrusted()) skylight=\(cgsSpaces != nil) visibleSpaces=\(visibleSpaces())")
NSApplication.shared.setActivationPolicy(.prohibited)

if args[1] == "snapshot" {
    let apps = NSWorkspace.shared.runningApplications.filter {
        args[2] == "all" ? $0.activationPolicy == .regular : $0.bundleIdentifier == args[2]
    }
    if apps.isEmpty { print("not running: \(args[2])"); exit(3) }
    for a in apps { print(describe(a)) }
    exit(0)
}

guard args[1] == "watch", args.count >= 4, let secs = Double(args[3]) else { exit(64) }
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == args[2] }) else {
    print("not running: \(args[2])"); exit(3)
}
let pid = app.processIdentifier
print("[\(ts())] start\n" + describe(app))

var observer: AXObserver?
let cb: AXObserverCallback = { obs, el, note, _ in
    var id: CGWindowID = 0
    _ = _AXUIElementGetWindow(el, &id)
    print("[\(ts())] AX \(note as String) wid=\(id)")
    if (note as String) == kAXWindowCreatedNotification {
        print("  observe new window destroyed: \(AXObserverAddNotification(obs, el, kAXUIElementDestroyedNotification as CFString, nil).rawValue)")
    }
    fflush(stdout)
}
if AXObserverCreate(pid, cb, &observer) == .success, let observer {
    let axApp = AXUIElementCreateApplication(pid)
    let notes = [kAXUIElementDestroyedNotification, kAXWindowCreatedNotification, kAXMainWindowChangedNotification,
                 kAXFocusedWindowChangedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                 kAXApplicationHiddenNotification, kAXApplicationShownNotification]
    for n in notes { print("  observe \(n): \(AXObserverAddNotification(observer, axApp, n as CFString, nil).rawValue)") }
    // Window-level destroyed notifications need registering on each window element.
    if let ws: [AXUIElement] = attr(axApp, kAXWindowsAttribute) {
        for w in ws { print("  observe window destroyed: \(AXObserverAddNotification(observer, w, kAXUIElementDestroyedNotification as CFString, nil).rawValue)") }
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
} else { print("AXObserverCreate failed") }

NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { e in
    let p = NSEvent.mouseLocation
    print("[\(ts())] mouse \(e.type == .leftMouseDown ? "down" : "up") at \(Int(p.x)),\(Int(p.y)) wid=\(e.windowNumber)")
}
NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { e in
    if e.modifierFlags.contains(.command) { print("[\(ts())] key cmd+\(e.charactersIgnoringModifiers ?? "?")") }
}

var last = ""
Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
    if app.isTerminated { print("[\(ts())] app terminated"); exit(0) }
    let axList = axWindows(pid)
    let ax = axList.map { $0.map { "\($0.id)\($0.min ? "m" : "")\($0.sub == "AXStandardWindow" ? "" : "(\($0.sub))")" }.joined(separator: ",") } ?? "unreadable"
    let cgList = cgWindows(pid).filter { $0.layer == 0 }
    let cg = cgList.filter { $0.spaces != "none" }.map { "\($0.id)\($0.onscreen ? "+" : "-")[\($0.spaces)]" }.joined(separator: ",")
    // Candidate rule: alive = AX standard window (minimized included) ∪ layer-0 window whose
    // Spaces are all currently invisible.
    let vis = Set(visibleSpaces().split(separator: ",").map(String.init))
    let axAlive = (axList ?? []).filter { $0.sub == "AXStandardWindow" }.count
    let elsewhere = cgList.filter { w in
        let sp = w.spaces.split(separator: ",").map(String.init)
        return !sp.isEmpty && w.spaces != "none" && w.spaces != "nil" && vis.isDisjoint(with: sp)
    }.count
    let verdict = axList == nil ? "UNREADABLE" : (axAlive + elsewhere == 0 ? "WOULD-QUIT" : "alive(ax=\(axAlive),elsewhere=\(elsewhere))")
    let line = "\(verdict) AX=[\(ax)] CG0spaced=[\(cg)] cg0total=\(cgList.count) hidden=\(app.isHidden) visibleSpaces=\(visibleSpaces())"
    if line != last { print("[\(ts())] \(line)"); last = line; fflush(stdout) }
}
DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
    print("[\(ts())] DEADLINE \(secs)s reached\n" + describe(app)); exit(2)
}
NSApplication.shared.run()
