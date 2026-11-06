import Testing
@testable import SwaplessCore

/// The submenu fix (owner, 2026-11-05): the 2 s refresh never closes an open submenu.
@Suite("Menu · in-place reconcile and refresh scope")
struct MenuReconcileTests {
    typealias Plan = MenuReconcile.Plan<String>

    func removed(_ p: Plan) -> [String] {
        guard case .steps(let steps) = p else { return [] }
        return steps.compactMap { if case .remove(let id) = $0 { id } else { nil } }
    }

    func check(_ current: [String], _ desired: [String], sourceLocation: SourceLocation = #_sourceLocation) -> Plan {
        let p = MenuReconcile.plan(current: current, desired: desired)
        #expect(MenuReconcile.apply(p, to: current, desired: desired) == desired, sourceLocation: sourceLocation)
        return p
    }

    @Test func sameRowsAreUnchanged() {
        // Titles change in place on the same NSMenuItems: the row list is the same.
        #expect(check(["h1", "h2", "g0", "g1", "quit"], ["h1", "h2", "g0", "g1", "quit"]) == .unchanged)
    }

    @Test func rowsThatStayAreNeverRemoved() {
        // A group appears in the middle, one disappears at the end, a Growing section appears.
        let p = check(["h1", "g0", "g1", "g2", "rules", "quit"], ["h1", "g0", "g1", "grow", "rules", "quit"])
        #expect(removed(p) == ["g2"])
        #expect(p == .steps([.remove("g2"), .insert("grow", at: 3)]))
        // A row with an open submenu (g0) survives inserts before and after it.
        let q = check(["g0", "g1"], ["new", "g0", "other", "g1", "tail"])
        #expect(removed(q).isEmpty)
        #expect(q == .steps([.insert("new", at: 0), .insert("other", at: 2), .insert("tail", at: 4)]))
    }

    @Test func emptyAndFull() {
        #expect(check([], ["a", "b"]) == .steps([.insert("a", at: 0), .insert("b", at: 1)]))
        #expect(check(["a", "b"], []) == .steps([.remove("a"), .remove("b")]))
    }

    @Test func reorderOfStayingRowsRebuilds() {
        #expect(check(["a", "b", "c"], ["b", "a", "c"]) == .rebuild)
    }

    @Test func refreshScopeWhileASubmenuIsOpen() {
        #expect(MenuReconcile.refreshScope(openSubmenus: 0) == .everything)
        #expect(MenuReconcile.refreshScope(openSubmenus: 1) == .openSubmenusOnly)
        #expect(MenuReconcile.refreshScope(openSubmenus: 2) == .openSubmenusOnly)
    }

    /// 1,000 seeded random cases where the staying rows keep their order (what positional
    /// slots give): never a rebuild, never a removed staying row, and the result is `desired`.
    @Test func randomOrderKeepingChanges() {
        var rng = SplitMix64(seed: 0x5EED_0005)
        for _ in 0..<1000 {
            var next = 0
            func fresh() -> String { next += 1; return "r\(next)" }
            let current = (0..<Int(rng.next() % 12)).map { _ in fresh() }
            var desired = current.filter { _ in rng.next() % 4 != 0 }   // drop ~25 %
            for _ in 0..<Int(rng.next() % 5) {                           // insert up to 4 new rows
                desired.insert(fresh(), at: Int(rng.next() % UInt64(desired.count + 1)))
            }
            let p = check(current, desired)
            #expect(p != .rebuild)
            let staying = Set(current).intersection(desired)
            #expect(Set(removed(p)).isDisjoint(with: staying))
            if current == desired { #expect(p == .unchanged) }
        }
    }
}
