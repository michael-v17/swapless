import AppKit
import SwaplessCore

extension NSMenu {
    /// Updates the rows to `desired` in place (`MenuReconcile.plan`): only rows that went away
    /// are removed and new ones inserted, so a submenu open under a row that stays stays open.
    ///
    /// A row being inserted is first taken out of the menu that still holds it. `NSMenu`
    /// asserts that an item sits in one menu at a time (`NSInternalInconsistencyException`
    /// from `insertItem(_:at:)`/`addItem`), and a reused row can still sit in a stale menu:
    /// group rows are positional, so after the groups reorder a row gets a new submenu for its
    /// new group, while that group's cached member rows are still in its previous submenu
    /// until AppKit frees it. Found by the rig's offscreen draws (2026-11-05): AppKit logs the
    /// exception from a timer callback and carries on, so the fill just stopped half-way.
    func reconcile(to desired: [NSMenuItem]) {
        var byID: [ObjectIdentifier: NSMenuItem] = [:]
        for ni in items + desired { byID[ObjectIdentifier(ni)] = ni }
        switch MenuReconcile.plan(current: items.map(ObjectIdentifier.init), desired: desired.map(ObjectIdentifier.init)) {
        case .unchanged:
            return
        case .rebuild:
            removeAllItems()
            for ni in desired { adopt(ni, at: numberOfItems) }
        case .steps(let steps):
            for step in steps {
                switch step {
                case .remove(let id): if let ni = byID[id] { removeItem(ni) }
                case .insert(let id, let at): if let ni = byID[id] { adopt(ni, at: at) }
                }
            }
        }
    }

    private func adopt(_ ni: NSMenuItem, at index: Int) {
        if let holder = ni.menu {
            if holder === self { return }
            holder.removeItem(ni)
        }
        insertItem(ni, at: index)
    }
}
