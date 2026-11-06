import Foundation

/// One base-tick observation of a series (§ H).
public struct SeriesObservation: Sendable {
    public var key: String
    /// "process" or "coalition".
    public var kind: String
    public var pid: Int32?
    public var label: String
    public var path: String
    public var groupLabel: String
    public var footprint: UInt64
    /// `ri_lifetime_max_phys_footprint`, when readable.
    public var lifetimeMax: UInt64?

    public init(key: String, kind: String, pid: Int32?, label: String, path: String,
                groupLabel: String, footprint: UInt64, lifetimeMax: UInt64?) {
        self.key = key
        self.kind = kind
        self.pid = pid
        self.label = label
        self.path = path
        self.groupLabel = groupLabel
        self.footprint = footprint
        self.lifetimeMax = lifetimeMax
    }
}

/// A wall-aligned bucket: min and max of its base-tick samples.
public struct Bucket: Sendable, Equatable {
    public var start: Double
    public var min: UInt64
    public var max: UInt64
    public var count: Int

    public init(start: Double, min: UInt64, max: UInt64, count: Int) {
        self.start = start
        self.min = min
        self.max = max
        self.count = count
    }
}

/// What the detector reports.
public enum DetectorEvent: Sendable, Equatable {
    case flag(FlagEvent)
    case unflag(FlagEvent)
    /// A bucket closed (for history).
    case bucketClosed(key: String, bucket: Bucket)
}

public struct FlagEvent: Sendable, Equatable {
    public var t: Double
    public var seriesKey: String
    public var pid: Int32?
    public var label: String
    public var footprint: UInt64
    public var slopeMBPerHour: Double?
    public var baselineMB: Double?
    public var reason: String

    public var json: JSON { json(type: "flag") }

    public func json(type: String) -> JSON {
        .object([
            ("type", .string(type)),
            ("t", .double(t)),
            ("seriesKey", .string(seriesKey)),
            ("pid", .opt(pid)),
            ("label", .string(label)),
            ("footprint", .uint(footprint)),
            ("slopeMBPerHour", .opt(slopeMBPerHour)),
            ("baselineMB", .opt(baselineMB)),
            ("reason", .string(reason)),
        ])
    }
}

/// Persisted series metadata (the `series` table).
public struct SeriesMeta: Sendable, Equatable {
    public var key: String
    public var kind: String
    public var label: String
    public var path: String
    public var groupLabel: String
    public var firstSeen: Double
    public var lastSeen: Double

    public init(key: String, kind: String, label: String, path: String, groupLabel: String,
                firstSeen: Double, lastSeen: Double) {
        self.key = key
        self.kind = kind
        self.label = label
        self.path = path
        self.groupLabel = groupLabel
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

/// The § H leak detector. Pure: no clock, no I/O; the caller passes wall time.
public struct LeakDetector: Sendable {
    public struct Flag: Sendable, Equatable {
        public var reason: String
        public var slopeMBPerHour: Double?
        public var baselineMB: Double?
        /// Frozen at the flag tick (fast flags).
        public var fastMin: UInt64?
    }

    struct Series: Sendable {
        var meta: SeriesMeta
        var pid: Int32?
        /// Closed buckets, oldest first.
        var closed: [Bucket] = []
        var open: Bucket?
        /// Base-tick samples within the fast-path window.
        var samples: [(t: Double, fp: UInt64)] = []
        var lastLifetimeMax: UInt64?
        var candidateStreak = 0
        var unflagStreak = 0
        var flag: Flag?
        var lastFootprint: UInt64 = 0
        var lastSlope: Double?
        var lastBaseline: Double?
    }

    public let config: DetectorConfig
    public let hwMemsize: UInt64
    private(set) var series: [String: Series] = [:]
    /// Buckets and first-seen loaded from history, waiting for their series to show up.
    private var preloaded: [String: (meta: SeriesMeta, buckets: [Bucket])] = [:]

    static let mib = 1_048_576.0

    public init(config: DetectorConfig, hwMemsize: UInt64) {
        self.config = config
        self.hwMemsize = hwMemsize
    }

    /// Loads the last 24 h of buckets so a relaunch keeps the detector's memory.
    public mutating func preload(meta: [SeriesMeta], buckets: [String: [Bucket]]) {
        for m in meta {
            preloaded[m.key] = (m, (buckets[m.key] ?? []).sorted { $0.start < $1.start })
        }
    }

    public var flags: [(key: String, flag: Flag, label: String, pid: Int32?, footprint: UInt64)] {
        series.values.compactMap { s in
            s.flag.map { (s.meta.key, $0, s.meta.label, s.pid, s.lastFootprint) }
        }.sorted { $0.key < $1.key }
    }

    public func meta(_ key: String) -> SeriesMeta? { series[key]?.meta }
    public var trackedKeys: [String] { Array(series.keys) }

    /// One base tick at wall time `t`.
    public mutating func tick(t: Double, observations: [SeriesObservation]) -> [DetectorEvent] {
        var events: [DetectorEvent] = []
        var seen = Set<String>()
        let bucketStart = floor(t / config.bucketSeconds) * config.bucketSeconds

        for o in observations {
            seen.insert(o.key)
            if series[o.key] == nil {
                guard Double(o.footprint) >= config.trackFloorMB * Self.mib else { continue }
                var s: Series
                if let pre = preloaded.removeValue(forKey: o.key) {
                    s = Series(meta: pre.meta, pid: o.pid)
                    s.closed = pre.buckets.filter { $0.start < bucketStart }
                } else {
                    s = Series(meta: SeriesMeta(key: o.key, kind: o.kind, label: o.label, path: o.path,
                                                groupLabel: o.groupLabel, firstSeen: t, lastSeen: t),
                               pid: o.pid)
                }
                series[o.key] = s
            }
            var s = series[o.key]!
            s.meta.label = o.label
            s.meta.groupLabel = o.groupLabel
            s.meta.lastSeen = t
            s.pid = o.pid
            s.lastFootprint = o.footprint

            // Bucket bookkeeping; a close evaluates the slope path.
            if let open = s.open, open.start != bucketStart {
                s.closed.append(open)
                s.open = nil
                events.append(.bucketClosed(key: o.key, bucket: open))
                events += onBucketClose(&s, closeTime: open.start + config.bucketSeconds, t: t)
            }
            var b = s.open ?? Bucket(start: bucketStart, min: o.footprint, max: o.footprint, count: 0)
            b.min = min(b.min, o.footprint)
            b.max = max(b.max, o.footprint)
            if let lm = o.lifetimeMax {
                if let prev = s.lastLifetimeMax, lm > prev { b.max = max(b.max, lm) }
                s.lastLifetimeMax = lm
            }
            b.count += 1
            s.open = b

            // Fast path (every base tick).
            s.samples.append((t, o.footprint))
            let keepFrom = t - config.fastPathWindowSeconds - 1
            if let i = s.samples.firstIndex(where: { $0.t >= keepFrom }), i > 0 { s.samples.removeFirst(i) }
            events += fastPath(&s, t: t)

            // Prune closed buckets beyond what any window needs.
            let horizon = max(config.baselineLookbackSeconds, config.slopeWindowSeconds) + config.bucketSeconds
            if let first = s.closed.first, first.start < t - horizon {
                let shortEnd = s.meta.firstSeen + config.baselineShortSeconds
                let keepShort = age(s) < config.baselineLongSeconds
                s.closed.removeAll { $0.start < t - horizon && !($0.start < shortEnd && keepShort) }
            }
            series[o.key] = s
        }

        // Series gone: drop from memory; a flagged one unflags.
        for key in series.keys where !seen.contains(key) {
            if let s = series[key], let f = s.flag {
                events.append(.unflag(FlagEvent(t: t, seriesKey: key, pid: s.pid, label: s.meta.label,
                                                footprint: s.lastFootprint, slopeMBPerHour: f.slopeMBPerHour,
                                                baselineMB: f.baselineMB, reason: f.reason)))
            }
            series.removeValue(forKey: key)
        }
        // Preloaded series that never showed up within a day are gone too.
        if !preloaded.isEmpty {
            preloaded = preloaded.filter { t - $0.value.meta.lastSeen < 86400 }
        }
        return events
    }

    // MARK: - § H pieces

    /// Series age: closed buckets holding ≥ 1 base-tick sample × bucketSeconds.
    func age(_ s: Series) -> Double {
        Double(s.closed.filter { $0.count > 0 }.count) * config.bucketSeconds
    }

    func baseline(_ s: Series, closeTime: Double) -> Double? {
        let a = age(s)
        if a >= config.baselineLongSeconds {
            let from = closeTime - config.baselineLookbackSeconds
            let mins = s.closed.filter { $0.start >= from }.map(\.min)
            return mins.min().map { Double($0) / Self.mib }
        }
        if a >= config.baselineShortSeconds {
            let end = s.meta.firstSeen + config.baselineShortSeconds
            let mins = s.closed.filter { $0.start < end }.map { Double($0.min) / Self.mib }
            return Self.median(mins)
        }
        return nil
    }

    /// The closed buckets inside the slope window ending at `closeTime`.
    func window(_ s: Series, closeTime: Double) -> [Bucket] {
        let from = closeTime - config.slopeWindowSeconds
        return s.closed.filter { $0.start >= from && $0.count > 0 }
    }

    /// Theil–Sen over bucket mins, MB per hour.
    public static func theilSen(_ buckets: [Bucket]) -> Double? {
        guard buckets.count >= 2 else { return nil }
        var slopes: [Double] = []
        slopes.reserveCapacity(buckets.count * (buckets.count - 1) / 2)
        for i in 0..<buckets.count {
            for j in (i + 1)..<buckets.count {
                let dt = buckets[j].start - buckets[i].start
                guard dt > 0 else { continue }
                let dmb = (Double(buckets[j].min) - Double(buckets[i].min)) / mib
                slopes.append(dmb / dt * 3600)
            }
        }
        return median(slopes)
    }

    /// Fraction of consecutive present-bucket steps that rise.
    public static func risingFraction(_ buckets: [Bucket]) -> Double {
        guard buckets.count >= 2 else { return 0 }
        var rising = 0
        for i in 1..<buckets.count where buckets[i].min > buckets[i - 1].min { rising += 1 }
        return Double(rising) / Double(buckets.count - 1)
    }

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    mutating func onBucketClose(_ s: inout Series, closeTime: Double, t: Double) -> [DetectorEvent] {
        guard let latest = s.closed.last else { return [] }
        let latestMinMB = Double(latest.min) / Self.mib
        let base = baseline(s, closeTime: closeTime)
        let w = window(s, closeTime: closeTime)
        let slope = w.count >= config.minBucketsInWindow ? Self.theilSen(w) : nil
        s.lastSlope = slope
        s.lastBaseline = base
        var events: [DetectorEvent] = []

        // Unflagging a slope flag.
        if let f = s.flag, f.reason == "slope" {
            if latestMinMB < config.floorMB {
                events.append(unflag(&s, t: t))
                return events
            }
            if let slope, slope < config.unflagSlopeMBPerHour {
                s.unflagStreak += 1
            } else {
                s.unflagStreak = 0
            }
            if s.unflagStreak >= config.confirmations {
                events.append(unflag(&s, t: t))
            }
            return events
        }

        // Candidate.
        var candidate = false
        if let base, let slope {
            let threshold = max(config.floorMB, config.baselineMultiplier * base)
            candidate = latestMinMB >= threshold
                && slope >= config.minSlopeMBPerHour
                && Self.risingFraction(w) >= config.risingFraction
        }
        s.candidateStreak = candidate ? s.candidateStreak + 1 : 0
        if s.flag == nil && s.candidateStreak >= config.confirmations {
            s.flag = Flag(reason: "slope", slopeMBPerHour: slope, baselineMB: base, fastMin: nil)
            s.unflagStreak = 0
            events.append(.flag(FlagEvent(t: t, seriesKey: s.meta.key, pid: s.pid, label: s.meta.label,
                                          footprint: s.lastFootprint, slopeMBPerHour: slope,
                                          baselineMB: base, reason: "slope")))
        }
        return events
    }

    mutating func fastPath(_ s: inout Series, t: Double) -> [DetectorEvent] {
        let threshold = config.fastPathFractionOfRAM * Double(hwMemsize)
        if let f = s.flag, f.reason == "fast", let fastMin = f.fastMin {
            // Clears when the latest sample is < fastMin + 0.5 × the threshold.
            if Double(s.lastFootprint) < Double(fastMin) + 0.5 * threshold {
                return [unflag(&s, t: t)]
            }
            return []
        }
        guard s.flag == nil else { return [] }
        let gateStart = s.meta.firstSeen + config.fastPathWindowSeconds
        guard t >= gateStart else { return [] }
        let from = max(t - config.fastPathWindowSeconds, gateStart)
        let window = s.samples.filter { $0.t >= from }
        guard window.count >= 2, let mn = window.map(\.fp).min(), let latest = window.last?.fp else { return [] }
        guard latest > mn, Double(latest - mn) >= threshold else { return [] }
        s.flag = Flag(reason: "fast", slopeMBPerHour: nil, baselineMB: s.lastBaseline, fastMin: mn)
        s.candidateStreak = 0
        return [.flag(FlagEvent(t: t, seriesKey: s.meta.key, pid: s.pid, label: s.meta.label,
                                footprint: latest, slopeMBPerHour: nil, baselineMB: s.lastBaseline,
                                reason: "fast"))]
    }

    mutating func unflag(_ s: inout Series, t: Double) -> DetectorEvent {
        let f = s.flag
        s.flag = nil
        s.unflagStreak = 0
        s.candidateStreak = 0
        return .unflag(FlagEvent(t: t, seriesKey: s.meta.key, pid: s.pid, label: s.meta.label,
                                 footprint: s.lastFootprint, slopeMBPerHour: f?.slopeMBPerHour ?? s.lastSlope,
                                 baselineMB: f?.baselineMB ?? s.lastBaseline, reason: f?.reason ?? "slope"))
    }

    /// The current flag of a series, if any.
    public func flag(_ key: String) -> Flag? { series[key]?.flag }
}
