import Foundation
import Testing

/// The snapshot fixtures are real `--dump-snapshot` captures, trimmed by `scripts/trim-snapshot.py`.
/// A raw capture lists every app, agent and extension on the machine that recorded it, so a tracked
/// fixture may only hold what the trim keeps: Apple system processes, kernel_task, the simulator's
/// process tree, Claude Code sessions (folders renamed project-a, -b, …) and Swapless itself.
@Suite("Fixtures · no private process data")
struct FixturePrivacyTests {
    static let applePrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/",
                                "/Library/Apple/", "/private/var/run/com.apple.security.cryptexd/",
                                "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/"]

    @Test(arguments: ["live-snapshot.json", "sim-booted.json"])
    func onlyAllowlistedProcesses(_ name: String) throws {
        let root = try #require(JSONSerialization.jsonObject(with: Fixture.data(name)) as? [String: Any])
        let entries = try #require(root["entries"] as? [[String: Any]])
        #expect(!entries.isEmpty)
        for e in entries {
            let path = e["path"] as? String ?? ""
            let procName = e["name"] as? String ?? ""
            let cwd = e["cwdBasename"] as? String
            let allowed = Self.applePrefixes.contains { path.hasPrefix($0) }
                || procName == "kernel_task" || procName == "launchd_sim" || e["simulatorUDID"] is String
                || path.contains("/claude/versions/") || path.contains("/Swapless/.build/")
            #expect(allowed, "\(name): \(procName) at \(path) is not allowlisted; trim the capture with scripts/trim-snapshot.py")
            if let cwd {
                #expect(cwd == "Swapless" || cwd.wholeMatch(of: /project-[a-z]/) != nil,
                        "\(name): Claude Code folder '\(cwd)' must be renamed (project-a, project-b, …)")
            }
        }
    }
}
