import Foundation

/// One cell of the when-do-I-work heatmap: a weekday and an hour of the day,
/// with how much net work fell in it over the shown period.
public struct HeatmapCell: Equatable, Sendable {
    /// 0 = Monday … 6 = Sunday, so the grid reads the way a work week does.
    public var weekday: Int
    /// Hour of the day, 0–23.
    public var hour: Int
    /// Net seconds worked in this cell (break and discarded idle already off).
    public var seconds: TimeInterval

    public init(weekday: Int, hour: Int, seconds: TimeInterval) {
        self.weekday = weekday
        self.hour = hour
        self.seconds = seconds
    }
}

/// Turns blocks into a weekday × hour grid, spreading each block's net time over
/// the hours it actually covers. A 09:00–11:30 block adds an hour to 09:00, an
/// hour to 10:00 and half an hour to 11:00. Purely a calculation on top of the
/// recorded blocks, so nothing is changed.
public enum Heatmap {
    /// Net seconds per (weekday, hour) over the given blocks. `now` closes a
    /// running block. Only cells with time appear.
    public static func cells(
        entries: [TimeEntry],
        now: Date = Date(),
        calendar: Calendar = Formatting.calendar
    ) -> [HeatmapCell] {
        var buckets: [Int: TimeInterval] = [:]

        for entry in entries {
            let end = entry.endedAt ?? (entry.status == .running ? now : entry.startedAt)
            let span = end.timeIntervalSince(entry.startedAt)
            guard span > 0 else { continue }
            let net = entry.duration(now: now)
            guard net > 0 else { continue }

            // Walk the block hour by hour and share its net time by overlap.
            var cursor = entry.startedAt
            while cursor < end {
                let next = min(cursor.roundedToHour(calendar), end)
                let overlap = next.timeIntervalSince(cursor)
                guard overlap > 0 else { break }
                let weekday = mondayIndex(for: cursor, calendar: calendar)
                let hour = calendar.component(.hour, from: cursor)
                buckets[weekday * 24 + hour, default: 0] += net * (overlap / span)
                cursor = next
            }
        }

        return buckets
            .map { key, seconds in
                HeatmapCell(weekday: key / 24, hour: key % 24, seconds: seconds)
            }
            .sorted { ($0.weekday, $0.hour) < ($1.weekday, $1.hour) }
    }

    /// 0 = Monday … 6 = Sunday. Calendar's weekday is 1 = Sunday … 7 = Saturday.
    public static func mondayIndex(for date: Date, calendar: Calendar = Formatting.calendar) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7
    }

    /// The total net seconds in a set of cells, for a sanity check or a header.
    public static func totalSeconds(_ cells: [HeatmapCell]) -> TimeInterval {
        cells.reduce(0) { $0 + $1.seconds }
    }
}

private extension Date {
    /// The next whole hour at or after this moment, in the given calendar.
    func roundedToHour(_ calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: self)
        let seconds = timeIntervalSince(start)
        let next = (seconds / 3600).rounded(.down) * 3600 + 3600
        return start.addingTimeInterval(next)
    }
}
