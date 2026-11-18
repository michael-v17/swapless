import AppKit
import Testing
@testable import Swapless

/// The 2026-11-17 idle-CPU fix: on menu close every window's `acceptsMouseMovedEvents` is
/// flipped and set back, which makes AppKit drop the app-wide mouse-moved subscription. Checked
/// on windows that are never ordered on screen.
@MainActor
@Suite("Menu · drop the mouse-moved subscription on close (AppKit)")
struct MouseMovedSubscriptionTests {
    /// Records every write to `acceptsMouseMovedEvents`.
    final class RecordingWindow: NSWindow {
        var writes: [Bool] = []
        override var acceptsMouseMovedEvents: Bool {
            get { super.acceptsMouseMovedEvents }
            set { writes.append(newValue); super.acceptsMouseMovedEvents = newValue }
        }
    }

    static func window(accepts: Bool) -> RecordingWindow {
        let w = RecordingWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                                styleMask: [.borderless], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.acceptsMouseMovedEvents = accepts
        w.writes.removeAll()
        return w
    }

    @Test func everyWindowIsFlippedAndKeepsItsValue() {
        _ = NSApplication.shared
        let off = Self.window(accepts: false)
        let on = Self.window(accepts: true)
        MenuController.dropMouseMovedSubscription()
        #expect(off.writes == [true, false])
        #expect(on.writes == [false, true])
        #expect(off.acceptsMouseMovedEvents == false)
        #expect(on.acceptsMouseMovedEvents == true)
        #expect(!off.isVisible && !on.isVisible)
    }
}
