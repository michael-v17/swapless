import Darwin
import Dispatch
import Foundation
import SwaplessCore

/// `--headless`: the same engine with no status item and no window, JSON lines on stdout (S6).
/// The main thread runs `CFRunLoopRun()` (which also services the main queue), so NSWorkspace
/// notifications and KVO reach the quit watcher (v1-quit-on-close T11).
func runHeadless(config: Config) -> Never {
    let sink = EventSink(jsonTypes: nil)
    let engine = Engine(config: config, sink: sink, labeler: Labeler(appNames: InfoPlistAppNameProvider()),
                        signalSender: LiveSignalSender(sink: sink))
    let watcher = WindowWatcher(engine: engine, sink: sink, dryRun: config.dryRun)
    watcher.start()
    engine.start()
    withExtendedLifetime(watcher) { CFRunLoopRun() }
    exit(0)
}

/// `--print-menu`: one sample, then the `MenuModel` as text. Never evaluates rules or acts,
/// takes no lock, never creates or writes the state dir.
func runPrintMenu(config: Config) -> Never {
    let sink = EventSink(jsonTypes: ["error"])
    // These modes never evaluate rules or act; the sender is never called.
    let engine = Engine(config: config, sink: sink, labeler: Labeler(appNames: InfoPlistAppNameProvider()),
                        signalSender: DryRunSignalSender(sink: sink))
    let r = engine.oneShot()
    var state = r.state
    state.dryRun = config.dryRun
    let items = MenuModel.build(MenuInput(state: state, runningApps: MenuController.runningApps()))
    print(MenuModel.text(items), terminator: "")
    exit(0)
}

/// `--dump-snapshot <file>`: one sanitized snapshot for test fixtures. Never writes args, env
/// or a full cwd; `$HOME` becomes `~`.
func runDumpSnapshot(config: Config, path: String) -> Never {
    let sink = EventSink(jsonTypes: ["error"])
    // These modes never evaluate rules or act; the sender is never called.
    let engine = Engine(config: config, sink: sink, labeler: Labeler(appNames: InfoPlistAppNameProvider()),
                        signalSender: DryRunSignalSender(sink: sink))
    let r = engine.oneShot()
    let json = SnapshotDump.encode(r.snapshot, home: realHome(),
                                   claudeRoots: Grouper.claudeRoots(r.groups))
    do {
        try Data((json.serialized + "\n").utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch {
        sink.error(where: "dump-snapshot", "can't write \(PathSanitizer.sanitize(path, home: realHome())): \(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}
