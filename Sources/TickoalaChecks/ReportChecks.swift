import Foundation
import TickoalaCore

func reportChecks() {
    suite("Totals and export") {
        /// Monday 7 September 2026 through Thursday 10 September 2026.
        func filledWeek() throws -> Fixture {
            let fixture = try Fixture()
            let migration = try fixture.project(fixture.profileA, number: "2401", name: "Migration")
            let maintenance = try fixture.store.createProject(profileId: fixture.profileA.id, number: "2402", name: "Maintenance")
            _ = try fixture.store.createEntry(profileId: fixture.profileA.id, projectId: migration.id,
                                              startedAt: at("2026-09-07 09:00"), endedAt: at("2026-09-07 17:00"),
                                              status: .completed, source: .controlplane, note: nil)
            _ = try fixture.store.createEntry(profileId: fixture.profileA.id, projectId: migration.id,
                                              startedAt: at("2026-09-10 09:00"), endedAt: at("2026-09-10 12:00"),
                                              status: .completed, source: .controlplane, note: nil)
            _ = try fixture.store.createEntry(profileId: fixture.profileA.id, projectId: maintenance.id,
                                              startedAt: at("2026-09-10 13:00"), endedAt: at("2026-09-10 15:30"),
                                              status: .completed, source: .manual, note: "correction, comma and \"quotes\"")
            // Another organization, same day: must not touch A's totals.
            let projectB = try fixture.project(fixture.profileB, number: "B-1", name: "Other work")
            _ = try fixture.store.createEntry(profileId: fixture.profileB.id, projectId: projectB.id,
                                              startedAt: at("2026-09-10 16:00"), endedAt: at("2026-09-10 17:00"),
                                              status: .completed, source: .controlplane, note: nil)
            return fixture
        }

        test("a daily total counts only that day and that profile") {
            let fixture = try filledWeek()
            let report = try Reporting.report(store: fixture.store, period: .day, containing: at("2026-09-10"),
                                              profileId: fixture.profileA.id, now: at("2026-09-10 18:00"))
            expectEqual(report.total, 5.5 * 3600, "3 hours plus 2.5 hours")
            expectEqual(report.byProject.count, 2)
            expectEqual(report.byProject.first?.label, "2401 — Migration", "largest project first")
        }

        test("a weekly total runs from Monday through Sunday") {
            let fixture = try filledWeek()
            let report = try Reporting.report(store: fixture.store, period: .week, containing: at("2026-09-10"),
                                              profileId: fixture.profileA.id, now: at("2026-09-10 18:00"))
            expectEqual(report.range.start, at("2026-09-07 00:00"), "the week begins on Monday")
            expectEqual(report.total, 13.5 * 3600, "8 hours plus 5.5 hours")
            expectEqual(report.byDay.count, 2, "two worked days")
        }

        test("a monthly total counts both organizations when no profile is chosen") {
            let fixture = try filledWeek()
            let report = try Reporting.report(store: fixture.store, period: .month, containing: at("2026-09-10"),
                                              now: at("2026-09-30 18:00"))
            expectEqual(report.total, 14.5 * 3600, "13.5 hours from A plus 1 hour from B")
            expectEqual(report.range.start, at("2026-09-01 00:00"))
            expectEqual(report.range.end, at("2026-10-01 00:00"))
        }

        test("a running block counts up to now") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")

            let report = try Reporting.report(store: fixture.store, period: .day, containing: at("2026-09-10"),
                                              now: at("2026-09-10 11:30"))
            expectEqual(report.total, 2.5 * 3600)
            expectEqual(report.runningCount, 1)
        }

        test("export produces one row per block with readable fields") {
            let fixture = try filledWeek()
            let csv = try CSVExport.export(store: fixture.store, from: at("2026-09-10"), to: at("2026-09-11"),
                                           profileId: fixture.profileA.id, now: at("2026-09-10 18:00"))
            let rows = csv.split(separator: "\n").map(String.init)

            expectEqual(rows.count, 3, "header row plus two blocks")
            expect(rows[0].hasPrefix("id,profile,context,project_number,project_name,date,start,end"), "header row: \(rows[0])")
            expect(rows[1].contains("2401,Migration,2026-09-10,09:00,12:00,3.00,180,0.00,0.00,EUR"), "block row: \(rows[1])")
            expect(rows[2].contains("\"correction, comma and \"\"quotes\"\"\""), "commas and quotes are escaped: \(rows[2])")
        }

        test("exporting an open block leaves the end empty but names the status") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")
            try fixture.tracker.tick(now: at("2026-09-11 09:00"))

            let csv = try CSVExport.export(store: fixture.store, from: at("2026-09-10"), to: at("2026-09-11"),
                                           now: at("2026-09-11 09:00"))
            let row = csv.split(separator: "\n").map(String.init)[1]

            expect(row.contains(",09:00,,"), "no end time: \(row)")
            expect(row.hasSuffix("open,controlplane,"), "status and source are named: \(row)")
        }

        test("a reversed time window is refused") {
            let fixture = try Fixture()
            expectThrows({
                _ = try CSVExport.export(store: fixture.store, from: at("2026-09-11"), to: at("2026-09-10"))
            })
        }

        test("duration is shown as hours:minutes and as decimal hours") {
            expectEqual(Formatting.duration(0), "0:00")
            expectEqual(Formatting.duration(59), "0:00", "the clock only ticks over after a full minute")
            expectEqual(Formatting.duration(3 * 3600 + 25 * 60), "3:25")
            expectEqual(Formatting.duration(-10), "0:00", "never negative")
            expectEqual(Formatting.decimalHours(5.5 * 3600), "5.50")
        }
    }
}
