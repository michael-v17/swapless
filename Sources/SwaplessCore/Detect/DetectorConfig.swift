import Foundation

/// Every number the leak detector uses (§ H). Codable and strict: a file must carry all 15 keys
/// and nothing else.
public struct DetectorConfig: Codable, Sendable, Equatable {
    public var bucketSeconds: Double
    public var trackFloorMB: Double
    public var baselineShortSeconds: Double
    public var baselineLongSeconds: Double
    public var baselineLookbackSeconds: Double
    public var floorMB: Double
    public var baselineMultiplier: Double
    public var slopeWindowSeconds: Double
    public var minBucketsInWindow: Int
    public var minSlopeMBPerHour: Double
    public var risingFraction: Double
    public var confirmations: Int
    public var unflagSlopeMBPerHour: Double
    public var fastPathFractionOfRAM: Double
    public var fastPathWindowSeconds: Double

    public static let defaults = DetectorConfig(
        bucketSeconds: 300, trackFloorMB: 50, baselineShortSeconds: 3600,
        baselineLongSeconds: 21600, baselineLookbackSeconds: 86400, floorMB: 500,
        baselineMultiplier: 3, slopeWindowSeconds: 7200, minBucketsInWindow: 12,
        minSlopeMBPerHour: 100, risingFraction: 0.7, confirmations: 2,
        unflagSlopeMBPerHour: 50, fastPathFractionOfRAM: 0.10, fastPathWindowSeconds: 300)

    public static let keys: [String] = [
        "bucketSeconds", "trackFloorMB", "baselineShortSeconds", "baselineLongSeconds",
        "baselineLookbackSeconds", "floorMB", "baselineMultiplier", "slopeWindowSeconds",
        "minBucketsInWindow", "minSlopeMBPerHour", "risingFraction", "confirmations",
        "unflagSlopeMBPerHour", "fastPathFractionOfRAM", "fastPathWindowSeconds",
    ]

    public struct DecodeError: Error, Equatable {
        public let message: String
    }

    public static func decodeStrict(_ data: Data) -> Result<DetectorConfig, DecodeError> {
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .failure(DecodeError(message: "not valid JSON"))
        }
        guard let dict = obj as? [String: Any] else {
            return .failure(DecodeError(message: "not a JSON object"))
        }
        let known = Set(keys)
        if let unknown = dict.keys.sorted().first(where: { !known.contains($0) }) {
            return .failure(DecodeError(message: "unknown key '\(unknown)'"))
        }
        if let missing = keys.first(where: { dict[$0] == nil }) {
            return .failure(DecodeError(message: "missing key '\(missing)'"))
        }
        func num(_ k: String) -> Double? {
            guard let d = JSONRead.double(dict[k]), d.isFinite, d > 0 else { return nil }
            return d
        }
        func int(_ k: String) -> Int? {
            guard let i = JSONRead.int(dict[k]), i >= 1 else { return nil }
            return i
        }
        var values: [String: Double] = [:]
        for k in keys where k != "minBucketsInWindow" && k != "confirmations" {
            guard let v = num(k) else {
                return .failure(DecodeError(message: "'\(k)' must be a positive number"))
            }
            values[k] = v
        }
        guard let minBuckets = int("minBucketsInWindow") else {
            return .failure(DecodeError(message: "'minBucketsInWindow' must be an integer ≥ 1"))
        }
        guard let confirmations = int("confirmations") else {
            return .failure(DecodeError(message: "'confirmations' must be an integer ≥ 1"))
        }
        guard values["risingFraction"]! <= 1, values["fastPathFractionOfRAM"]! <= 1 else {
            return .failure(DecodeError(message: "fractions must be ≤ 1"))
        }
        return .success(DetectorConfig(
            bucketSeconds: values["bucketSeconds"]!, trackFloorMB: values["trackFloorMB"]!,
            baselineShortSeconds: values["baselineShortSeconds"]!,
            baselineLongSeconds: values["baselineLongSeconds"]!,
            baselineLookbackSeconds: values["baselineLookbackSeconds"]!,
            floorMB: values["floorMB"]!, baselineMultiplier: values["baselineMultiplier"]!,
            slopeWindowSeconds: values["slopeWindowSeconds"]!, minBucketsInWindow: minBuckets,
            minSlopeMBPerHour: values["minSlopeMBPerHour"]!,
            risingFraction: values["risingFraction"]!, confirmations: confirmations,
            unflagSlopeMBPerHour: values["unflagSlopeMBPerHour"]!,
            fastPathFractionOfRAM: values["fastPathFractionOfRAM"]!,
            fastPathWindowSeconds: values["fastPathWindowSeconds"]!))
    }
}
