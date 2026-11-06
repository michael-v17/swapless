import Darwin
import Foundation
import SwaplessCore

// The only place that computes the real default state dir and the build flavour (§ C).

#if DEBUG
let isRelease = false
#else
let isRelease = true
#endif

/// The real home from the password database (never `$HOME`, which a caller can change).
func realHome() -> String {
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
        return String(cString: dir)
    }
    return NSHomeDirectory()
}

let defaultStateDir = URL(fileURLWithPath: realHome())
    .appendingPathComponent("Library/Application Support/Swapless")

struct Arguments {
    var mode: Flavour.Mode = .menuApp
    var duration: Double?
    var dumpPath: String?
}

func usageError(_ message: String) -> Never {
    let sink = EventSink(jsonTypes: nil)
    sink.error(where: "arguments", message)
    exit(2)
}

func parseArguments(_ argv: [String]) -> Arguments {
    var a = Arguments()
    var i = 1
    var modeSet = false
    func setMode(_ m: Flavour.Mode) {
        if modeSet && a.mode != m { usageError("only one of --headless, --print-menu, --dump-snapshot") }
        a.mode = m
        modeSet = true
    }
    while i < argv.count {
        let arg = argv[i]
        switch arg {
        case "--headless": setMode(.headless)
        case "--print-menu": setMode(.printMenu)
        case "--dump-snapshot":
            setMode(.dumpSnapshot)
            i += 1
            guard i < argv.count else { usageError("--dump-snapshot needs a file") }
            a.dumpPath = argv[i]
        case "--duration":
            i += 1
            guard i < argv.count, let d = Double(argv[i]), d > 0 else {
                usageError("--duration needs a positive number of seconds")
            }
            a.duration = d
        default:
            // LaunchServices may pass -psn_… or -NS… pairs to an app; ignore those.
            if arg.hasPrefix("-psn_") || arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") {
                if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") { i += 1 }
            } else {
                usageError("unknown argument '\(arg)'")
            }
        }
        i += 1
    }
    return a
}

let args = parseArguments(CommandLine.arguments)
let flavour = Flavour(isRelease: isRelease, mode: args.mode)

let config: Config
switch Config.load(env: ProcessInfo.processInfo.environment, defaultStateDir: defaultStateDir,
                   flavour: flavour, duration: args.duration) {
case .success(let c): config = c
case .failure(let e):
    EventSink(jsonTypes: nil).error(where: e.where_, e.message)
    exit(2)
}

switch args.mode {
case .headless:
    runHeadless(config: config)
case .printMenu:
    runPrintMenu(config: config)
case .dumpSnapshot:
    runDumpSnapshot(config: config, path: args.dumpPath ?? "")
case .menuApp:
    runApp(config: config)
}
