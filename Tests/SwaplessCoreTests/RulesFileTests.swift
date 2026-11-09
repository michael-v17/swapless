import Foundation
import Testing
@testable import SwaplessCore

@Suite("S4 · rules.json strict decoding")
struct RulesFileTests {
    let allowed: Set<String> = ["wallpaper"]

    func decode(_ s: String, allowed: Set<String>? = nil) -> RulesLoad {
        RulesFile.decode(Data(s.utf8), allowedTargets: allowed ?? self.allowed)
    }

    let seedJSON = """
    {"version":1,"rules":[{"id":"wallpaper-leak-guard","note":"n","enabled":true,"target":"wallpaper",
    "action":"restart","footprintAboveMB":1024,"consecutiveSamples":2,"cooldownMinutes":30,"maxPerDay":8}]}
    """

    @Test func seedDecodes() {
        let r = decode(seedJSON)
        #expect(r.status == .ok)
        #expect(r.validRules.count == 1)
        #expect(r.validRules[0].footprintAboveMB == 1024)
        #expect(r.allValid)
    }

    @Test func emptyRules() {
        let r = decode("{\"version\":1,\"rules\":[]}")
        #expect(r.status == .ok)
        #expect(r.entries.isEmpty)
    }

    @Test func fileLevelErrorsInvalidateTheFile() {
        #expect(decode("{not json").status == .invalid)
        #expect(decode("[]").status == .invalid)
        #expect(decode("{\"version\":3,\"rules\":[]}").status == .invalid)
        #expect(decode("{\"version\":true,\"rules\":[]}").status == .invalid)
        #expect(decode("{\"version\":1,\"rules\":[],\"extra\":1}").status == .invalid)
        #expect(decode("{\"version\":1}").status == .invalid)
        let r = decode("{\"version\":1,\"rules\":[],\"extra\":1}")
        #expect(r.validRules.isEmpty)
        #expect(r.fileError != nil)
    }

    @Test func unknownKeyInARuleInvalidatesOnlyThatRule() {
        let r = decode("""
        {"version":1,"rules":[
          {"id":"a","enabled":true,"target":"wallpaper","action":"restart","footprintAboveMB":1024,"cooldownMinutes":30,"maxPerDay":8,"bogus":1}
        ]}
        """)
        #expect(r.status == .ok)
        #expect(r.entries.count == 1)
        #expect(!r.entries[0].valid)
        #expect(r.entries[0].error?.contains("bogus") == true)
        #expect(!r.allValid)
    }

    @Test func wrongTypesAndRanges() {
        func one(_ body: String) -> RuleEntry {
            decode("{\"version\":1,\"rules\":[{\(body)}]}").entries[0]
        }
        let base = "\"id\":\"a\",\"target\":\"wallpaper\",\"action\":\"restart\",\"cooldownMinutes\":30,\"maxPerDay\":8"
        #expect(one(base + ",\"enabled\":true,\"footprintAboveMB\":1024").valid)
        #expect(!one(base + ",\"enabled\":1,\"footprintAboveMB\":1024").valid)
        #expect(!one(base + ",\"enabled\":true,\"footprintAboveMB\":\"1024\"").valid)
        #expect(!one(base + ",\"enabled\":true,\"footprintAboveMB\":1024.5").valid)
        #expect(!one(base + ",\"enabled\":true,\"footprintAboveMB\":0").valid)
        #expect(!one(base + ",\"enabled\":true,\"footprintAboveMB\":65537").valid)
        #expect(one(base + ",\"enabled\":true,\"footprintAboveMB\":1").valid)
        #expect(!one(base + ",\"enabled\":true,\"footprintAboveMB\":1024,\"consecutiveSamples\":21").valid)
        #expect(!one(base + ",\"enabled\":true,\"footprintAboveMB\":1024,\"note\":5").valid)
        #expect(!one("\"id\":\"\",\"target\":\"wallpaper\",\"action\":\"restart\",\"cooldownMinutes\":30,\"maxPerDay\":8,\"enabled\":true,\"footprintAboveMB\":1").valid)
        // Missing required field.
        #expect(!one("\"id\":\"a\",\"target\":\"wallpaper\",\"action\":\"restart\",\"cooldownMinutes\":30,\"enabled\":true,\"footprintAboveMB\":1").valid)
        // consecutiveSamples defaults to 2.
        #expect(one(base + ",\"enabled\":true,\"footprintAboveMB\":1024").rule?.consecutiveSamples == 2)
    }

    @Test func unknownTargetAndAction() {
        let t = decode("""
        {"version":1,"rules":[{"id":"a","enabled":true,"target":"WindowServer","action":"restart","footprintAboveMB":1,"cooldownMinutes":1,"maxPerDay":1}]}
        """)
        #expect(t.status == .ok)
        #expect(t.entries[0].error == "unknown target")
        let a = decode("""
        {"version":1,"rules":[{"id":"a","enabled":true,"target":"wallpaper","action":"quit","footprintAboveMB":1,"cooldownMinutes":1,"maxPerDay":1}]}
        """)
        #expect(a.status == .ok)
        #expect(!a.entries[0].valid)
        // rig-helper is unknown unless the code allowlist names it (release builds never do).
        let h = decode("""
        {"version":1,"rules":[{"id":"h","enabled":true,"target":"rig-helper","action":"restart","footprintAboveMB":1,"cooldownMinutes":1,"maxPerDay":1}]}
        """, allowed: ["wallpaper"])
        #expect(h.entries[0].error == "unknown target")
    }

    @Test func duplicateTarget() {
        let r = decode("""
        {"version":1,"rules":[
          {"id":"a","enabled":true,"target":"wallpaper","action":"restart","footprintAboveMB":1024,"cooldownMinutes":30,"maxPerDay":8},
          {"id":"b","enabled":true,"target":"wallpaper","action":"restart","footprintAboveMB":2048,"cooldownMinutes":30,"maxPerDay":8}
        ]}
        """)
        #expect(r.entries[0].valid)
        #expect(r.entries[1].error == "duplicate target")
        #expect(r.validRules.count == 1)
    }

    @Test func rulesLineShape() {
        let r = decode("{\"version\":1,\"rules\":[]}")
        let seedIds = QuitSettings.seedApps.map { "\"\($0.bundleId)\"" }.sorted().joined(separator: ",")
        #expect(r.json.serialized == "{\"type\":\"rules\",\"status\":\"ok\",\"rules\":[],\"quit\":{\"status\":\"default\",\"enabled\":false,\"neverQuit\":[\(seedIds)],\"error\":null}}")
        let m = RulesLoad.missing
        #expect(m.json.serialized == "{\"type\":\"rules\",\"status\":\"missing\",\"rules\":[],\"quit\":{\"status\":\"missing\",\"enabled\":false,\"neverQuit\":[],\"error\":null}}")
    }

    @Test func missingFileMeansNoRules() {
        let dir = makeTempDir()
        let r = RulesFile.load(url: RulesFile.url(in: dir), allowedTargets: allowed)
        #expect(r.status == .missing)
        #expect(r.validRules.isEmpty)
    }
}
