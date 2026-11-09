import Foundation

/// One AX window as the watcher read it (v1-quit-on-close S2).
public struct AXWin: Sendable, Equatable, Codable {
    /// From `_AXUIElementGetWindow`; 0 when it couldn't be read.
    public var id: UInt32
    public var role: String
    public var subrole: String?
    public var minimized: Bool

    public init(id: UInt32, role: String = "AXWindow", subrole: String? = "AXStandardWindow", minimized: Bool = false) {
        self.id = id
        self.role = role
        self.subrole = subrole
        self.minimized = minimized
    }
}

/// One CG window of the app, with its Spaces (`CGSCopySpacesForWindows`).
public struct CGWin: Sendable, Equatable, Codable {
    public var id: UInt32
    public var layer: Int
    public var spaces: [UInt64]

    public init(id: UInt32, layer: Int = 0, spaces: [UInt64] = []) {
        self.id = id
        self.layer = layer
        self.spaces = spaces
    }
}

/// Everything one decision reads about one app at one moment (T2).
public struct WindowReading: Sendable, Equatable, Codable {
    /// nil when AX failed or timed out.
    public var ax: [AXWin]?
    public var cg: [CGWin]
    /// Each display's current Space.
    public var visibleSpaces: Set<UInt64>

    public init(ax: [AXWin]?, cg: [CGWin], visibleSpaces: Set<UInt64>) {
        self.ax = ax
        self.cg = cg
        self.visibleSpaces = visibleSpaces
    }
}

/// The count T2 defines, with its parts.
public struct Verdict: Sendable, Equatable {
    public var alive: Int
    /// Windows counted through AX, (A).
    public var ax: Int
    /// Windows counted as alive on an invisible Space, (B).
    public var elsewhere: Int
    /// `ax-error` or `no-window-id`; when set, the app is never quit on this reading.
    public var error: String?

    public init(alive: Int, ax: Int, elsewhere: Int, error: String? = nil) {
        self.alive = alive
        self.ax = ax
        self.elsewhere = elsewhere
        self.error = error
    }
}

/// T2 and T3: how many windows the owner would say the app has, and which ones a close just
/// left behind.
public enum WindowVerdict {
    /// The only subroles that don't keep an app alive (inspectors, palettes).
    public static let floatingSubroles: Set<String> = ["AXFloatingWindow", "AXSystemFloatingWindow"]

    /// (A): role `AXWindow`, and minimized (any subrole) or not a floating panel.
    public static func countsInA(_ w: AXWin) -> Bool {
        guard w.role == "AXWindow" else { return false }
        if w.minimized { return true }
        return !floatingSubroles.contains(w.subrole ?? "")
    }

    public static func evaluate(_ r: WindowReading, closed: Set<UInt32>) -> Verdict {
        guard let ax = r.ax else { return Verdict(alive: 0, ax: 0, elsewhere: 0, error: "ax-error") }
        let a = ax.filter { countsInA($0) && !($0.id != 0 && closed.contains($0.id)) }
        if a.contains(where: { $0.id == 0 }) {
            return Verdict(alive: 0, ax: a.count, elsewhere: 0, error: "no-window-id")
        }
        let aIds = Set(a.map(\.id))
        let b = Set(r.cg.filter { w in
            w.layer == 0 && !w.spaces.isEmpty && r.visibleSpaces.isDisjoint(with: w.spaces)
                && !closed.contains(w.id) && !aIds.contains(w.id)
        }.map(\.id))
        return Verdict(alive: aIds.count + b.count, ax: aIds.count, elsewhere: b.count)
    }

    /// T3: layer-0 ids absent from AX that sit on no Space or on a visible Space. Nothing when
    /// AX couldn't be read.
    public static func closedMarks(_ r: WindowReading) -> Set<UInt32> {
        guard let ax = r.ax else { return [] }
        let axIds = Set(ax.map(\.id))
        return Set(r.cg.filter { w in
            w.layer == 0 && !axIds.contains(w.id)
                && (w.spaces.isEmpty || !r.visibleSpaces.isDisjoint(with: w.spaces))
        }.map(\.id))
    }

    /// The ids AX lists right now (their closed marks clear).
    public static func axIds(_ r: WindowReading) -> Set<UInt32> {
        Set((r.ax ?? []).map(\.id).filter { $0 != 0 })
    }

    /// The reading shows at least one (A) window: the app is armed.
    public static func arms(_ r: WindowReading) -> Bool {
        (r.ax ?? []).contains(where: countsInA)
    }
}
