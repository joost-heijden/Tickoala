import Foundation
import TickoalaCore

func holidayChecks() {
    suite("Holidays and vacation") {
        test("a non-working day is stored, listed and removed") {
            let fixture = try Fixture()
            expect(try fixture.store.nonWorkingDays().isEmpty, "none by default")
            try fixture.store.addNonWorkingDay(at("2026-12-25"), label: "Christmas", kind: .holiday)
            try fixture.store.addNonWorkingDay(at("2026-12-26"), label: "", kind: .vacation)

            let days = try fixture.store.nonWorkingDays()
            expectEqual(days.count, 2)
            expectEqual(days.first?.label, "Christmas")
            expectEqual(days.last?.kind, .vacation)
            expectEqual(days.last?.display, "Vacation", "an empty label falls back to the kind")

            try fixture.store.deleteNonWorkingDay(at("2026-12-25"))
            expectEqual(try fixture.store.nonWorkingDays().count, 1)
        }

        test("a stop is final right away on a holiday, not held to the workday end") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")
            _ = try fixture.event("Office A", .stop, "2026-09-10 12:00")

            try fixture.store.addNonWorkingDay(at("2026-09-10"), label: "Holiday", kind: .holiday)
            let closed = try fixture.tracker.finalizePendingStops(now: at("2026-09-10 13:00"))
            expectEqual(closed.count, 1, "closed on the holiday itself")
            expectEqual(closed.first?.endedAt, at("2026-09-10 12:00"), "at the stop moment")
        }

        test("without a holiday the same stop waits for the workday end") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")
            _ = try fixture.event("Office A", .stop, "2026-09-10 12:00")

            let early = try fixture.tracker.finalizePendingStops(now: at("2026-09-10 13:00"))
            expectEqual(early.count, 0, "still running until the workday ends")
        }

        test("a block left running on a holiday closes at the end of that day") {
            let fixture = try Fixture()
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 09:00"), endedAt: nil,
                status: .running, source: .manual, note: nil
            )
            try fixture.store.addNonWorkingDay(at("2026-09-10"), label: "Holiday", kind: .holiday)

            let closed = try fixture.tracker.closeBlocksPastWorkday(now: at("2026-09-11 00:30"))
            expectEqual(closed.count, 1)
            expectEqual(closed.first?.endedAt, at("2026-09-11 00:00"), "end of the holiday, not the workday end")
        }
    }
}
