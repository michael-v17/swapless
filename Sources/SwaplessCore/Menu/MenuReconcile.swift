/// How the open menu is updated in place by the 2 s refresh (the app applies the plan to its
/// `NSMenu`; this is the pure part). Owner, 2026-11-05: the refresh must never close an open
/// submenu.
/// - While any submenu is open, only the open submenus' rows are refreshed: group rows sit in
///   positional slots, so a top-level rebuild after the groups reorder would hand the open
///   submenu's row to another group and replace its submenu.
/// - Rows are reconciled, never rebuilt: only rows that went away are removed and new ones
///   inserted. A row that stays is never removed, so a submenu open under it stays open.
public enum MenuReconcile {
    public enum Step<ID: Hashable & Sendable>: Equatable, Sendable {
        case remove(ID)
        case insert(ID, at: Int)
    }

    public enum Plan<ID: Hashable & Sendable>: Equatable, Sendable {
        case unchanged
        /// Removes first, then inserts in ascending index order.
        case steps([Step<ID>])
        /// The rows that stay changed their order: remove everything and add `desired`.
        /// (Slots are positional, so the menu never asks for this.)
        case rebuild
    }

    public enum RefreshScope: Equatable, Sendable {
        case everything
        case openSubmenusOnly
    }

    public static func refreshScope(openSubmenus: Int) -> RefreshScope {
        openSubmenus > 0 ? .openSubmenusOnly : .everything
    }

    /// `current` and `desired` hold unique ids (one per menu row).
    public static func plan<ID: Hashable & Sendable>(current: [ID], desired: [ID]) -> Plan<ID> {
        if current == desired { return .unchanged }
        let keep = Set(desired)
        var steps: [Step<ID>] = current.filter { !keep.contains($0) }.map { .remove($0) }
        let staying = current.filter { keep.contains($0) }
        let present = Set(staying)
        guard staying == desired.filter({ present.contains($0) }) else { return .rebuild }
        var rows = staying
        for (i, id) in desired.enumerated() where i >= rows.count || rows[i] != id {
            steps.append(.insert(id, at: i))
            rows.insert(id, at: i)
        }
        return .steps(steps)
    }

    /// What applying `plan` to `current` gives (the app does the same to the `NSMenu`).
    public static func apply<ID: Hashable & Sendable>(_ plan: Plan<ID>, to current: [ID], desired: [ID]) -> [ID] {
        switch plan {
        case .unchanged:
            return current
        case .rebuild:
            return desired
        case .steps(let steps):
            var rows = current
            for step in steps {
                switch step {
                case .remove(let id): rows.removeAll { $0 == id }
                case .insert(let id, let at): rows.insert(id, at: at)
                }
            }
            return rows
        }
    }
}
