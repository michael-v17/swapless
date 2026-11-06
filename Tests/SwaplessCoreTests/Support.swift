import Foundation
@testable import SwaplessCore

enum Fixture {
    static func url(_ name: String) -> URL {
        guard let u = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            fatalError("missing fixture \(name)")
        }
        return u
    }

    static func data(_ name: String) -> Data { try! Data(contentsOf: url(name)) }
    static func text(_ name: String) -> String { String(decoding: data(name), as: UTF8.self) }
}

/// A fresh temp dir per test; never the real state dir.
func makeTempDir() -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("swapless-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return URL(fileURLWithPath: StatePaths.resolved(base))
}

/// SplitMix64: the seeded deterministic generator the spec requires (never the system RNG).
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform(_ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * Double(next() >> 11) / Double(1 << 53)
    }
}

let MB: UInt64 = 1_048_576

/// A synthetic process row.
func proc(_ pid: Int32, ppid: Int32 = 1, euid: UInt32 = 501, start: Int64 = 1_000, usec: Int32 = 0,
          name: String? = nil, path: String = "", coalition: UInt64, footprintMB: Double? = nil,
          readable: Bool? = nil, responsible: Int32 = -1, cwd: String? = nil,
          udid: String? = nil) -> ProcessSample {
    let fp = footprintMB.map { UInt64($0 * Double(MB)) }
    let n = name ?? (path.isEmpty ? "p\(pid)" : ProcessTable.basename(path))
    return ProcessSample(pid: pid, ppid: ppid, euid: euid, startSec: start, startUsec: usec,
                         name: n, path: path, coalition: coalition, jetsamCoalition: 0,
                         footprint: fp, lifetimeMax: fp, readable: readable ?? (euid == 501 && fp != nil),
                         responsiblePid: responsible, cwdBasename: cwd, simulatorUDID: udid)
}

func snapshot(_ entries: [ProcessSample], coalitions: [UInt64: Double] = [:],
              source: FootprintSourceKind = .coalition, t: Double = 1_800_000_000) -> Snapshot {
    var c: [UInt64: CoalitionSample] = [:]
    for (cid, mbv) in coalitions {
        c[cid] = CoalitionSample(cid: cid, footprint: UInt64(mbv * Double(MB)), started: 1, exited: 0)
    }
    return Snapshot(wallTime: t, uptime: 0, bootSessionUUID: "BOOT", hwMemsize: 16 << 30,
                    ownUid: 501, entries: entries, coalitions: c, system: .zero, source: source)
}
