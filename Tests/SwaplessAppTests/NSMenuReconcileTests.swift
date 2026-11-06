import AppKit
import Testing
@testable import Swapless

/// The AppKit side of the submenu fix, on real `NSMenu`s (never shown: no status item, no
/// popUp). The pure plan is in SwaplessCoreTests' `MenuReconcileTests`.
@MainActor
@Suite("Menu · NSMenu reconcile (AppKit)")
struct NSMenuReconcileTests {
    func rows(_ titles: String...) -> [NSMenuItem] {
        titles.map { NSMenuItem(title: $0, action: nil, keyEquivalent: "") }
    }

    /// Counts `didRemoveItem` notifications of one menu.
    final class Removals: @unchecked Sendable {
        var count = 0
        var token: NSObjectProtocol?
        init(_ m: NSMenu) {
            token = NotificationCenter.default.addObserver(forName: NSMenu.didRemoveItemNotification, object: m,
                                                           queue: nil) { [unowned self] _ in self.count += 1 }
        }
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }

    /// The rig's offscreen draws (2026-11-05): the groups reorder, a positional group row gets
    /// a new submenu for its new group, and that group's cached member rows are still in its
    /// previous submenu. Before the fix, `insertItem` raised NSInternalInconsistencyException.
    @Test func aRowStillInAStaleSubmenuMovesToTheNewOne() {
        let row = NSMenuItem(title: "Safari", action: nil, keyEquivalent: "")
        let members = rows("Safari", "Safari Web Content")
        let stale = NSMenu()
        for m in members { stale.addItem(m) }
        row.submenu = stale
        let fresh = NSMenu()
        row.submenu = fresh          // `stale` is still alive (held here, as by an autorelease pool)
        fresh.reconcile(to: members)
        #expect(fresh.items == members)
        #expect(stale.items.isEmpty)
        #expect(members.allSatisfy { $0.menu === fresh })
    }

    @Test func aRebuildMovesRowsToo() {
        let (a, b, c) = (rows("a")[0], rows("b")[0], rows("c")[0])
        let target = NSMenu()
        target.addItem(a)
        target.addItem(b)
        let other = NSMenu()
        other.addItem(c)
        target.reconcile(to: [b, a, c])   // the staying rows reorder: a rebuild
        #expect(target.items == [b, a, c])
        #expect(other.items.isEmpty)
    }

    /// The row whose submenu is open is never removed, so its submenu stays open; only the
    /// row that went away is removed.
    @Test func rowsThatStayAreNeverRemoved() {
        let (header, g0, g1, g2) = (rows("header")[0], rows("g0")[0], rows("g1")[0], rows("g2")[0])
        let openSubmenu = NSMenu()
        g0.submenu = openSubmenu
        let m = NSMenu()
        for r in [header, g0, g1, g2] { m.addItem(r) }
        let removals = Removals(m)
        let growing = rows("Growing")[0]
        m.reconcile(to: [header, growing, g0, g1])
        #expect(m.items == [header, growing, g0, g1])
        #expect(removals.count == 1)                      // g2 only
        #expect(g0.menu === m && g0.submenu === openSubmenu)
        m.reconcile(to: [header, growing, g0, g1])        // nothing changed: nothing removed
        #expect(removals.count == 1)
    }
}
