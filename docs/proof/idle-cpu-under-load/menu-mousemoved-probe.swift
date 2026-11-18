import AppKit
// Probe: after a status-item menu opens and closes once, does the app keep receiving mouseMoved?
// Args: variant (control|toggle|popup|reattach) openAt(s)
let variant = CommandLine.arguments[1]
let openAt = Double(CommandLine.arguments[2])!
let countFrom = 22.0, countTo = 172.0
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let start = Date()
var moved = (nilWin: 0, win: 0), other = 0
_ = NSEvent.addLocalMonitorForEvents(matching: .any) { e in
    let t = Date().timeIntervalSince(start)
    if t >= countFrom && t < countTo {
        if e.type == .mouseMoved { if e.window == nil { moved.nilWin += 1 } else { moved.win += 1 } } else { other += 1 }
    }
    return e
}
final class D: NSObject, NSMenuDelegate {
    var item: NSStatusItem!
    var menu: NSMenu!
    func menuWillOpen(_ m: NSMenu) {
        let t = Timer(timeInterval: 1.0, repeats: false) { _ in m.cancelTracking() }
        RunLoop.main.add(t, forMode: .common)
    }
    func menuDidClose(_ m: NSMenu) {
        switch variant {
        case "toggle":
            for w in NSApp.windows { w.acceptsMouseMovedEvents = true; w.acceptsMouseMovedEvents = false }
        case "reattach":
            item.menu = nil
            DispatchQueue.main.async { self.item.menu = self.menu }
        default: break
        }
    }
    @objc func click(_ s: Any?) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: item.button!.bounds.height + 4), in: item.button)
    }
}
let d = D()
let menu = NSMenu()
menu.addItem(withTitle: "probe \(variant)", action: nil, keyEquivalent: "")
let sub = NSMenu(); sub.addItem(withTitle: "sub", action: nil, keyEquivalent: "")
let si = NSMenuItem(title: "submenu", action: nil, keyEquivalent: ""); si.submenu = sub; menu.addItem(si)
menu.delegate = d
let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
item.button?.title = "P-\(variant.prefix(3))"
d.item = item; d.menu = menu
if variant == "popup" { item.button?.target = d; item.button?.action = #selector(D.click(_:)) } else { item.menu = menu }
Timer.scheduledTimer(withTimeInterval: openAt, repeats: false) { _ in item.button?.performClick(nil) }
Timer.scheduledTimer(withTimeInterval: countTo + 1, repeats: false) { _ in
    print("\(variant): mouseMoved after close (150 s): window=nil \(moved.nilWin), window=set \(moved.win); other events \(other)")
    exit(0)
}
app.run()
