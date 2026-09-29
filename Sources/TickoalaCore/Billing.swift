import Foundation

/// Turns the recorded work blocks into the extra time the billing rules call
/// evening or weekend. It only reads the entries; the recorded time itself is
/// never changed, so the rules can be set or cleared at any moment.
public enum Billing {
    /// Seconds of work that fall in the evening (weekdays after `eveningStartMinutes`)
    /// and on a weekend. Weekends win over the evening: a Saturday hour is weekend,
    /// not both. The recorded break is ignored here, because it is small and the
    /// surcharge is a percentage of the hours anyway.
    // ponytail: break is not apportioned over evening/weekend; refine if a client disputes a few minutes.
    public static func surchargeSeconds(
        entries: [TimeEntry],
        rules: BillingRules,
        now: Date = Date(),
        calendar: Calendar = Formatting.calendar
    ) -> (evening: TimeInterval, weekend: TimeInterval) {
        guard rules.isActive else { return (0, 0) }
        var evening: TimeInterval = 0
        var weekend: TimeInterval = 0
        for entry in entries where entry.kind == .work {
            let start = entry.startedAt
            let end = entry.endedAt ?? (entry.status == .running ? now : entry.startedAt)
            guard end > start else { continue }
            var day = calendar.startOfDay(for: start)
            while day < end {
                guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                let segmentStart = max(start, day)
                let segmentEnd = min(end, dayEnd)
                if segmentEnd > segmentStart {
                    if calendar.isDateInWeekend(day) {
                        weekend += segmentEnd.timeIntervalSince(segmentStart)
                    } else if let eveningStart = calendar.date(byAdding: .minute, value: rules.eveningStartMinutes, to: day) {
                        let from = max(segmentStart, eveningStart)
                        if segmentEnd > from { evening += segmentEnd.timeIntervalSince(from) }
                    }
                }
                day = dayEnd
            }
        }
        return (evening, weekend)
    }
}
