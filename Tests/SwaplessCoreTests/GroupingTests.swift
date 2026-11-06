import Foundation
import Testing
@testable import SwaplessCore

/// A stub provider: the outermost `.app` bundle name of the given path.
struct StubAppNames: AppNameProvider {
    func appName(pid: Int32, path: String) -> String? {
        Labeler.outermostAppBundle(path).map { String(ProcessTable.basename($0).dropLast(4)) }
    }
}

let fixtureHome = "/Users/fixture"
let safariPath = "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari"
let webContentPaths = [
    "/System/Volumes/Preboot/Cryptexes/Incoming/OS/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent",
    "/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent",
    "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent",
]
let claudeV = "\(fixtureHome)/.local/share/claude/versions/2.1.318"
let wsPath = "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"
let simPath = "/Library/Developer/CoreSimulator/Volumes/iOS_23A/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.0.simruntime/Contents/Resources/RuntimeRoot/sbin/launchd_sim"

func grouper() -> Grouper { Grouper(labeler: Labeler(appNames: StubAppNames()), home: fixtureHome) }

/// The synthetic Mac most S2 tests share.
func syntheticMac() -> Snapshot {
    var e: [ProcessSample] = []
    // Safari (coalition 10) with Web Content from three cryptex prefixes.
    e.append(proc(500, path: safariPath, coalition: 10, footprintMB: 190, responsible: 500))
    e.append(proc(501, path: webContentPaths[0], coalition: 10, footprintMB: 1228.8, responsible: 500))
    e.append(proc(502, path: webContentPaths[1], coalition: 10, footprintMB: 400, responsible: 500))
    e.append(proc(503, path: webContentPaths[2], coalition: 10, footprintMB: 9, responsible: 500))
    // Another app's WebKit GPU helper stays with that app (WebThumbnailExtension).
    e.append(proc(600, path: "/System/Library/ExtensionKit/Extensions/WebThumbnailExtension.appex/Contents/MacOS/WebThumbnailExtension",
                  coalition: 11, footprintMB: 20, responsible: 600))
    e.append(proc(601, name: "com.apple.WebKit.GPU", coalition: 11, footprintMB: 30, responsible: 600))
    // Warp (coalition 20): three Claude sessions, one with a nested claude.
    e.append(proc(1171, path: "/Applications/Warp.app/Contents/MacOS/stable", coalition: 20, footprintMB: 600, responsible: 1171))
    e.append(proc(1200, ppid: 1171, name: "zsh", path: "/bin/zsh", coalition: 20, footprintMB: 5, responsible: 1171))
    e.append(proc(1201, ppid: 1200, path: claudeV, coalition: 20, footprintMB: 300, responsible: 1171, cwd: "Swapless"))
    e.append(proc(1202, ppid: 1201, name: "node", path: "/opt/homebrew/bin/node", coalition: 20, footprintMB: 50, responsible: 1171))
    e.append(proc(1203, ppid: 1201, name: "bash", path: "/bin/bash", coalition: 20, footprintMB: 2, responsible: 1171))
    e.append(proc(1204, ppid: 1203, path: claudeV, coalition: 20, footprintMB: 40, responsible: 1171, cwd: "Swapless"))  // nested
    e.append(proc(1205, ppid: 1203, euid: 0, name: "top", path: "/usr/bin/top", coalition: 20))  // setuid, unreadable: stays
    e.append(proc(1300, ppid: 1171, name: "zsh", path: "/bin/zsh", coalition: 20, footprintMB: 5, responsible: 1171))
    e.append(proc(1301, ppid: 1300, path: claudeV, coalition: 20, footprintMB: 350, responsible: 1171, cwd: "project-a"))
    e.append(proc(1400, ppid: 1171, name: "zsh", path: "/bin/zsh", coalition: 20, footprintMB: 5, responsible: 1171))
    e.append(proc(1401, ppid: 1400, path: "/opt/homebrew/bin/claude", coalition: 20, footprintMB: 200, responsible: 1171, cwd: "TypeFlow"))
    // WindowServer (coalition 381): another euid, plus a root MTLCompilerService.
    e.append(proc(88, euid: 88, path: wsPath, coalition: 381))
    e.append(proc(89, euid: 0, name: "MTLCompilerService", coalition: 381))
    // WallpaperImageExtension in its own coalition, apart from WallpaperAgent.
    e.append(proc(700, path: RestartTarget.wallpaperExtensionPath, coalition: 29980, footprintMB: 1126, responsible: 700))
    e.append(proc(701, path: RestartTarget.wallpaperAgentPath, coalition: 664, footprintMB: 25, responsible: 701))
    // A Claude process outside any terminal: its coalition is left empty and hidden.
    e.append(proc(1500, path: claudeV, coalition: 30, footprintMB: 100, responsible: 1500, cwd: "loose"))
    return snapshot(e, coalitions: [
        10: 1840, 11: 50, 20: 1600, 381: 1186.2, 29980: 1126, 664: 25, 30: 100,
    ])
}

@Suite("S2 · grouping")
struct GroupingTests {
    func find(_ g: [ProcessGroup], _ label: String) -> ProcessGroup? { g.first { $0.label == label } }

    @Test func safariKeepsItsWebContentRows() throws {
        let s = syntheticMac()
        let g = grouper().group(s)
        let safari = try #require(find(g, "Safari"))
        #expect(safari.kind == .app)
        #expect(safari.footprint == UInt64(1840 * Double(MB)))
        let names = safari.members.map { Labeler.memberName(s.entries[$0]) }
        #expect(names.first == "Web Content (pid 501)")
        #expect(names.contains("Web Content (pid 502)"))
        #expect(names.contains("Web Content (pid 503)"))
        #expect(names.contains("Safari"))
        // Another app's WebKit helper stays with that app.
        let thumb = try #require(g.first { $0.members.contains { s.entries[$0].pid == 601 } })
        #expect(thumb.label == "WebThumbnailExtension")
    }

    @Test func warpWithThreeClaudeSessionsOneNested() throws {
        let s = syntheticMac()
        let g = grouper().group(s)
        let sessions = g.filter { $0.kind == .claude }
        #expect(sessions.count == 4)  // 3 in Warp + the loose one
        let a = try #require(sessions.first { $0.rootPid == 1201 })
        #expect(a.label == "Claude Code · Swapless")
        let aPids = Set(a.members.map { s.entries[$0].pid })
        #expect(aPids == [1201, 1202, 1203, 1204])  // the nested claude belongs to the outer session
        #expect(!aPids.contains(1205))  // unreadable: never moved
        #expect(a.footprint == UInt64((300 + 50 + 2 + 40) * Double(MB)))
        #expect(a.key == s.entries.first { $0.pid == 1201 }!.identity.seriesKey)
        let b = try #require(sessions.first { $0.rootPid == 1301 })
        #expect(b.label == "Claude Code · project-a")
        let c = try #require(sessions.first { $0.rootPid == 1401 })
        #expect(c.label == "Claude Code · TypeFlow")  // the basename `claude` rule (npm/Homebrew)

        // Warp keeps the rest: coalition − Σ moved (392 + 350 + 200).
        let warp = try #require(find(g, "Warp"))
        #expect(warp.footprint == UInt64(1600 * Double(MB)) - UInt64(942 * Double(MB)))
        let warpPids = Set(warp.members.map { s.entries[$0].pid })
        #expect(warpPids == [1171, 1200, 1205, 1300, 1400])
        // The transient setuid child is a `+ N system processes` row.
        #expect(warp.unreadableCount == 1)
    }

    @Test func windowServerIsASystemCoalition() throws {
        let g = grouper().group(syntheticMac())
        let ws = try #require(find(g, "WindowServer · system"))
        #expect(ws.kind == .system)
        #expect(ws.footprint == UInt64(1186.2 * Double(MB)))
        #expect(ws.unreadableCount == 2)
        #expect(ws.unreadableBytes == ws.footprint)
    }

    @Test func wallpaperExtensionHasItsOwnGroup() throws {
        let s = syntheticMac()
        let g = grouper().group(s)
        let wie = try #require(find(g, "WallpaperImageExtension"))
        #expect(wie.members.count == 1)
        #expect(wie.key == "coal:BOOT:29980")
        let agent = try #require(find(g, "WallpaperAgent"))
        #expect(agent.key != wie.key)
    }

    @Test func emptiedCoalitionIsHidden() {
        let s = syntheticMac()
        let g = grouper().group(s)
        #expect(!g.contains { $0.coalition == 30 })
        #expect(g.contains { $0.kind == .claude && $0.rootPid == 1500 && $0.label == "Claude Code · loose" })
    }

    @Test func movedMemberThatExitedMidSweepIsNotSubtracted() throws {
        // The coalition was read with node (1202) alive; its rusage then failed with ESRCH, so
        // it isn't in the snapshot and is never subtracted.
        var s = syntheticMac()
        s.entries.removeAll { $0.pid == 1202 }
        let g = grouper().group(s)
        let warp = try #require(find(g, "Warp"))
        #expect(warp.footprint == UInt64(1600 * Double(MB)) - UInt64(892 * Double(MB)))
    }

    @Test func residualIsFlooredAtZero() throws {
        var s = syntheticMac()
        s.coalitions[20] = CoalitionSample(cid: 20, footprint: 100 * MB, started: 1, exited: 0)
        let warp = try #require(find(grouper().group(s), "Warp"))
        #expect(warp.footprint == 0)
    }

    @Test func nullGroupSortsLast() throws {
        var s = syntheticMac()
        s.source = .none
        let g = grouper().group(s)
        let ws = try #require(g.last)
        #expect(ws.label == "WindowServer · system")
        #expect(ws.footprint == nil)
        let st = { () -> EngineState in
            var x = EngineState()
            x.snapshot = s
            x.groups = g
            return x
        }()
        let rows = MenuModel.build(MenuInput(state: st))
        #expect(rows.contains { $0.title == "WindowServer · system: not readable" } || g.count > MenuModel.topGroups)
    }

    @Test func syntheticSimulatorSubtree() throws {
        let home = makeTempDir().path
        let udid = "0A1B2C3D-4E5F-4061-8293-A4B5C6D7E8F9"
        let dev = URL(fileURLWithPath: home).appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)")
        try FileManager.default.createDirectory(at: dev, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["name": "iPhone 18 Pro", "UDID": udid],
                                                       format: .xml, options: 0)
        try plist.write(to: dev.appendingPathComponent("device.plist"))
        var e: [ProcessSample] = []
        e.append(proc(900, path: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/XPCServices/com.apple.CoreSimulator.CoreSimulatorService.xpc/Contents/MacOS/com.apple.CoreSimulator.CoreSimulatorService",
                      coalition: 40, footprintMB: 55))
        e.append(proc(901, ppid: 900, path: simPath, coalition: 41, footprintMB: 10, udid: udid))
        e.append(proc(902, ppid: 901, name: "SpringBoard", coalition: 41, footprintMB: 200))
        e.append(proc(903, ppid: 901, name: "backboardd", coalition: 42, footprintMB: 60))
        e.append(proc(904, ppid: 902, name: "MobileSafari", coalition: 41, footprintMB: 120))
        e.append(proc(905, ppid: 1, name: "unrelated", coalition: 41, footprintMB: 5))
        let s = snapshot(e, coalitions: [40: 55, 41: 335, 42: 60])
        let g = Grouper(labeler: Labeler(appNames: StubAppNames()), home: home).group(s)
        let sim = try #require(g.first { $0.kind == .simulator })
        #expect(sim.label == "Simulator · iPhone 18 Pro")
        #expect(Set(sim.members.map { s.entries[$0].pid }) == [901, 902, 903, 904])
        #expect(sim.footprint == UInt64(390 * Double(MB)))
        // The coalition it emptied partly keeps only the unrelated process (335 − 330 = 5 MB).
        let rest = try #require(g.first { $0.coalition == 41 })
        #expect(rest.footprint == 5 * MB)
        #expect(!g.contains { $0.coalition == 42 })  // emptied → hidden
        // Unknown device without a plist.
        let g2 = Grouper(labeler: Labeler(), home: "/nonexistent").group(s)
        #expect(g2.first { $0.kind == .simulator }?.label == "Simulator (unknown device)")
    }

    @Test func udidExtractionKeepsOnlyTheUUID() {
        let udid = "0A1B2C3D-4E5F-4061-8293-A4B5C6D7E8F9"
        let args = Array("\u{0}\u{0}\u{0}\u{1}/path/launchd_sim\u{0}--secret=hunter2\u{0}/Users/x/Library/Developer/CoreSimulator/Devices/\(udid)/data\u{0}TOKEN=abc\u{0}".utf8)
        #expect(SimulatorResolver.extractUDID(args) == udid)
        let env = Array("x\u{0}SIMULATOR_UDID=\(udid.lowercased())\u{0}".utf8)
        #expect(SimulatorResolver.extractUDID(env) == udid)
        #expect(SimulatorResolver.extractUDID(Array("Devices/not-a-uuid/".utf8)) == nil)
    }

    @Test func labelFallbacks() {
        let l = Labeler(appNames: nil)
        // .app bundle of a member's path, outermost.
        let m1 = proc(1, path: "/Applications/Foo.app/Contents/Frameworks/Foo Helper.app/Contents/MacOS/Foo Helper", coalition: 1)
        #expect(l.coalitionLabel(members: [m1], allSystem: false) == "Foo")
        // Else the earliest-started member's executable name.
        let a = proc(2, start: 50, name: "late", coalition: 1)
        let b = proc(3, start: 10, name: "early", coalition: 1)
        #expect(l.coalitionLabel(members: [a, b], allSystem: true) == "early · system")
    }

    @Test func everyProcessLandsInExactlyOneGroup() {
        let s = syntheticMac()
        let g = grouper().group(s)
        let all = g.flatMap(\.members)
        #expect(all.count == s.entries.count)
        #expect(Set(all).count == s.entries.count)
    }

    @Test func liveFixture() throws {
        let s = try SnapshotDump.decode(Fixture.data("live-snapshot.json"), home: fixtureHome, ownUid: 501,
                                        source: .coalition)
        let g = Grouper(labeler: Labeler(appNames: InfoPlistAppNameProvider()), home: fixtureHome).group(s)
        // Coverage: every entry in exactly one group.
        #expect(Set(g.flatMap(\.members)).count == s.entries.count)
        #expect(g.flatMap(\.members).count == s.entries.count)
        // WindowServer is a system coalition; the wallpaper extension has its own group.
        let ws = try #require(g.first { $0.members.contains { s.entries[$0].path.hasSuffix("/WindowServer") } })
        #expect(ws.kind == .system)
        #expect(ws.label.hasSuffix(" · system"))
        let wie = try #require(g.first { $0.members.contains { s.entries[$0].path == RestartTarget.wallpaperExtensionPath } })
        #expect(wie.members.allSatisfy { s.entries[$0].path == RestartTarget.wallpaperExtensionPath })
        // Claude sessions: one group per root, each labelled with its cwd basename.
        let sessions = g.filter { $0.kind == .claude }
        #expect(sessions.count >= 1)
        #expect(sessions.allSatisfy { $0.label.hasPrefix("Claude Code · ") })
        // Safari's Web Content rows sit in Safari's group.
        if let safari = s.entries.first(where: { $0.name == "Safari" }) {
            let sg = try #require(g.first { $0.coalition == safari.coalition })
            #expect(sg.members.contains { s.entries[$0].name == "com.apple.WebKit.WebContent" })
        }
        // Group footprints are never above what the coalitions report.
        for grp in g where grp.coalition != nil {
            if let c = s.coalitions[grp.coalition!], let f = grp.footprint { #expect(f <= c.footprint) }
        }
    }
    @Test func realBootedSimulatorFixture() throws {
        // Recorded by `--sim` (check 6) with iPhone 18 Pro booted.
        let home = makeTempDir().path
        let s = try SnapshotDump.decode(Fixture.data("sim-booted.json"), home: home, ownUid: 501, source: .coalition)
        let root = try #require(s.entries.first { $0.name == "launchd_sim" })
        let udid = try #require(root.simulatorUDID)
        let dev = URL(fileURLWithPath: home).appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)")
        try FileManager.default.createDirectory(at: dev, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["name": "iPhone 18 Pro"], format: .xml, options: 0)
            .write(to: dev.appendingPathComponent("device.plist"))
        let g = Grouper(labeler: Labeler(appNames: StubAppNames()), home: home).group(s)
        let sims = g.filter { $0.kind == .simulator }
        #expect(sims.count == 1)
        let sim = try #require(sims.first)
        #expect(sim.label == "Simulator · iPhone 18 Pro")
        #expect((sim.footprint ?? 0) >= 300 * MB)
        // Members = launchd_sim plus its ppid-closure over the snapshot.
        var children: [Int32: [Int32]] = [:]
        for e in s.entries where e.pid != e.ppid { children[e.ppid, default: []].append(e.pid) }
        var closure = Set<Int32>()
        var stack = [root.pid]
        while let p = stack.popLast() {
            guard closure.insert(p).inserted else { continue }
            stack += children[p] ?? []
        }
        #expect(Set(sim.members.map { s.entries[$0].pid }) == closure)
        // Every process still lands in exactly one group.
        #expect(Set(g.flatMap(\.members)).count == s.entries.count)
    }
}
