import Foundation
import TickoalaCore

/// Builds a completed block, for the pure heatmap maths.
private func block(_ start: String, _ end: String) -> TimeEntry {
    TimeEntry(
        id: 0, profileId: 1, projectId: nil,
        startedAt: at(start), endedAt: at(end),
        status: .completed, source: .manual, note: nil,
        createdAt: at(start), updatedAt: at(start)
    )
}

func heatmapChecks() {
    suite("heatmap") {
        test("a block spreads its net time over the hours it covers") {
            // Monday 2026-01-05, 09:00–11:30, no break.
            let cells = Heatmap.cells(entries: [block("2026-01-05 09:00", "2026-01-05 11:30")])
            let byKey = Dictionary(uniqueKeysWithValues: cells.map { ($0.hour, $0.seconds) })
            expectEqual(cells.first?.weekday, 0, "Monday is index 0")
            expectEqual(byKey[9], 3600)
            expectEqual(byKey[10], 3600)
            expectEqual(byKey[11], 1800, "half an hour in the last hour")
            expectEqual(Heatmap.totalSeconds(cells), 2.5 * 3600)
        }

        test("Monday through Sunday map to 0 through 6") {
            expectEqual(Heatmap.mondayIndex(for: at("2026-01-05 10:00")), 0, "Monday")
            expectEqual(Heatmap.mondayIndex(for: at("2026-01-11 10:00")), 6, "Sunday")
        }

        test("a block over midnight lands on two weekdays") {
            let cells = Heatmap.cells(entries: [block("2026-01-05 23:00", "2026-01-06 01:00")])
            let monday = cells.filter { $0.weekday == 0 }.reduce(0) { $0 + $1.seconds }
            let tuesday = cells.filter { $0.weekday == 1 }.reduce(0) { $0 + $1.seconds }
            expectEqual(monday, 3600, "one hour on Monday")
            expectEqual(tuesday, 3600, "one hour on Tuesday")
            expectEqual(cells.first(where: { $0.weekday == 0 && $0.hour == 23 })?.seconds, 3600)
            expectEqual(cells.first(where: { $0.weekday == 1 && $0.hour == 0 })?.seconds, 3600)
        }

        test("a running block is measured up to now") {
            let entry = TimeEntry(
                id: 0, profileId: 1, projectId: nil,
                startedAt: at("2026-01-05 09:00"), endedAt: nil,
                status: .running, source: .manual, note: nil,
                createdAt: at("2026-01-05 09:00"), updatedAt: at("2026-01-05 09:00")
            )
            let cells = Heatmap.cells(entries: [entry], now: at("2026-01-05 10:30"))
            expectEqual(Heatmap.totalSeconds(cells), 1.5 * 3600)
        }

        test("a break lowers the time that is spread out") {
            var entry = block("2026-01-05 09:00", "2026-01-05 12:00")
            entry.breakStartedAt = at("2026-01-05 10:00")
            entry.breakEndedAt = at("2026-01-05 11:00")
            let cells = Heatmap.cells(entries: [entry])
            expectEqual(Heatmap.totalSeconds(cells), 2 * 3600, "three hours minus a one-hour break")
        }

        test("an empty set gives no cells") {
            expectEqual(Heatmap.cells(entries: []), [])
        }
    }
}
