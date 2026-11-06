import Foundation
import Testing
@testable import SwaplessCore

/// § C / § K: env seams and the state-dir refusal. Every test injects a temp
/// `<tmp>/Application Support/Swapless` as the default; the real path is never computed here.
@Suite("Config · state dir and seams")
struct ConfigTests {
    let root = makeTempDir()
    var fakeDefault: URL { root.appendingPathComponent("Application Support/Swapless") }

    func load(_ env: [String: String], release: Bool, mode: Flavour.Mode) -> Result<Config, ConfigError> {
        Config.load(env: env, defaultStateDir: fakeDefault,
                    flavour: Flavour(isRelease: release, mode: mode), cwd: root.path)
    }

    @Test func releaseMenuAppMayUseDefault() throws {
        let c = try load([:], release: true, mode: .menuApp).get()
        #expect(c.usesDefaultStateDir)
        #expect(c.stateDir == fakeDefault)
        // The refusal is decided before any mkdir.
        #expect(!FileManager.default.fileExists(atPath: fakeDefault.path))
    }

    @Test(arguments: [Flavour.Mode.headless, .printMenu, .dumpSnapshot])
    func otherModesRequireStateDirInAnyBuild(mode: Flavour.Mode) {
        for release in [true, false] {
            #expect(throws: ConfigError.self) { try load([:], release: release, mode: mode).get() }
            #expect(throws: ConfigError.self) {
                try load(["SWAPLESS_STATE_DIR": fakeDefault.path], release: release, mode: mode).get()
            }
        }
    }

    @Test(arguments: [Flavour.Mode.menuApp, .headless, .printMenu, .dumpSnapshot])
    func debugRefusesDefaultInEveryMode(mode: Flavour.Mode) {
        #expect(throws: ConfigError.self) { try load([:], release: false, mode: mode).get() }
        #expect(throws: ConfigError.self) {
            try load(["SWAPLESS_STATE_DIR": fakeDefault.path], release: false, mode: mode).get()
        }
    }

    @Test func refusalSeesThroughSymlinksTrailingSlashAndCase() throws {
        try FileManager.default.createDirectory(at: fakeDefault, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fakeDefault)
        for variant in [link.path, fakeDefault.path + "/", fakeDefault.path.uppercased(),
                        root.path + "/Application Support/./Swapless",
                        root.path + "/x/../Application Support/Swapless"] {
            #expect(throws: ConfigError.self) {
                try load(["SWAPLESS_STATE_DIR": variant], release: false, mode: .headless).get()
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fakeDefault.appendingPathComponent("rules.json").path))
    }

    @Test func tempDirIsAccepted() throws {
        let dir = root.appendingPathComponent("state").path
        for release in [true, false] {
            for mode in [Flavour.Mode.menuApp, .headless, .printMenu, .dumpSnapshot] {
                let c = try load(["SWAPLESS_STATE_DIR": dir], release: release, mode: mode).get()
                #expect(!c.usesDefaultStateDir)
                #expect(c.stateDirEnv == dir)
            }
        }
    }

    @Test func releaseMenuAppWithExplicitDefaultIsAllowedButNotDefault() throws {
        let c = try load(["SWAPLESS_STATE_DIR": fakeDefault.path], release: true, mode: .menuApp).get()
        #expect(!c.usesDefaultStateDir)  // seeding needs the env unset
    }

    @Test func dryRunAcceptsExactly0Or1() throws {
        let dir = root.path
        #expect(try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_DRY_RUN": "1"], release: false, mode: .headless).get().dryRun)
        #expect(try !load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_DRY_RUN": "0"], release: false, mode: .headless).get().dryRun)
        for bad in ["", "true", "yes", "01", " 1", "2"] {
            #expect(throws: ConfigError.self) {
                try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_DRY_RUN": bad], release: false, mode: .headless).get()
            }
        }
    }

    @Test func intervalValidated() throws {
        let dir = root.path
        #expect(try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_SAMPLE_INTERVAL": "0.25"], release: false, mode: .headless).get().sampleInterval == 0.25)
        #expect(try load(["SWAPLESS_STATE_DIR": dir], release: false, mode: .headless).get().sampleInterval == 30)
        for bad in ["0.2", "0", "-1", "abc", "nan", "inf"] {
            #expect(throws: ConfigError.self) {
                try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_SAMPLE_INTERVAL": bad], release: false, mode: .headless).get()
            }
        }
    }

    @Test func forceTopAndMenuCycles() throws {
        let dir = root.path
        #expect(try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_FORCE_TOP": "1"], release: false, mode: .headless).get().forceTop)
        #expect(throws: ConfigError.self) {
            try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_FORCE_TOP": "yes"], release: false, mode: .headless).get()
        }
        #expect(try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_RIG_MENU_CYCLES": "20"], release: true, mode: .menuApp).get().rigMenuCycles == 20)
        // Ignored by --headless.
        #expect(try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_RIG_MENU_CYCLES": "x"], release: true, mode: .headless).get().rigMenuCycles == nil)
        #expect(throws: ConfigError.self) {
            try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_RIG_MENU_CYCLES": "0"], release: true, mode: .menuApp).get()
        }
    }

    @Test func menuShows() throws {
        let dir = root.path
        #expect(try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_RIG_MENU_SHOWS": "10"], release: true, mode: .menuApp).get().rigMenuShows == 10)
        // Ignored by --headless.
        #expect(try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_RIG_MENU_SHOWS": "x"], release: true, mode: .headless).get().rigMenuShows == nil)
        #expect(throws: ConfigError.self) {
            try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_RIG_MENU_SHOWS": "0"], release: true, mode: .menuApp).get()
        }
        // Not together with menu cycles (they run without a status item).
        #expect(throws: ConfigError.self) {
            try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_RIG_MENU_SHOWS": "2", "SWAPLESS_RIG_MENU_CYCLES": "2"],
                     release: true, mode: .menuApp).get()
        }
    }

    @Test func menuDraws() throws {
        let dir = root.path
        #expect(try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_RIG_MENU_DRAWS": "50"], release: true, mode: .menuApp).get().rigMenuDraws == 50)
        #expect(try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_RIG_MENU_DRAWS": "x"], release: true, mode: .headless).get().rigMenuDraws == nil)
        #expect(throws: ConfigError.self) {
            try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_RIG_MENU_DRAWS": "0"], release: true, mode: .menuApp).get()
        }
        // Exclusive with the other menu modes.
        for other in ["SWAPLESS_RIG_MENU_CYCLES", "SWAPLESS_RIG_MENU_SHOWS"] {
            #expect(throws: ConfigError.self) {
                try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_RIG_MENU_DRAWS": "2", other: "2"], release: true, mode: .menuApp).get()
            }
        }
    }

    /// v1-menu-today S5.
    @Test func menuOpen() throws {
        let dir = root.path
        for release in [true, false] {
            #expect(try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_RIG_MENU_OPEN": "60"], release: release, mode: .menuApp).get().rigMenuOpen == 60)
        }
        #expect(try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_RIG_MENU_OPEN": "50"], release: true, mode: .menuApp).get().rigMenuOpen == 50)
        #expect(try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_RIG_MENU_OPEN": "600"], release: true, mode: .menuApp).get().rigMenuOpen == 600)
        for bad in ["49", "601", "x"] {
            #expect(throws: ConfigError.self) {
                try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_RIG_MENU_OPEN": bad], release: true, mode: .menuApp).get()
            }
            // Ignored outside app mode, as _DRAWS is.
            #expect(try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_RIG_MENU_OPEN": bad], release: true, mode: .headless).get().rigMenuOpen == nil)
        }
        for other in ["SWAPLESS_RIG_MENU_CYCLES", "SWAPLESS_RIG_MENU_SHOWS", "SWAPLESS_RIG_MENU_DRAWS"] {
            #expect(throws: ConfigError.self) {
                try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_RIG_MENU_OPEN": "60", other: "2"], release: true, mode: .menuApp).get()
            }
        }
    }

    @Test func rigHelperPathDebugOnly() throws {
        let dir = root.path
        let d = try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_RIG_HELPER_PATH": "/x/swapless-leak-helper"], release: false, mode: .headless).get()
        #expect(d.rigHelperPath == "/x/swapless-leak-helper")
        #expect(d.allowedTargets.contains("rig-helper"))
        let r = try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_RIG_HELPER_PATH": "/x/swapless-leak-helper"], release: true, mode: .headless).get()
        #expect(r.rigHelperPath == nil)
        #expect(r.rigHelperIgnored)
        #expect(r.allowedTargets == ["wallpaper"])
    }

    @Test func detectorConfigNeedsAll15Keys() throws {
        let dir = root.path
        var obj: [String: Any] = [:]
        let d = DetectorConfig.defaults
        let mirror = Mirror(reflecting: d)
        for c in mirror.children { obj[c.label!] = c.value }
        #expect(obj.count == 15)
        let good = root.appendingPathComponent("det.json")
        try JSONSerialization.data(withJSONObject: obj).write(to: good)
        #expect(try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_DETECTOR_CONFIG": good.path], release: false, mode: .headless).get().detectorConfig == d)

        var missing = obj
        missing.removeValue(forKey: "floorMB")
        let m = root.appendingPathComponent("missing.json")
        try JSONSerialization.data(withJSONObject: missing).write(to: m)
        #expect(throws: ConfigError.self) {
            try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_DETECTOR_CONFIG": m.path], release: false, mode: .headless).get()
        }

        var extra = obj
        extra["bogus"] = 1
        let x = root.appendingPathComponent("extra.json")
        try JSONSerialization.data(withJSONObject: extra).write(to: x)
        #expect(throws: ConfigError.self) {
            try load(["SWAPLESS_STATE_DIR": dir, "SWAPLESS_DETECTOR_CONFIG": x.path], release: false, mode: .headless).get()
        }
    }

    @Test func rigDetectorFileDecodes() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../scripts/rig/detector-rig.json").standardizedFileURL
        let c = try DetectorConfig.decodeStrict(try Data(contentsOf: url)).get()
        #expect(c.bucketSeconds == 2)
        #expect(c.trackFloorMB == 16)
        #expect(c.floorMB == 200)
        #expect(c.baselineMultiplier == 1)
        #expect(c.minBucketsInWindow == 6)
        #expect(c.minSlopeMBPerHour == 3600)
        #expect(c.fastPathWindowSeconds == 10)
    }
}
