import Foundation
import Testing
@testable import SwaplessCore

/// v1-quit-on-close S1: `rules.json` version 2 (the quit switch and the `apps` table).
@Suite("Quit · rules.json v2")
struct RulesFileV2Tests {
    let allowed: Set<String> = ["wallpaper"]

    func decode(_ s: String) -> RulesLoad {
        RulesFile.decode(Data(s.utf8), allowedTargets: allowed)
    }

    func v2(enabled: String = "false", apps: String = "[]", extraTop: String = "") -> String {
        "{\"version\":2,\"rules\":[\(wallRule())],\"quitOnLastWindow\":{\"enabled\":\(enabled)},\"apps\":\(apps)\(extraTop)}"
    }

    let mexico = TimeZone(identifier: "America/Mexico_City")!
    /// 2026-11-06 12:00 local in Mexico City.
    let now = 1_793_988_000.0

    @Test func v1FileKeepsItsRulesAndReadsTheDefaults() {
        let r = decode("{\"version\":1,\"rules\":[\(wallRule())]}")
        #expect(r.status == .ok)
        #expect(r.validRules.count == 1)
        #expect(r.quit.status == .default)
        #expect(r.quit.enabled == false)
        #expect(r.quit.apps.count == 11)
        #expect(r.quit.neverQuitIds == Set(QuitSettings.seedApps.map(\.bundleId)))
        #expect(r.allValid)
        #expect(!r.quit.isActive)
    }

    @Test func seedListIsTheOwnersListSortedCaseInsensitively() {
        let names = QuitSettings.seed.apps.map(\.name)
        #expect(names == ["Claude", "iTerm2", "Mail", "Messages", "Music", "OpenMausBot", "Portal",
                          "Tailscale", "Warp", "WhatsApp", "ZeroTier"])
        #expect(QuitSettings.seed.apps.allSatisfy { $0.neverQuit && $0.note == QuitSettings.seedNote })
        #expect(QuitSettings.seed.apps.first { $0.name == "OpenMausBot" }?.bundleId == "com.openmausbot.app")
    }

    @Test func v2RoundTripsAndSortsApps() {
        let apps = """
        [{"bundleId":"com.b","name":"zeta","neverQuit":true},
         {"bundleId":"com.a","name":"Alpha","neverQuit":false,"note":"n"}]
        """
        let r = decode(v2(enabled: "true", apps: apps))
        #expect(r.quit.status == .ok)
        #expect(r.quit.enabled)
        #expect(r.quit.isActive)
        #expect(r.quit.apps.map(\.bundleId) == ["com.a", "com.b"])
        #expect(r.quit.neverQuitIds == ["com.b"])
        let again = RulesFile.decode(RulesFile.encode(r.validRules, quit: r.quit), allowedTargets: allowed)
        #expect(again.quit == r.quit)
        #expect(again.validRules == r.validRules)
    }

    @Test func fileLevelErrorsStillInvalidateTheWholeFile() {
        let unknown = decode(v2(extraTop: ",\"extra\":1"))
        #expect(unknown.status == .invalid)
        #expect(unknown.fileError == "unknown top-level key 'extra'")
        #expect(unknown.quit.status == .invalid)
        #expect(decode("{\"version\":3,\"rules\":[]}").status == .invalid)
        let v1WithApps = decode("{\"version\":1,\"rules\":[],\"apps\":[]}")
        #expect(v1WithApps.status == .invalid)
        #expect(v1WithApps.fileError == "unknown top-level key 'apps'")
    }

    @Test func sectionErrorsInvalidateOnlyTheQuitSection() {
        let cases: [(String, String)] = [
            ("{\"version\":2,\"rules\":[\(wallRule())],\"apps\":[]}", "missing key 'quitOnLastWindow'"),
            ("{\"version\":2,\"rules\":[\(wallRule())],\"quitOnLastWindow\":{\"enabled\":false}}", "missing key 'apps'"),
            ("{\"version\":2,\"rules\":[\(wallRule())],\"quitOnLastWindow\":true,\"apps\":[]}", "'quitOnLastWindow' must be an object"),
            ("{\"version\":2,\"rules\":[\(wallRule())],\"quitOnLastWindow\":{},\"apps\":[]}", "quitOnLastWindow: missing key 'enabled'"),
            ("{\"version\":2,\"rules\":[\(wallRule())],\"quitOnLastWindow\":{\"enabled\":1},\"apps\":[]}", "quitOnLastWindow: 'enabled' must be a boolean"),
            ("{\"version\":2,\"rules\":[\(wallRule())],\"quitOnLastWindow\":{\"enabled\":true,\"x\":1},\"apps\":[]}", "quitOnLastWindow: unknown key 'x'"),
            (v2(apps: "{}"), "'apps' must be an array"),
            (v2(apps: "[1]"), "apps[0]: not an object"),
            (v2(apps: "[{\"bundleId\":\"a\",\"name\":\"A\"}]"), "apps[0]: missing key 'neverQuit'"),
            (v2(apps: "[{\"bundleId\":\"a\",\"name\":\"A\",\"neverQuit\":true,\"x\":1}]"), "apps[0]: unknown key 'x'"),
            (v2(apps: "[{\"bundleId\":\"\",\"name\":\"A\",\"neverQuit\":true}]"), "apps[0]: 'bundleId' must be 1…255 characters with no whitespace"),
            (v2(apps: "[{\"bundleId\":\"a b\",\"name\":\"A\",\"neverQuit\":true}]"), "apps[0]: 'bundleId' must be 1…255 characters with no whitespace"),
            (v2(apps: "[{\"bundleId\":\"a\",\"name\":\"\",\"neverQuit\":true}]"), "apps[0]: 'name' must be 1…255 characters"),
            (v2(apps: "[{\"bundleId\":\"a\",\"name\":\"A\",\"neverQuit\":\"yes\"}]"), "apps[0]: 'neverQuit' must be a boolean"),
            (v2(apps: "[{\"bundleId\":\"a\",\"name\":\"A\",\"neverQuit\":true,\"note\":3}]"), "apps[0]: 'note' must be a string"),
            (v2(apps: "[{\"bundleId\":\"a\",\"name\":\"A\",\"neverQuit\":true},{\"bundleId\":\"a\",\"name\":\"B\",\"neverQuit\":true}]"), "apps[1]: duplicate bundleId"),
        ]
        for (json, error) in cases {
            let r = decode(json)
            #expect(r.status == .ok, "\(error)")
            #expect(r.quit.status == .invalid, "\(error)")
            #expect(r.quit.error == error)
            #expect(!r.quit.isActive)
            #expect(r.validRules.count == 1, "the restart rule keeps working: \(error)")
            #expect(!r.allValid)
        }
    }

    @Test func moreThan500EntriesInvalidatesTheSection() {
        let entries = (0...500).map { "{\"bundleId\":\"com.x\($0)\",\"name\":\"X\($0)\",\"neverQuit\":true}" }
        let r = decode(v2(apps: "[" + entries.joined(separator: ",") + "]"))
        #expect(r.quit.status == .invalid)
        #expect(r.quit.error == "'apps' has more than 500 entries")
        let ok = decode(v2(apps: "[" + entries.dropLast().joined(separator: ",") + "]"))
        #expect(ok.quit.status == .ok)
    }

    @Test func finderIsNeverInTheListUnlessListed() {
        #expect(!QuitSettings.seed.neverQuitIds.contains(QuitSettings.finderBundleId))
        let r = decode(v2(apps: "[{\"bundleId\":\"com.apple.finder\",\"name\":\"Finder\",\"neverQuit\":true}]"))
        #expect(r.quit.neverQuitIds == ["com.apple.finder"])
    }

    @Test func seedFileIsV2WithTheRuleTheListAndTheSwitchOff() throws {
        let dir = makeTempDir()
        let url = RulesFile.url(in: dir)
        #expect(RulesFile.restoreDefault(url: url) == .written)
        let r = RulesFile.load(url: url, allowedTargets: allowed)
        #expect(r.validRules == [RulesFile.seedRule])
        #expect(r.quit == QuitSettings.seed)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"version\" : 2"))
    }

    @Test func quitToggleFromAV1FileWritesV2KeepingTheRule() throws {
        let dir = makeTempDir()
        let url = RulesFile.url(in: dir)
        try Data("{\"version\":1,\"rules\":[\(wallRule(maxPerDay: 8))]}".utf8).write(to: url)
        let before = RulesFile.load(url: url, allowedTargets: allowed)
        #expect(RulesFile.writeQuitEnabled(url: url, load: before, enabled: true) == .written)
        let after = RulesFile.load(url: url, allowedTargets: allowed)
        #expect(after.validRules == before.validRules)
        #expect(after.quit.status == .ok)
        #expect(after.quit.enabled)
        #expect(after.quit.apps == QuitSettings.seedApps)
    }

    @Test func wallpaperToggleOnAV1FileWritesV2WithTheSeedList() throws {
        let dir = makeTempDir()
        let url = RulesFile.url(in: dir)
        try Data("{\"version\":1,\"rules\":[\(wallRule())]}".utf8).write(to: url)
        let l = RulesFile.load(url: url, allowedTargets: allowed)
        #expect(RulesFile.writeEnabled(url: url, load: l, ruleId: "wallpaper-leak-guard", enabled: false) == .written)
        let after = RulesFile.load(url: url, allowedTargets: allowed)
        #expect(after.validRules.first?.enabled == false)
        #expect(after.quit == QuitSettings.seed)
    }

    @Test func addAndRemove() throws {
        let dir = makeTempDir()
        let url = RulesFile.url(in: dir)
        try Data(v2(apps: "[{\"bundleId\":\"com.kept\",\"name\":\"Kept\",\"neverQuit\":false,\"note\":\"mine\"}]").utf8).write(to: url)
        var l = RulesFile.load(url: url, allowedTargets: allowed)
        #expect(RulesFile.addNeverQuit(url: url, load: l, bundleId: "com.apple.Notes", name: "Notes",
                                       now: now, timeZone: mexico) == .written)
        l = RulesFile.load(url: url, allowedTargets: allowed)
        let notes = try #require(l.quit.apps.first { $0.bundleId == "com.apple.Notes" })
        #expect(notes == AppEntry(bundleId: "com.apple.Notes", name: "Notes", neverQuit: true,
                                  note: "Added from the menu 2026-11-06"))
        // An existing entry keeps its name and note.
        #expect(RulesFile.addNeverQuit(url: url, load: l, bundleId: "com.kept", name: "Other",
                                       now: now, timeZone: mexico) == .written)
        l = RulesFile.load(url: url, allowedTargets: allowed)
        #expect(l.quit.apps.first { $0.bundleId == "com.kept" } == AppEntry(bundleId: "com.kept", name: "Kept",
                                                                           neverQuit: true, note: "mine"))
        #expect(RulesFile.removeNeverQuit(url: url, load: l, bundleId: "com.apple.Notes") == .written)
        l = RulesFile.load(url: url, allowedTargets: allowed)
        #expect(l.quit.apps.map(\.bundleId) == ["com.kept"])
    }

    @Test func everyWriteRefusesWhenInvalidOrChanged() throws {
        let dir = makeTempDir()
        let url = RulesFile.url(in: dir)
        try Data(v2(apps: "[{\"bundleId\":\"a\",\"name\":\"A\"}]").utf8).write(to: url)
        let bad = RulesFile.load(url: url, allowedTargets: allowed)
        #expect(RulesFile.writeQuitEnabled(url: url, load: bad, enabled: true) == .notAllowed)
        #expect(RulesFile.addNeverQuit(url: url, load: bad, bundleId: "b", name: "B", now: now, timeZone: mexico) == .notAllowed)
        #expect(RulesFile.removeNeverQuit(url: url, load: bad, bundleId: "a") == .notAllowed)
        #expect(RulesFile.writeEnabled(url: url, load: bad, ruleId: "wallpaper-leak-guard", enabled: false) == .notAllowed)

        try Data(v2().utf8).write(to: url)
        let l = RulesFile.load(url: url, allowedTargets: allowed)
        Thread.sleep(forTimeInterval: 0.01)
        try Data(v2(enabled: "true").utf8).write(to: url)
        #expect(RulesFile.writeQuitEnabled(url: url, load: l, enabled: false) == .skippedChanged)
        #expect(RulesFile.addNeverQuit(url: url, load: l, bundleId: "b", name: "B", now: now, timeZone: mexico) == .skippedChanged)
        #expect(RulesFile.removeNeverQuit(url: url, load: l, bundleId: "a") == .skippedChanged)
        #expect(RulesFile.load(url: url, allowedTargets: allowed).quit.enabled)
    }

    @Test func missingFileMeansQuitOffAndNotWritable() {
        let r = RulesFile.load(url: RulesFile.url(in: makeTempDir()), allowedTargets: allowed)
        #expect(r.quit.status == .missing)
        #expect(!r.quit.isActive)
        #expect(!r.allValid)
    }
}
