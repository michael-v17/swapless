import AppKit
import SwaplessCore

/// App names backed by `NSRunningApplication` (spec § E), only for processes inside an `.app`
/// bundle so the labels agree with the headless Info.plist provider. Cached by pid + path.
final class RunningAppNameProvider: AppNameProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: String?] = [:]
    private let fallback = InfoPlistAppNameProvider()

    func appName(pid: Int32, path: String) -> String? {
        guard Labeler.outermostAppBundle(path) != nil else { return nil }
        let key = "\(pid):\(path)"
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        var name: String?
        if let app = NSRunningApplication(processIdentifier: pid), let url = app.bundleURL,
           url.pathExtension == "app", let n = app.localizedName, !n.isEmpty {
            name = n
        } else {
            name = fallback.appName(pid: pid, path: path)
        }
        lock.lock()
        if cache.count > 4096 { cache.removeAll(keepingCapacity: true) }
        cache[key] = name
        lock.unlock()
        return name
    }
}

/// The injected wake signal (`NSWorkspace.didWakeNotification` lives here, not in the core).
@MainActor
final class WakeObserver {
    private var token: NSObjectProtocol?

    init(onWake: @escaping @Sendable () -> Void) {
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in onWake() }
    }
}
