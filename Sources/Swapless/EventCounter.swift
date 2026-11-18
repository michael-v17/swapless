import AppKit
import SwaplessCore

/// The sensor for the 2026-11-17 idle-CPU regression: counts the events AppKit dispatches to
/// this app, by type, and logs one `events` line per 5 min in the `self` category. With the
/// menu closed it should read ~0; a steady `mouseMoved` count means AppKit has subscribed the
/// app to every mouse move again (see `MenuController.dropMouseMovedSubscription`).
/// The line never starts with `self cpuSeconds=`, so the rig and self-report.sh skip it.
@MainActor
final class EventCounter {
    private var counts: [UInt: Int] = [:]
    private var monitor: Any?
    private var timer: Timer?
    private let sink: EventSink
    static let window: TimeInterval = 300

    init(sink: EventSink) {
        self.sink = sink
        monitor = NSEvent.addLocalMonitorForEvents(matching: .any) { [weak self] e in
            MainActor.assumeIsolated { self?.counts[e.type.rawValue, default: 0] += 1 }
            return e
        }
        let t = Timer(timeInterval: Self.window, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func flush() {
        let total = counts.values.reduce(0, +)
        let parts = counts.sorted { $0.key < $1.key }.map { "\(Self.name($0.key))=\($0.value)" }
        sink.log(.`self`, "events window=\(Int(Self.window))s total=\(total) \(parts.joined(separator: " "))")
        counts.removeAll(keepingCapacity: true)
    }

    static func name(_ raw: UInt) -> String {
        switch NSEvent.EventType(rawValue: raw) {
        case .leftMouseDown?: return "leftDown"
        case .leftMouseUp?: return "leftUp"
        case .rightMouseDown?: return "rightDown"
        case .rightMouseUp?: return "rightUp"
        case .mouseMoved?: return "mouseMoved"
        case .leftMouseDragged?: return "leftDragged"
        case .mouseEntered?: return "mouseEntered"
        case .mouseExited?: return "mouseExited"
        case .keyDown?: return "keyDown"
        case .keyUp?: return "keyUp"
        case .flagsChanged?: return "flagsChanged"
        case .appKitDefined?: return "appKitDefined"
        case .systemDefined?: return "systemDefined"
        case .scrollWheel?: return "scrollWheel"
        default: return "type\(raw)"
        }
    }
}
