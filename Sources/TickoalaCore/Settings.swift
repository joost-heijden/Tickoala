import Foundation

/// Configurable thresholds. Stored in the `settings` table.
public struct TrackerSettings: Equatable, Sendable {
    /// Grace period before a stop becomes final, so a brief Wi-Fi dropout doesn't close anything.
    public var stopGraceSeconds: Int
    /// Time window within which identical ControlPlane events count as a repeat.
    public var dedupeWindowSeconds: Int
    /// A running block longer than this is not credible (sleep, crash) and needs correction.
    public var maxEntrySeconds: Int

    public static let `default` = TrackerSettings(
        stopGraceSeconds: 90,
        dedupeWindowSeconds: 30,
        maxEntrySeconds: 16 * 3600
    )

    public init(stopGraceSeconds: Int, dedupeWindowSeconds: Int, maxEntrySeconds: Int) {
        self.stopGraceSeconds = stopGraceSeconds
        self.dedupeWindowSeconds = dedupeWindowSeconds
        self.maxEntrySeconds = maxEntrySeconds
    }

    static let keys = ["stop-grace-seconds", "dedupe-window-seconds", "max-entry-seconds"]

    mutating func set(_ key: String, _ value: Int) -> Bool {
        switch key {
        case "stop-grace-seconds": stopGraceSeconds = value
        case "dedupe-window-seconds": dedupeWindowSeconds = value
        case "max-entry-seconds": maxEntrySeconds = value
        default: return false
        }
        return true
    }
}
