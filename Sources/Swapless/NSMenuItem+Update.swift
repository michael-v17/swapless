import AppKit
import SwaplessCore

extension NSMenuItem {
    /// v1-menu-today S2: writes only what changed. Every write to an item of an open menu can
    /// make AppKit lay out and redraw it again, so `title`, `isEnabled`, `state` and
    /// `keyEquivalent` are written only when each differs, and `target` / `action` /
    /// `representedObject` only when the row's `MenuAction` differs from the current
    /// `ActionBox`'s (or one is absent and the other isn't). Returns whether anything was written.
    @MainActor
    @discardableResult
    func update(from it: MenuItem, target: AnyObject?, action: Selector) -> Bool {
        var wrote = false
        if title != it.title {
            title = it.title
            wrote = true
        }
        if isEnabled != it.enabled {
            isEnabled = it.enabled
            wrote = true
        }
        let st: NSControl.StateValue = it.checked ? .on : .off
        if state != st {
            state = st
            wrote = true
        }
        let ke = it.keyEquivalent ?? ""
        if keyEquivalent != ke {
            keyEquivalent = ke
            wrote = true
        }
        let current = (representedObject as? ActionBox)?.action
        if current != it.action {
            if let a = it.action {
                self.target = target
                self.action = action
                representedObject = ActionBox(a)
            } else {
                self.target = nil
                self.action = nil
                representedObject = nil
            }
            wrote = true
        }
        return wrote
    }
}
