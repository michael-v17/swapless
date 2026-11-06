import AppKit
import CSwaplessProc
import SwaplessCore

/// The real `NSMenu`: fixed slots updated in place while it is open, refreshed once at open and
/// once per engine publish (no timer of its own; v1-menu-today S2), group submenus built in
/// `menuNeedsUpdate` (with the compressed reads for their member rows, cached while open).
@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    let engine: Engine
    let stateDir: URL
    private(set) var state = EngineState()
    private var slots: [String: NSMenuItem] = [:]
    private(set) var isOpen = false
    /// `LoginItem.isEnabled`, read at open and after the toggle (never per refresh).
    private var loginEnabled = false
    /// Compressed bytes per pid, read as a group submenu opens, per open submenu.
    private var compressedCache: [ObjectIdentifier: [Int32: UInt64]] = [:]
    /// The rig's counters: `refresh()` calls that ran, and compressed-read batches (one per
    /// `menuNeedsUpdate` on a group submenu whose group exists).
    private(set) var refreshCount = 0
    private(set) var compressedReadBatches = 0
    /// Creates every new menu item (tests inject a counting subclass).
    var makeItem: () -> NSMenuItem = { NSMenuItem() }
    /// Submenus open right now (group submenus and nested ones), by identity.
    private var openSubmenus: [ObjectIdentifier: NSMenu] = [:]
    var openSubmenuCount: Int { openSubmenus.count }
    private var lastSeenDot = 0
    /// Called with true when the dot should show.
    var onDot: ((Bool) -> Void)?
    /// The rig's menu shows: called when the top-level menu opens and closes.
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var onSubmenuOpen: (() -> Void)?
    var onSubmenuClose: (() -> Void)?
    /// The rig's menu shows: the menu stays real, but no item acts (a stray key press from the
    /// owner while the rig's menu is open must not quit, toggle a rule or Open at login).
    var actionsDisabled = false

    init(engine: Engine, stateDir: URL) {
        self.engine = engine
        self.stateDir = stateDir
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    func update(_ s: EngineState) {
        state = s
        if isOpen { refresh() }
        onDot?(s.dotGeneration > lastSeenDot)
    }

    /// Rebuilds the top level from the current state, reusing items by slot.
    ///
    /// While a submenu is open, only the open group submenus' rows are updated, in place, and
    /// the top level is left alone: group rows sit in positional slots, so a rebuild after the
    /// groups reorder would hand the open submenu's row to another group and replace its
    /// submenu, closing it under the pointer (owner, 2026-11-05: never close an open submenu).
    func refresh() {
        refreshCount += 1
        if MenuReconcile.refreshScope(openSubmenus: openSubmenus.count) == .openSubmenusOnly {
            for sub in openSubmenus.values {
                if let key = sub.identifier?.rawValue {
                    fillGroupSubmenu(sub, groupKey: key, compressed: compressedCache[ObjectIdentifier(sub)] ?? [:])
                }
            }
            return
        }
        let items = MenuModel.build(MenuInput(state: state, loginEnabled: loginEnabled))
        apply(items, to: menu, prefix: "top:")
        // Forget submenu rows of groups that are no longer shown.
        let shown = Set(items.compactMap(\.groupKey))
        for k in slots.keys where k.hasPrefix("sub:") {
            let rest = k.dropFirst(4)
            if !shown.contains(where: { rest.hasPrefix($0 + ":") }) { slots.removeValue(forKey: k) }
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ m: NSMenu) {
        guard m === menu else {
            openSubmenus[ObjectIdentifier(m)] = m
            onSubmenuOpen?()
            return
        }
        isOpen = true
        lastSeenDot = state.dotGeneration
        onDot?(false)
        loginEnabled = LoginItem.isEnabled
        engine.setMenuOpen(true)
        refresh()
        onOpen?()
    }

    func menuDidClose(_ m: NSMenu) {
        guard m === menu else {
            compressedCache.removeValue(forKey: ObjectIdentifier(m))
            if openSubmenus.removeValue(forKey: ObjectIdentifier(m)) != nil { onSubmenuClose?() }
            return
        }
        openSubmenus.removeAll()
        compressedCache.removeAll()
        isOpen = false
        engine.setMenuOpen(false)
        onClose?()
    }

    /// A group submenu is about to open: read its members' compressed memory now (never per
    /// sweep), cache it for this open, and fill it.
    func menuNeedsUpdate(_ m: NSMenu) {
        guard m !== menu, let key = m.identifier?.rawValue else { return }
        var compressed: [Int32: UInt64] = [:]
        if let s = state.snapshot, let g = state.groups.first(where: { $0.key == key }) {
            compressedReadBatches += 1
            compressed = Self.readCompressed(g, in: s)
        }
        compressedCache[ObjectIdentifier(m)] = compressed
        fillGroupSubmenu(m, groupKey: key, compressed: compressed)
    }

    /// Group submenus: no key equivalents, so AppKit's key-equivalent search never populates
    /// them (and never reads compressed memory). Other menus: the matching enabled item's
    /// target and action (AppKit expects both set when this returns true), so ⌘Q keeps working.
    func menuHasKeyEquivalent(_ m: NSMenu, for event: NSEvent,
                              target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                              action: UnsafeMutablePointer<Selector?>) -> Bool {
        if m.identifier != nil { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else { return false }
        for ni in m.items where ni.isEnabled && !ni.keyEquivalent.isEmpty {
            let need = ni.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift])
            if ni.keyEquivalent.lowercased() == chars && need == mods {
                target.pointee = ni.target
                action.pointee = ni.action
                return true
            }
        }
        return false
    }

    /// Compressed bytes of a group's top members (readable ones only).
    static func readCompressed(_ g: ProcessGroup, in s: Snapshot) -> [Int32: UInt64] {
        var compressed: [Int32: UInt64] = [:]
        for i in g.members.prefix(MenuModel.topMembers) where s.entries[i].readable {
            var c: UInt64 = 0
            if sw_task_compressed(s.entries[i].pid, &c) == 0 { compressed[s.entries[i].pid] = c }
        }
        return compressed
    }

    /// Member rows of one group, with the given compressed values (a member new since the
    /// submenu opened has none).
    func fillGroupSubmenu(_ m: NSMenu, groupKey: String, compressed: [Int32: UInt64]) {
        guard let s = state.snapshot, let g = state.groups.first(where: { $0.key == groupKey }) else {
            apply([MenuItem(slot: "gone", title: "Gone")], to: m, prefix: "sub:\(groupKey):")
            return
        }
        apply(MenuModel.memberRows(g, in: s, compressed: compressed), to: m, prefix: "sub:\(groupKey):")
    }

    /// The rig paths (offscreen draws, fills): stand in for an open, so they read fresh values
    /// every call, and don't count as a batch.
    private func fillGroupSubmenuFresh(_ m: NSMenu, groupKey: String) {
        var compressed: [Int32: UInt64] = [:]
        if let s = state.snapshot, let g = state.groups.first(where: { $0.key == groupKey }) {
            compressed = Self.readCompressed(g, in: s)
        }
        fillGroupSubmenu(m, groupKey: groupKey, compressed: compressed)
    }

    // MARK: - Applying the model

    func apply(_ items: [MenuItem], to target: NSMenu, prefix: String) {
        var desired: [NSMenuItem] = []
        for it in items {
            let key = prefix + it.slot
            let ni: NSMenuItem
            if it.isSeparator {
                ni = slots[key] ?? NSMenuItem.separator()
            } else {
                ni = slots[key] ?? makeItem()
                ni.update(from: it, target: self, action: #selector(performMenuAction(_:)))
                if let gk = it.groupKey {
                    // A closed group submenu is not refilled here: `menuNeedsUpdate` fills it
                    // every time it is about to open.
                    if ni.submenu?.identifier?.rawValue != gk {
                        let sub = NSMenu(title: it.title)
                        sub.identifier = NSUserInterfaceItemIdentifier(gk)
                        sub.delegate = self
                        sub.autoenablesItems = false
                        ni.submenu = sub
                    }
                } else if let children = it.children {
                    if let sub = ni.submenu {
                        apply(children, to: sub, prefix: key + ":")
                    } else {
                        let sub = NSMenu(title: it.title)
                        sub.autoenablesItems = false
                        sub.delegate = self   // tracked as an open submenu
                        apply(children, to: sub, prefix: key + ":")
                        ni.submenu = sub
                    }
                } else if ni.submenu != nil {
                    ni.submenu = nil
                }
            }
            slots[key] = ni
            desired.append(ni)
        }
        if target.items != desired { target.reconcile(to: desired) }
        // Forget slots under this prefix that are no longer shown.
        let live = Set(items.map { prefix + $0.slot })
        for k in slots.keys where k.hasPrefix(prefix) && !live.contains(k) && !isNested(k, under: live) {
            slots.removeValue(forKey: k)
        }
    }

    private func isNested(_ key: String, under live: Set<String>) -> Bool {
        live.contains { key.hasPrefix($0 + ":") }
    }

    // MARK: - Actions

    @objc func performMenuAction(_ sender: NSMenuItem) {
        guard !actionsDisabled, let box = sender.representedObject as? ActionBox else { return }
        switch box.action {
        case .toggleRule(let id):
            let enabled = state.rules.validRules.first { $0.id == id }?.enabled ?? false
            engine.setRuleEnabled(id, enabled: !enabled)
        case .resumeRule(let id):
            engine.resumeRule(id)
        case .restoreRules:
            engine.restoreDefaultRules()
        case .openRules:
            NSWorkspace.shared.open(RulesFile.url(in: stateDir))
        case .toggleLogin:
            LoginItem.toggle()
            loginEnabled = LoginItem.isEnabled
            refresh()
        case .quit:
            engine.requestQuit()
        }
    }

    /// The rig's offscreen menu test (owner rule, 2026-11-05: nothing on screen). Rebuilds the
    /// real menu, fills every group submenu, then draws every row of the menu and its submenus
    /// with AppKit's own menu-item cell into layer-backed views of a borderless window that is
    /// **never ordered on screen** (no `orderFront`, no status item), forces it to display, and
    /// releases it, like one show and close of the menu. Drawing into CoreAnimation backing
    /// stores is what leaves the framework memory the on-screen menu leaves (the ColorSync
    /// tables); a plain bitmap doesn't (docs/research/2026-11-05-menu-footprint.md).
    /// Returns the rows drawn (counted inside `draw(_:)`) and whether the window was ever visible.
    func drawOffscreen() -> (rows: Int, visible: Bool) {
        refresh()
        var menus: [NSMenu] = []
        func fill(_ m: NSMenu) {
            menus.append(m)
            for ni in m.items {
                guard let sub = ni.submenu else { continue }
                if let key = sub.identifier?.rawValue { fillGroupSubmenuFresh(sub, groupKey: key) }
                fill(sub)
            }
        }
        fill(menu)
        let width: CGFloat = 420
        let rowHeight: CGFloat = 22
        let height = CGFloat(menus.reduce(0) { $0 + max(1, $1.numberOfItems) }) * rowHeight
        var rows = 0
        var visible = false
        autoreleasepool {
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                               styleMask: [.borderless], backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            content.wantsLayer = true
            var top = height
            var views: [MenuRowsView] = []
            for m in menus {
                let h = CGFloat(max(1, m.numberOfItems)) * rowHeight
                top -= h
                let v = MenuRowsView(frame: NSRect(x: 0, y: top, width: width, height: h), items: m.items, rowHeight: rowHeight)
                v.wantsLayer = true
                content.addSubview(v)
                views.append(v)
            }
            win.contentView = content
            // A window that isn't on screen doesn't draw its layer-backed views on `display()`:
            // ask each layer to draw now (into its CoreAnimation backing store).
            win.display()
            for v in views {
                v.layer?.setNeedsDisplay()
                v.layer?.displayIfNeeded()
            }
            visible = win.isVisible
            rows = views.reduce(0) { $0 + $1.rowsDrawn }
            win.contentView = nil
            win.close()
        }
        return (rows, visible)
    }

    /// The rig's offscreen menu-open test (`SWAPLESS_RIG_MENU_OPEN`), on a menu that is never
    /// shown: open it through the delegate, "open" group submenus 0, 1, 2 at +5, +20, +35 s
    /// (each looked up at that moment from the menu's current items, since a reorder may have
    /// replaced it) and close each 10 s later, then close the menu at +`seconds`. Every delay is
    /// a `.common`-mode timer. `done` gets the number of submenus actually opened.
    func simulateOpen(seconds: Double, done: @escaping @MainActor (Int) -> Void) {
        func after(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
            let t = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { body() } }
            RunLoop.main.add(t, forMode: .common)
        }
        var opened = 0
        menuWillOpen(menu)
        for (i, at) in [5.0, 20.0, 35.0].enumerated() where at + 10 < seconds {
            after(at) { [weak self] in
                guard let self, self.isOpen else { return }
                let groupRows = self.menu.items.filter { $0.submenu?.identifier != nil }
                guard i < groupRows.count, let sub = groupRows[i].submenu else { return }
                self.menuNeedsUpdate(sub)
                self.menuWillOpen(sub)
                opened += 1
                after(10) { [weak self] in self?.menuDidClose(sub) }
            }
        }
        after(seconds) { [weak self] in
            guard let self else { return }
            self.menuDidClose(self.menu)
            done(opened)
        }
    }

    /// The rig's peak test: fills every slot and every group submenu (with the compressed
    /// reads), without showing anything.
    func fillEverything() {
        refresh()
        for ni in menu.items {
            if let sub = ni.submenu, let key = sub.identifier?.rawValue {
                fillGroupSubmenuFresh(sub, groupKey: key)
            }
        }
        Icons.render(Icons.plain())
        Icons.render(Icons.dot())
    }
}

/// One menu's rows, drawn with AppKit's menu-item cell (the rig's offscreen menu test).
final class MenuRowsView: NSView {
    let items: [NSMenuItem]
    let rowHeight: CGFloat
    private let cell = NSMenuItemCell()
    private(set) var rowsDrawn = 0

    init(frame: NSRect, items: [NSMenuItem], rowHeight: CGFloat) {
        self.items = items
        self.rowHeight = rowHeight
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        for (i, ni) in items.enumerated() {
            cell.menuItem = ni
            cell.draw(withFrame: NSRect(x: 0, y: CGFloat(i) * rowHeight, width: bounds.width, height: rowHeight), in: self)
            rowsDrawn += 1
        }
    }
}

final class ActionBox: NSObject {
    let action: MenuAction
    init(_ a: MenuAction) { action = a }
}
