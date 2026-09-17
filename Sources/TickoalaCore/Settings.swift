import Foundation

/// Configurable thresholds. Stored in the `settings` table.
public struct TrackerSettings: Equatable, Sendable {
    /// Time window within which identical ControlPlane events count as a repeat.
    public var dedupeWindowSeconds: Int
    /// A running block longer than this is not credible (sleep, crash) and needs correction.
    public var maxEntrySeconds: Int

    public static let `default` = TrackerSettings(
        dedupeWindowSeconds: 30,
        maxEntrySeconds: 16 * 3600
    )

    public init(dedupeWindowSeconds: Int, maxEntrySeconds: Int) {
        self.dedupeWindowSeconds = dedupeWindowSeconds
        self.maxEntrySeconds = maxEntrySeconds
    }

    static let keys = ["dedupe-window-seconds", "max-entry-seconds"]

    mutating func set(_ key: String, _ value: Int) -> Bool {
        switch key {
        case "dedupe-window-seconds": dedupeWindowSeconds = value
        case "max-entry-seconds": maxEntrySeconds = value
        default: return false
        }
        return true
    }
}
