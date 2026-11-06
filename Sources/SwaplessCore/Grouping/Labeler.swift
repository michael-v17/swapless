import Foundation

/// pid → app name. The core's default reads the enclosing `.app`'s Info.plist; the app injects
/// one backed by `NSRunningApplication` (spec § E).
public protocol AppNameProvider: Sendable {
    /// `path` is the process's executable path (empty when unknown).
    func appName(pid: Int32, path: String) -> String?
}

/// The core's default: the outermost enclosing `.app` of the process's path, named from its
/// Info.plist (`CFBundleDisplayName`, then `CFBundleName`, then the bundle's file name).
public final class InfoPlistAppNameProvider: AppNameProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: String?] = [:]

    public init() {}

    public func appName(pid: Int32, path: String) -> String? {
        guard let bundle = Labeler.outermostAppBundle(path) else { return nil }
        lock.lock()
        if let hit = cache[bundle] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let name = Self.readName(bundlePath: bundle)
        lock.lock()
        cache[bundle] = name
        lock.unlock()
        return name
    }

    static func readName(bundlePath: String) -> String? {
        let plist = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: plist),
           let d = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            if let n = d["CFBundleDisplayName"] as? String, !n.isEmpty { return n }
            if let n = d["CFBundleName"] as? String, !n.isEmpty { return n }
        }
        return Labeler.bundleName(bundlePath)
    }
}

/// Labels for groups and member rows (§ G).
public struct Labeler: Sendable {
    public var appNames: AppNameProvider?

    public init(appNames: AppNameProvider? = nil) { self.appNames = appNames }

    /// § G step 3:
    /// - the responsible pid's app name when it is > 0;
    /// - else the outermost enclosing `.app` bundle name of a member's path;
    /// - else the executable name of the earliest-started member;
    /// plus ` · system` for a group whose members all run under another euid.
    public func coalitionLabel(members: [ProcessSample], allSystem: Bool,
                               pathOfPid: (Int32) -> String? = { _ in nil }) -> String {
        let ordered = members.sorted(by: Self.earlier)
        var base: String?
        if let appNames {
            for m in ordered where m.responsiblePid > 0 {
                let path = m.responsiblePid == m.pid ? m.path : (pathOfPid(m.responsiblePid) ?? "")
                if let name = appNames.appName(pid: m.responsiblePid, path: path) {
                    base = name
                    break
                }
            }
        }
        if base == nil {
            for m in ordered {
                if let b = Self.outermostAppBundle(m.path) {
                    base = Self.bundleName(b)
                    break
                }
            }
        }
        let label = base ?? ordered.first?.name ?? "unknown"
        return allSystem ? label + " · system" : label
    }

    /// A member row's name: `Web Content (pid N)` for WebKit's content processes (matched by
    /// executable name, never by path prefix), else the executable name.
    public static func memberName(_ e: ProcessSample) -> String {
        if e.name == "com.apple.WebKit.WebContent" { return "Web Content (pid \(e.pid))" }
        return e.name
    }

    static func earlier(_ a: ProcessSample, _ b: ProcessSample) -> Bool {
        if a.startSec != b.startSec { return a.startSec < b.startSec }
        if a.startUsec != b.startUsec { return a.startUsec < b.startUsec }
        return a.pid < b.pid
    }

    /// `/Applications/Foo.app/Contents/…/Bar.app/…` → `/Applications/Foo.app`.
    public static func outermostAppBundle(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        var acc = ""
        for comp in path.split(separator: "/", omittingEmptySubsequences: true) {
            acc += "/" + comp
            if comp.hasSuffix(".app") && comp.count > 4 { return acc }
        }
        return nil
    }

    static func bundleName(_ bundlePath: String) -> String {
        let base = ProcessTable.basename(bundlePath)
        return base.hasSuffix(".app") ? String(base.dropLast(4)) : base
    }
}
