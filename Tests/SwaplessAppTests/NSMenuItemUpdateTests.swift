import AppKit
import Testing
@testable import Swapless
@testable import SwaplessCore

/// v1-menu-today S2: an item's properties are written only when they change. Counted on a
/// subclass's setters (deterministic; doesn't depend on AppKit notifications), on menus that
/// are never shown.
@MainActor
@Suite("Menu · write only what changed (AppKit)")
struct NSMenuItemUpdateTests {
    /// Counts calls to the setters an update may make.
    final class CountingItem: NSMenuItem {
        var calls: [String: Int] = [:]
        var total: Int { calls.values.reduce(0, +) }
        private func hit(_ k: String) { calls[k, default: 0] += 1 }
        override var title: String { get { super.title } set { hit("title"); super.title = newValue } }
        override var isEnabled: Bool { get { super.isEnabled } set { hit("isEnabled"); super.isEnabled = newValue } }
        override var state: NSControl.StateValue { get { super.state } set { hit("state"); super.state = newValue } }
        override var keyEquivalent: String { get { super.keyEquivalent } set { hit("keyEquivalent"); super.keyEquivalent = newValue } }
        override var target: AnyObject? { get { super.target } set { hit("target"); super.target = newValue } }
        override var action: Selector? { get { super.action } set { hit("action"); super.action = newValue } }
        override var representedObject: Any? { get { super.representedObject } set { hit("representedObject"); super.representedObject = newValue } }
        override var submenu: NSMenu? { get { super.submenu } set { hit("submenu"); super.submenu = newValue } }
    }

    final class Target: NSObject {
        @objc func act(_ sender: Any?) {}
    }

    let target = Target()
    let sel = #selector(Target.act(_:))

    @Test func identicalUpdateWritesNothing() {
        let ni = CountingItem()
        let it = MenuItem(slot: "quit", title: "Quit Swapless", enabled: true, action: .quit, keyEquivalent: "q")
        #expect(ni.update(from: it, target: target, action: sel))
        ni.calls = [:]
        #expect(!ni.update(from: it, target: target, action: sel))
        #expect(ni.total == 0)
    }

    @Test func changedTitleWritesOnlyTheTitle() {
        let ni = CountingItem()
        let it = MenuItem(slot: "footer", title: "Swapless 0.11 % CPU idle · 33 MB")
        ni.update(from: it, target: target, action: sel)
        ni.calls = [:]
        var it2 = it
        it2.title = "Swapless 0.12 % CPU idle · 33 MB"
        #expect(ni.update(from: it2, target: target, action: sel))
        #expect(ni.calls == ["title": 1])
    }

    @Test func unchangedActionKeepsTheSameBox() throws {
        let ni = CountingItem()
        let it = MenuItem(slot: "login", title: "Open at login", enabled: true, checked: false, action: .toggleLogin)
        ni.update(from: it, target: target, action: sel)
        let box = try #require(ni.representedObject as? ActionBox)
        var it2 = it
        it2.checked = true
        ni.calls = [:]
        #expect(ni.update(from: it2, target: target, action: sel))
        #expect(ni.calls == ["state": 1])
        let after = ni.representedObject as? ActionBox
        #expect(after === box)
    }

    @Test func actionChangesAndRemovalAreWritten() {
        let ni = CountingItem()
        ni.update(from: MenuItem(slot: "r", title: "Resume", enabled: true, action: .resumeRule("a")), target: target, action: sel)
        ni.calls = [:]
        #expect(ni.update(from: MenuItem(slot: "r", title: "Resume", enabled: true, action: .resumeRule("b")),
                          target: target, action: sel))
        #expect((ni.representedObject as? ActionBox)?.action == .resumeRule("b"))
        #expect(ni.calls["title"] == nil)
        ni.calls = [:]
        #expect(ni.update(from: MenuItem(slot: "r", title: "Resume", enabled: true), target: target, action: sel))
        let cleared = ni.representedObject == nil && ni.action == nil && ni.target == nil
        #expect(cleared)
    }

    func controller() throws -> MenuController {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("swapless-apptests-\(UUID().uuidString)")
        let cfg = try Config.load(env: ["SWAPLESS_STATE_DIR": dir.path],
                                  defaultStateDir: dir.appendingPathComponent("default"),
                                  flavour: Flavour(isRelease: false, mode: .headless)).get()
        struct NoSignals: SignalSender {
            func sigterm(pid: Int32, target: RestartTarget) -> SignalResult { .refused("test") }
        }
        let engine = Engine(config: cfg, sink: EventSink(jsonTypes: []), labeler: Labeler(), signalSender: NoSignals())
        let mc = MenuController(engine: engine, stateDir: dir)
        mc.makeItem = { CountingItem() }
        return mc
    }

    /// The Today row and `+ N system processes`: an existing submenu is reused untouched.
    @Test func reapplyingAChildrenRowMakesNoSubmenuWrites() throws {
        let mc = try controller()
        let rows = [
            MenuItem(slot: "today", title: "Today: 1 restart", enabled: true, children: [
                MenuItem(slot: "today.day.0", title: "Today: 1 restart"),
                MenuItem.separator("today.sep"),
                MenuItem(slot: "today.total", title: "7 days: 1 restart"),
            ]),
        ]
        let m = NSMenu()
        mc.apply(rows, to: m, prefix: "top:")
        let ni = try #require(m.items.first as? CountingItem)
        #expect(ni.calls["submenu"] == 1)
        let sub = ni.submenu
        let child = try #require(sub?.items.first as? CountingItem)
        ni.calls = [:]
        child.calls = [:]
        mc.apply(rows, to: m, prefix: "top:")
        #expect(ni.calls["submenu"] == nil)
        #expect(ni.total == 0)
        #expect(child.total == 0)
        #expect(ni.submenu === sub)
        // A changed child is applied in place, still without a submenu write.
        var rows2 = rows
        rows2[0].children![0].title = "Today: 2 restarts"
        mc.apply(rows2, to: m, prefix: "top:")
        #expect(ni.calls["submenu"] == nil)
        #expect(child.calls == ["title": 1])
    }
}
