// swapless-leak-helper: the rig's own process that grows its footprint at a set rate (S6).
//
// Phases: allocate --start-mb · hold --hold-start · grow at --grow-mb-per-s to --max-mb ·
// hold --hold-end · exit 0. --sawtooth LOW:HIGH:PERIOD replaces the grow and hold-end phases.
// --marker FILE: on SIGTERM, write FILE and exit 143. --max-lifetime S (default 300) is always
// enforced, and the helper exits as soon as its parent changes.
import Darwin
import Foundation

let chunkMB = 8
let mb = 1024 * 1024

struct Options {
    var startMB = 0
    var holdStart = 0.0
    var growMBPerS = 0.0
    var maxMB = 0
    var holdEnd = 120.0
    var sawtooth: (low: Int, high: Int, period: Double)?
    var marker: String?
    var maxLifetime = 300.0
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("swapless-leak-helper: \(msg)\n".utf8))
    exit(2)
}

func parse() -> Options {
    var o = Options()
    let a = CommandLine.arguments
    var i = 1
    func value() -> String {
        i += 1
        guard i < a.count else { fail("\(a[i - 1]) needs a value") }
        return a[i]
    }
    while i < a.count {
        switch a[i] {
        case "--start-mb": o.startMB = Int(value()) ?? { fail("bad --start-mb") }()
        case "--hold-start": o.holdStart = Double(value()) ?? { fail("bad --hold-start") }()
        case "--grow-mb-per-s": o.growMBPerS = Double(value()) ?? { fail("bad --grow-mb-per-s") }()
        case "--max-mb": o.maxMB = Int(value()) ?? { fail("bad --max-mb") }()
        case "--hold-end": o.holdEnd = Double(value()) ?? { fail("bad --hold-end") }()
        case "--marker": o.marker = value()
        case "--max-lifetime": o.maxLifetime = Double(value()) ?? { fail("bad --max-lifetime") }()
        case "--sawtooth":
            let parts = value().split(separator: ":")
            guard parts.count == 3, let lo = Int(parts[0]), let hi = Int(parts[1]),
                  let p = Double(parts[2]), lo >= 0, hi > lo, p > 0 else { fail("bad --sawtooth LOW:HIGH:PERIOD") }
            o.sawtooth = (lo, hi, p)
        default: fail("unknown argument \(a[i])")
        }
        i += 1
    }
    return o
}

let opts = parse()

// SIGTERM: write the marker (async-signal-safe calls only) and exit 143.
nonisolated(unsafe) var markerCString: UnsafeMutablePointer<CChar>? = nil
if let m = opts.marker { markerCString = strdup(m) }
signal(SIGTERM) { _ in
    if let p = markerCString {
        let fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 {
            let msg = "sigterm\n"
            _ = msg.withCString { write(fd, $0, strlen($0)) }
            close(fd)
        }
    }
    _exit(143)
}

nonisolated(unsafe) var chunks: [(ptr: UnsafeMutableRawPointer, mb: Int)] = []
nonisolated(unsafe) var allocatedMB = 0
nonisolated(unsafe) var refused = false

func memoryLevel() -> Int {
    var v: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.memorystatus_level", &v, &size, nil, 0) == 0 else { return 100 }
    return Int(v)
}

func emit(_ phase: String) {
    let t = Date().timeIntervalSince1970
    print("{\"t\":\(t),\"allocatedMB\":\(allocatedMB),\"phase\":\"\(phase)\"}")
    fflush(stdout)
}

func emitRefused() {
    let t = Date().timeIntervalSince1970
    print("{\"t\":\(t),\"allocatedMB\":\(allocatedMB),\"refused\":true}")
    fflush(stdout)
}

/// Allocates or frees 8 MB chunks (the last one may be partial) toward `target` MB.
func adjust(to target: Int) {
    while allocatedMB < target {
        if refused { return }
        if memoryLevel() < 30 {
            refused = true
            emitRefused()
            return
        }
        let size = min(chunkMB, target - allocatedMB)
        let bytes = size * mb
        guard let p = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0),
              p != MAP_FAILED else {
            fail("mmap failed")
        }
        memset(p, 0xA5, bytes)  // touch every page with a non-zero pattern
        chunks.append((p, size))
        allocatedMB += size
    }
    while let last = chunks.last, allocatedMB - last.mb >= target {
        munmap(last.ptr, last.mb * mb)
        chunks.removeLast()
        allocatedMB -= last.mb
    }
}

let parent = getppid()
let t0 = Date().timeIntervalSince1970
let mono0 = DispatchTime.now().uptimeNanoseconds
func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - mono0) / 1e9 }

adjust(to: opts.startMB)
var phase = "start"
var lastPrint = -1.0
var growStart: Double?
var holdEndStart: Double?

while true {
    let now = elapsed()
    if getppid() != parent { exit(5) }
    if now >= opts.maxLifetime { exit(4) }

    if now < opts.holdStart {
        phase = "hold-start"
    } else if let saw = opts.sawtooth {
        if holdEndStart == nil { holdEndStart = now }
        let s = now - holdEndStart!
        if s >= opts.holdEnd {
            emit("done")
            exit(0)
        }
        phase = "sawtooth"
        let x = s.truncatingRemainder(dividingBy: saw.period) / saw.period  // 0..1
        let tri = x < 0.5 ? x * 2 : (1 - x) * 2
        let raw = Double(saw.low) + Double(saw.high - saw.low) * tri
        let target = saw.low + Int((raw - Double(saw.low)) / Double(chunkMB)) * chunkMB
        adjust(to: min(saw.high, max(saw.low, target)))
    } else if opts.growMBPerS > 0 && holdEndStart == nil {
        if growStart == nil { growStart = now }
        phase = "grow"
        let target = min(opts.maxMB, opts.startMB + Int(opts.growMBPerS * (now - growStart!)))
        adjust(to: target)
        if allocatedMB >= opts.maxMB || refused { holdEndStart = now }
    } else {
        if holdEndStart == nil { holdEndStart = now }
        phase = "hold-end"
        if now - holdEndStart! >= opts.holdEnd {
            emit("done")
            exit(0)
        }
    }

    if now - lastPrint >= 1.0 {
        lastPrint = now
        emit(phase)
    }
    usleep(20_000)
}
