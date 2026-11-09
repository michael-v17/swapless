import AppKit
import SwaplessCore

/// The only `terminate()` in Swapless (spec v1-quit-on-close T6): the app's own Quit, the
/// normal ⌘Q path, so it may ask to save. Never a force quit. The watcher calls it on the main
/// thread, only after `QuitGate` said `.quit` at both the decide and the confirm read, and only
/// after it checked that the pid is still the same app (bundle id and launch date).
struct LiveQuitSender: QuitSending {
    func terminate(pid: Int32) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.terminate() ?? false
    }
}

/// `SWAPLESS_DRY_RUN=1`: the tracker never emits a terminate in dry runs; this sender exists
/// so a dry-run engine holds no live sender at all.
struct DryRunQuitSender: QuitSending {
    let sink: EventSink

    func terminate(pid: Int32) -> Bool {
        sink.log(.quit, "dry run: would ask pid \(pid) to quit")
        return false
    }
}

/// App names by bundle id, for the `Last quit` row once the app is gone.
struct LaunchServicesAppNames: AppNameByBundleId {
    func name(forBundleId bundleId: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
              let info = Bundle(url: url)?.infoDictionary else { return nil }
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let n = info[key] as? String, !n.isEmpty { return n }
        }
        return nil
    }
}
