import Foundation
import TickoalaCore

func travelChecks() {
    suite("Travel time") {
        test("a block remembers whether it is work, travel or commute") {
            let fixture = try Fixture()
            let entry = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 08:00"), endedAt: at("2026-09-10 09:00"),
                status: .completed, source: .manual, kind: .travel, note: nil
            )
            expectEqual(entry.kind, .travel)
            expectEqual(try fixture.store.entry(id: entry.id)?.kind, .travel, "reads back as travel")
        }

        test("the report keeps work, travel and commute apart") {
            let fixture = try Fixture()
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 09:00"), endedAt: at("2026-09-10 13:00"),
                status: .completed, source: .manual, kind: .work, note: nil
            )
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 13:00"), endedAt: at("2026-09-10 15:00"),
                status: .completed, source: .manual, kind: .travel, note: nil
            )
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 15:00"), endedAt: at("2026-09-10 15:30"),
                status: .completed, source: .manual, kind: .commute, note: nil
            )
            let report = try Reporting.report(
                store: fixture.store, period: .day, containing: at("2026-09-10")
            )
            expectEqual(report.byKind[.work], 4 * 3600)
            expectEqual(report.byKind[.travel], 2 * 3600)
            expectEqual(report.byKind[.commute], 30 * 60)
        }

        test("the automatic break comes off work, not off travel") {
            let fixture = try Fixture()
            try fixture.store.updateBreakRule(
                profileId: fixture.profileA.id,
                rule: BreakRule(enabled: true, minutes: 30, thresholdMinutes: 360)
            )
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 09:00"), endedAt: at("2026-09-10 17:00"),
                status: .completed, source: .manual, kind: .work, note: nil
            )
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 17:00"), endedAt: at("2026-09-10 19:00"),
                status: .completed, source: .manual, kind: .travel, note: nil
            )
            let report = try Reporting.report(
                store: fixture.store, period: .day, containing: at("2026-09-10")
            )
            expectEqual(report.byKind[.work], 7.5 * 3600, "8 hours minus the 30-minute break")
            expectEqual(report.byKind[.travel], 2 * 3600, "travel is untouched by the break")
        }

        test("the commute is not billed without its own rate, travel falls back to hourly") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10000)
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 09:00"), endedAt: at("2026-09-10 17:00"),
                status: .completed, source: .manual, kind: .work, note: nil
            )
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 17:00"), endedAt: at("2026-09-10 19:00"),
                status: .completed, source: .manual, kind: .travel, note: nil
            )
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 19:00"), endedAt: at("2026-09-10 20:00"),
                status: .completed, source: .manual, kind: .commute, note: nil
            )
            let invoice = try Invoicing.invoice(
                store: fixture.store, profileId: fixture.profileA.id,
                period: DateRange(start: at("2026-09-10"), end: at("2026-09-11"))
            )
            expectEqual(invoice.subtotalCents, 80000 + 20000, "8h work plus 2h travel, commute excluded")
            expect(invoice.lines.contains { $0.label == "Travel time" && $0.amountCents == 20000 }, "travel is its own line")
            expect(invoice.lines.allSatisfy { $0.label != "Commute" }, "the unbilled commute stays off the invoice")
        }

        test("a client travel rate and commute rate are used when set") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(
                id: fixture.profileA.id, hourlyRateCents: 10000,
                travelRateCents: 5000, commuteRateCents: 2500
            )
            let loaded = try expectNotNil(try fixture.store.profile(id: fixture.profileA.id))
            expectEqual(loaded.rateCents(for: .travel), 5000)
            expectEqual(loaded.rateCents(for: .commute), 2500)
            expectEqual(loaded.rateCents(for: .work), 10000)

            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 07:00"), endedAt: at("2026-09-10 08:00"),
                status: .completed, source: .manual, kind: .commute, note: nil
            )
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 08:00"), endedAt: at("2026-09-10 10:00"),
                status: .completed, source: .manual, kind: .travel, note: nil
            )
            let invoice = try Invoicing.invoice(
                store: fixture.store, profileId: fixture.profileA.id,
                period: DateRange(start: at("2026-09-10"), end: at("2026-09-11"))
            )
            expectEqual(invoice.subtotalCents, 2500 + 10000, "1h commute at €25 plus 2h travel at €50")
            expect(invoice.lines.contains { $0.label == "Commute" && $0.amountCents == 2500 })
            expect(invoice.lines.contains { $0.label == "Travel time" && $0.amountCents == 10000 })
        }

        test("travel blocks do not count towards a project budget") {
            let fixture = try Fixture()
            let project = try fixture.project(fixture.profileA)
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: project.id,
                startedAt: at("2026-09-10 09:00"), endedAt: at("2026-09-10 11:00"),
                status: .completed, source: .manual, kind: .work, note: nil
            )
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: project.id,
                startedAt: at("2026-09-10 11:00"), endedAt: at("2026-09-10 13:00"),
                status: .completed, source: .manual, kind: .travel, note: nil
            )
            let usage = try fixture.store.projectUsageSeconds()
            expectEqual(usage[project.id], 2 * 3600, "only the work hours count")
        }
    }
}
