import Foundation
import TickoalaCore

/// The automatic break deduction is a calculation on top of the raw blocks:
/// time entries are never modified by it.
func breakChecks() {
    suite("Automatic break deduction") {
        /// Records one completed block of `hours` hours on the given day.
        @discardableResult
        func workday(_ fixture: Fixture, _ profile: Profile, _ day: String, hours: Double) throws -> TimeEntry {
            let start = at("\(day) 09:00")
            return try fixture.store.createEntry(
                profileId: profile.id, projectId: nil,
                startedAt: start, endedAt: start.addingTimeInterval(hours * 3600),
                status: .completed, source: .controlplane, note: nil
            )
        }

        func dayReport(_ fixture: Fixture, _ profile: Profile, _ day: String) throws -> Report {
            try Reporting.report(
                store: fixture.store, period: .day, containing: at(day),
                profileId: profile.id, now: at("\(day) 23:00")
            )
        }

        test("by default the deduction is off") {
            let fixture = try Fixture()
            expectEqual(fixture.profileA.breakRule.enabled, false)
            try workday(fixture, fixture.profileA, "2026-09-10", hours: 8)

            let report = try dayReport(fixture, fixture.profileA, "2026-09-10")
            expectEqual(report.breakDeduction, 0)
            expectEqual(report.netTotal, 8 * 3600, "without the rule nothing changes")
        }

        test("from the threshold the break is deducted") {
            let fixture = try Fixture()
            try fixture.store.updateBreakRule(
                profileId: fixture.profileA.id,
                rule: BreakRule(enabled: true, minutes: 30, thresholdMinutes: 360)
            )
            try workday(fixture, fixture.profileA, "2026-09-10", hours: 8)

            let report = try dayReport(fixture, fixture.profileA, "2026-09-10")
            expectEqual(report.total, 8 * 3600, "gross stays 8 hours")
            expectEqual(report.breakDeduction, 30 * 60)
            expectEqual(report.netTotal, 7.5 * 3600)
        }

        test("the threshold is inclusive: exactly 6 hours is already enough") {
            let fixture = try Fixture()
            try fixture.store.updateBreakRule(
                profileId: fixture.profileA.id,
                rule: BreakRule(enabled: true, minutes: 30, thresholdMinutes: 360)
            )
            try workday(fixture, fixture.profileA, "2026-09-10", hours: 6)

            expectEqual(try dayReport(fixture, fixture.profileA, "2026-09-10").breakDeduction, 30 * 60)
        }

        test("below the threshold nothing is deducted") {
            let fixture = try Fixture()
            try fixture.store.updateBreakRule(
                profileId: fixture.profileA.id,
                rule: BreakRule(enabled: true, minutes: 30, thresholdMinutes: 360)
            )
            try workday(fixture, fixture.profileA, "2026-09-10", hours: 5.75)

            let report = try dayReport(fixture, fixture.profileA, "2026-09-10")
            expectEqual(report.breakDeduction, 0)
            expectEqual(report.netTotal, 5.75 * 3600)
        }

        test("the deduction applies per day, not per block") {
            let fixture = try Fixture()
            try fixture.store.updateBreakRule(
                profileId: fixture.profileA.id,
                rule: BreakRule(enabled: true, minutes: 30, thresholdMinutes: 360)
            )
            // Two blocks on one day, 8 hours together: one break deducted.
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 08:00"), endedAt: at("2026-09-10 12:00"),
                status: .completed, source: .controlplane, note: nil
            )
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 13:00"), endedAt: at("2026-09-10 17:00"),
                status: .completed, source: .controlplane, note: nil
            )

            let report = try dayReport(fixture, fixture.profileA, "2026-09-10")
            expectEqual(report.breakDeduction, 30 * 60, "one break per day")
            expectEqual(report.netTotal, 7.5 * 3600)
        }

        test("every customer has its own rule") {
            let fixture = try Fixture()
            try fixture.store.updateBreakRule(
                profileId: fixture.profileA.id,
                rule: BreakRule(enabled: true, minutes: 30, thresholdMinutes: 360)
            )
            try fixture.store.updateBreakRule(
                profileId: fixture.profileB.id,
                rule: BreakRule(enabled: true, minutes: 60, thresholdMinutes: 240)
            )
            try workday(fixture, fixture.profileA, "2026-09-10", hours: 8)
            try workday(fixture, fixture.profileB, "2026-09-10", hours: 8)

            expectEqual(try dayReport(fixture, fixture.profileA, "2026-09-10").breakDeduction, 30 * 60)
            expectEqual(try dayReport(fixture, fixture.profileB, "2026-09-10").breakDeduction, 60 * 60)

            // Without a profile filter both rules count.
            let combined = try Reporting.report(
                store: fixture.store, period: .day, containing: at("2026-09-10"), now: at("2026-09-10 23:00")
            )
            expectEqual(combined.total, 16 * 3600)
            expectEqual(combined.breakDeduction, 90 * 60)
            expectEqual(combined.netTotal, 14.5 * 3600)
        }

        test("a disabled rule no longer counts, even retroactively") {
            let fixture = try Fixture()
            try fixture.store.updateBreakRule(
                profileId: fixture.profileA.id,
                rule: BreakRule(enabled: true, minutes: 30, thresholdMinutes: 360)
            )
            try workday(fixture, fixture.profileA, "2026-09-10", hours: 8)
            expectEqual(try dayReport(fixture, fixture.profileA, "2026-09-10").netTotal, 7.5 * 3600)

            try fixture.store.updateBreakRule(
                profileId: fixture.profileA.id,
                rule: BreakRule(enabled: false, minutes: 30, thresholdMinutes: 360)
            )
            expectEqual(try dayReport(fixture, fixture.profileA, "2026-09-10").netTotal, 8 * 3600,
                        "the source data was never modified")
        }

        test("the weekly report deducts per day") {
            let fixture = try Fixture()
            try fixture.store.updateBreakRule(
                profileId: fixture.profileA.id,
                rule: BreakRule(enabled: true, minutes: 30, thresholdMinutes: 360)
            )
            try workday(fixture, fixture.profileA, "2026-09-07", hours: 8)   // Monday
            try workday(fixture, fixture.profileA, "2026-09-08", hours: 8)   // Tuesday
            try workday(fixture, fixture.profileA, "2026-09-09", hours: 3)   // Wednesday, below the threshold

            let week = try Reporting.report(
                store: fixture.store, period: .week, containing: at("2026-09-08"),
                profileId: fixture.profileA.id, now: at("2026-09-13 23:00")
            )
            expectEqual(week.total, 19 * 3600)
            expectEqual(week.breakDeduction, 60 * 60, "two days above the threshold")
            expectEqual(week.netTotal, 18 * 3600)
            expectEqual(week.byDay.count, 3)
            expectEqual(week.byDay.last?.breakDeduction, 0, "the short Wednesday stays whole")
        }

        test("it never deducts more than was worked") {
            let fixture = try Fixture()
            try fixture.store.updateBreakRule(
                profileId: fixture.profileA.id,
                rule: BreakRule(enabled: true, minutes: 60, thresholdMinutes: 0)
            )
            try workday(fixture, fixture.profileA, "2026-09-10", hours: 0.25)

            let report = try dayReport(fixture, fixture.profileA, "2026-09-10")
            expectEqual(report.netTotal, 0, "the day does not go negative")
            expectEqual(report.breakDeduction, 15 * 60)
        }

        test("the menu bar shows net daily and weekly totals") {
            let fixture = try Fixture()
            try fixture.store.updateBreakRule(
                profileId: fixture.profileA.id,
                rule: BreakRule(enabled: true, minutes: 30, thresholdMinutes: 360)
            )
            try workday(fixture, fixture.profileA, "2026-09-10", hours: 8)

            let status = try fixture.tracker.status(now: at("2026-09-10 18:00"))
            let row = try expectNotNil(status.profiles.first(where: { $0.profile.id == fixture.profileA.id }))
            expectEqual(row.todayTotal, 7.5 * 3600, "net")
            expectEqual(row.todayBreak, 30 * 60)
            expectEqual(row.todayRaw, 8 * 3600, "gross stays retrievable")
        }

        test("export puts the break as a separate row with a negative duration") {
            let fixture = try Fixture()
            try fixture.store.updateBreakRule(
                profileId: fixture.profileA.id,
                rule: BreakRule(enabled: true, minutes: 30, thresholdMinutes: 360)
            )
            try workday(fixture, fixture.profileA, "2026-09-10", hours: 8)

            let csv = try CSVExport.export(
                store: fixture.store, from: at("2026-09-10"), to: at("2026-09-11"), now: at("2026-09-10 23:00")
            )
            let rows = csv.split(separator: "\n").map(String.init)
            expectEqual(rows.count, 3, "header row, the block and the break row")
            expect(rows[2].contains("-0.50"), "negative duration: \(rows[2])")
            expect(rows[2].contains("break,rule"), "status and source: \(rows[2])")

            let gross = try CSVExport.export(
                store: fixture.store, from: at("2026-09-10"), to: at("2026-09-11"),
                now: at("2026-09-10 23:00"), includeBreaks: false
            )
            expectEqual(gross.split(separator: "\n").count, 2, "with gross only the blocks remain")
        }
    }
}
