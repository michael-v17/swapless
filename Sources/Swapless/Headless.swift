import Darwin
import Dispatch
import Foundation
import SwaplessCore

/// `--headless`: the same engine with no AppKit, JSON lines on stdout (S6).
func runHeadless(config: Config) -> Never {
    let sink = EventSink(jsonTypes: nil)
    let engine = Engine(config: config, sink: sink, labeler: Labeler(appNames: InfoPlistAppNameProvider()),
                        signalSender: LiveSignalSender(sink: sink))
    engine.start()
    dispatchMain()
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
    let items = MenuModel.build(MenuInput(state: state))
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
