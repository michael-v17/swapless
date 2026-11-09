import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// The private window APIs quit on close needs (spec v1-quit-on-close T8), looked up with
/// `dlsym` so a missing symbol never stops the app from loading. Checked once at start; any
/// failure makes the feature `unavailable`, and it never acts.
final class PrivateWindowAPI: @unchecked Sendable {
    typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    typealias SpacesFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    typealias ConnFn = @convention(c) () -> Int32
    typealias DisplaysFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private let getWindow: GetWindowFn?
    private let spacesFn: SpacesFn?
    private let connFn: ConnFn?
    private let displaysFn: DisplaysFn?
    /// nil when every symbol resolved and the display check passed.
    let unavailableReason: String?

    var available: Bool { unavailableReason == nil }

    init() {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        getWindow = dlsym(rtldDefault, "_AXUIElementGetWindow").map { unsafeBitCast($0, to: GetWindowFn.self) }
        let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        spacesFn = sky.flatMap { dlsym($0, "CGSCopySpacesForWindows") }.map { unsafeBitCast($0, to: SpacesFn.self) }
        connFn = sky.flatMap { dlsym($0, "CGSMainConnectionID") }.map { unsafeBitCast($0, to: ConnFn.self) }
        displaysFn = sky.flatMap { dlsym($0, "CGSCopyManagedDisplaySpaces") }.map { unsafeBitCast($0, to: DisplaysFn.self) }
        if getWindow == nil {
            unavailableReason = "_AXUIElementGetWindow"
        } else if sky == nil {
            unavailableReason = "SkyLight"
        } else if spacesFn == nil {
            unavailableReason = "CGSCopySpacesForWindows"
        } else if connFn == nil {
            unavailableReason = "CGSMainConnectionID"
        } else if displaysFn == nil {
            unavailableReason = "CGSCopyManagedDisplaySpaces"
        } else {
            unavailableReason = nil
        }
    }

    /// The T8 functional check: at least one display reports a current Space.
    func checkedReason() -> String? {
        if let r = unavailableReason { return r }
        return visibleSpaces().isEmpty ? "no display reports a current Space" : nil
    }

    /// The window id of an AX window; nil when it can't be read.
    func windowId(_ e: AXUIElement) -> UInt32? {
        guard let getWindow else { return nil }
        var id: CGWindowID = 0
        guard getWindow(e, &id) == .success, id != 0 else { return nil }
        return id
    }

    /// The Spaces a window sits on (empty: none, e.g. ordered out).
    func spaces(_ id: UInt32) -> [UInt64] {
        guard let spacesFn, let connFn else { return [] }
        let arr = spacesFn(connFn(), 7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber]
        return (arr ?? []).map(\.uint64Value)
    }

    /// Each display's current Space.
    func visibleSpaces() -> Set<UInt64> {
        guard let displaysFn, let connFn,
              let arr = displaysFn(connFn())?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return Set(arr.compactMap { d in
            ((d["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value
        })
    }
}
