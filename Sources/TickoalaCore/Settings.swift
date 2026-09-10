import Foundation

/// Instelbare drempels. Worden in de `settings`-tabel bewaard.
public struct TrackerSettings: Equatable, Sendable {
    /// Wachttijd voordat een stop definitief wordt, zodat korte wifi-uitval niets afsluit.
    public var stopGraceSeconds: Int
    /// Tijdvenster waarbinnen identieke ControlPlane-events als herhaling gelden.
    public var dedupeWindowSeconds: Int
    /// Een lopend blok langer dan dit is niet geloofwaardig (slaapstand, crash) en vraagt om correctie.
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

    func value(for key: String) -> Int? {
        switch key {
        case "stop-grace-seconds": return stopGraceSeconds
        case "dedupe-window-seconds": return dedupeWindowSeconds
        case "max-entry-seconds": return maxEntrySeconds
        default: return nil
        }
    }

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
