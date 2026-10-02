import Foundation
import TickoalaCore

func weeklyChecks() {
    suite("weekly review") {
        test("the review covers the week before the given day") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10_000)
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-01-06 09:00"), endedAt: at("2026-01-06 11:00"),
                status: .completed, source: .manual, note: nil
            )
            let summary = try WeeklySummary.make(
                store: fixture.store, weekContaining: at("2026-01-12 09:00")
            )
            expectEqual(summary.range.start, at("2026-01-05"), "the Monday of the week before")
            expectEqual(summary.report.netTotal, 2 * 3600)
        }

        test("the body names the client, the hours and the amount") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10_000)
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-01-06 09:00"), endedAt: at("2026-01-06 11:00"),
                status: .completed, source: .manual, note: nil
            )
            let summary = try WeeklySummary.make(
                store: fixture.store, weekContaining: at("2026-01-12 09:00")
            )
            expect(summary.body.contains("Organization A"), "names the client")
            expect(summary.body.contains("2:00"), "shows the net hours")
            expect(summary.body.contains("€200.00"), "shows the amount")
            expectEqual(summary.totalAmount?.cents, 20_000)
        }

        test("the notification line is short") {
            let fixture = try Fixture()
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-01-06 09:00"), endedAt: at("2026-01-06 11:00"),
                status: .completed, source: .manual, note: nil
            )
            let summary = try WeeklySummary.make(
                store: fixture.store, weekContaining: at("2026-01-12 09:00")
            )
            expectEqual(summary.notificationText, "Last week 2:00 net · 1 client")
        }

        test("an empty week has no amount and only the hours") {
            let fixture = try Fixture()
            let summary = try WeeklySummary.make(
                store: fixture.store, weekContaining: at("2026-01-12 09:00")
            )
            expectEqual(summary.report.total, 0)
            expect(summary.totalAmount == nil, "no clients, so no amount")
            expect(summary.body.contains("0:00"), "still renders the zero hours")
        }
    }
}
