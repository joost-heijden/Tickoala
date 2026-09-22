import Foundation

/// Configurable thresholds. Stored in the `settings` table.
public struct TrackerSettings: Equatable, Sendable {
    /// Time window within which identical ControlPlane events count as a repeat.
    public var dedupeWindowSeconds: Int
    /// A running block longer than this is not credible (sleep, crash) and needs correction.
    public var maxEntrySeconds: Int
    /// Minutes since midnight at which the workday ends. A block that saw a stop
    /// signal or that never got a signal is closed here instead of running into
    /// the night; it is the default last moment of the day.
    public var workdayEndMinutes: Int

    public static let `default` = TrackerSettings(
        dedupeWindowSeconds: 30,
        maxEntrySeconds: 16 * 3600,
        workdayEndMinutes: 18 * 60
    )

    public init(dedupeWindowSeconds: Int, maxEntrySeconds: Int, workdayEndMinutes: Int = 18 * 60) {
        self.dedupeWindowSeconds = dedupeWindowSeconds
        self.maxEntrySeconds = maxEntrySeconds
        self.workdayEndMinutes = workdayEndMinutes
    }

    static let keys = ["dedupe-window-seconds", "max-entry-seconds", "workday-end-minutes"]

    mutating func set(_ key: String, _ value: Int) -> Bool {
        switch key {
        case "dedupe-window-seconds": dedupeWindowSeconds = value
        case "max-entry-seconds": maxEntrySeconds = value
        case "workday-end-minutes": workdayEndMinutes = min(max(0, value), 24 * 60)
        default: return false
        }
        return true
    }

    /// The configured end of the workday on the day of `date`.
    public func endOfWorkday(for date: Date) -> Date {
        let calendar = Formatting.calendar
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .minute, value: workdayEndMinutes, to: start) ?? start
    }
}
