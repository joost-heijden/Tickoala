import Foundation
import TickoalaCore

func reportChecks() {
    suite("Totalen en export") {
        /// Maandag 7 september 2026 t/m donderdag 10 september 2026.
        func gevuldeWeek() throws -> Fixture {
            let fixture = try Fixture()
            let migratie = try fixture.project(fixture.profileA, number: "2401", name: "Migratie")
            let onderhoud = try fixture.store.createProject(profileId: fixture.profileA.id, number: "2402", name: "Onderhoud")
            _ = try fixture.store.createEntry(profileId: fixture.profileA.id, projectId: migratie.id,
                                              startedAt: at("2026-09-07 09:00"), endedAt: at("2026-09-07 17:00"),
                                              status: .completed, source: .controlplane, note: nil)
            _ = try fixture.store.createEntry(profileId: fixture.profileA.id, projectId: migratie.id,
                                              startedAt: at("2026-09-10 09:00"), endedAt: at("2026-09-10 12:00"),
                                              status: .completed, source: .controlplane, note: nil)
            _ = try fixture.store.createEntry(profileId: fixture.profileA.id, projectId: onderhoud.id,
                                              startedAt: at("2026-09-10 13:00"), endedAt: at("2026-09-10 15:30"),
                                              status: .completed, source: .manual, note: "correctie, komma en \"aanhalingstekens\"")
            // Andere organisatie, zelfde dag: mag de totalen van A niet raken.
            let projectB = try fixture.project(fixture.profileB, number: "B-1", name: "Ander werk")
            _ = try fixture.store.createEntry(profileId: fixture.profileB.id, projectId: projectB.id,
                                              startedAt: at("2026-09-10 16:00"), endedAt: at("2026-09-10 17:00"),
                                              status: .completed, source: .controlplane, note: nil)
            return fixture
        }

        test("dagtotaal telt alleen die dag en dat profiel") {
            let fixture = try gevuldeWeek()
            let rapport = try Reporting.report(store: fixture.store, period: .day, containing: at("2026-09-10"),
                                               profileId: fixture.profileA.id, now: at("2026-09-10 18:00"))
            expectEqual(rapport.total, 5.5 * 3600, "3 uur plus 2,5 uur")
            expectEqual(rapport.byProject.count, 2)
            expectEqual(rapport.byProject.first?.label, "2401 — Migratie", "grootste project eerst")
        }

        test("weektotaal loopt van maandag tot en met zondag") {
            let fixture = try gevuldeWeek()
            let rapport = try Reporting.report(store: fixture.store, period: .week, containing: at("2026-09-10"),
                                               profileId: fixture.profileA.id, now: at("2026-09-10 18:00"))
            expectEqual(rapport.range.start, at("2026-09-07 00:00"), "de week begint op maandag")
            expectEqual(rapport.total, 13.5 * 3600, "8 uur plus 5,5 uur")
            expectEqual(rapport.byDay.count, 2, "twee gewerkte dagen")
        }

        test("maandtotaal telt beide organisaties als er geen profiel is gekozen") {
            let fixture = try gevuldeWeek()
            let rapport = try Reporting.report(store: fixture.store, period: .month, containing: at("2026-09-10"),
                                               now: at("2026-09-30 18:00"))
            expectEqual(rapport.total, 14.5 * 3600, "13,5 uur van A plus 1 uur van B")
            expectEqual(rapport.range.start, at("2026-09-01 00:00"))
            expectEqual(rapport.range.end, at("2026-10-01 00:00"))
        }

        test("een lopend blok telt mee tot nu") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Kantoor A", .start, "2026-09-10 09:00")

            let rapport = try Reporting.report(store: fixture.store, period: .day, containing: at("2026-09-10"),
                                               now: at("2026-09-10 11:30"))
            expectEqual(rapport.total, 2.5 * 3600)
            expectEqual(rapport.runningCount, 1)
        }

        test("export levert een regel per blok met leesbare velden") {
            let fixture = try gevuldeWeek()
            let csv = try CSVExport.export(store: fixture.store, from: at("2026-09-10"), to: at("2026-09-11"),
                                           profileId: fixture.profileA.id, now: at("2026-09-10 18:00"))
            let regels = csv.split(separator: "\n").map(String.init)

            expectEqual(regels.count, 3, "koprij plus twee blokken")
            expect(regels[0].hasPrefix("id,profiel,context,projectnummer,projectnaam,datum,start,einde"), "koprij: \(regels[0])")
            expect(regels[1].contains("2401,Migratie,2026-09-10,09:00,12:00,3.00,180,0.00,0.00,completed,controlplane"), "blokregel: \(regels[1])")
            expect(regels[2].contains("\"correctie, komma en \"\"aanhalingstekens\"\"\""), "komma's en aanhalingstekens worden ontweken: \(regels[2])")
        }

        test("export van een open blok laat het einde leeg maar noemt de status") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Kantoor A", .start, "2026-09-10 09:00")
            try fixture.tracker.tick(now: at("2026-09-11 09:00"))

            let csv = try CSVExport.export(store: fixture.store, from: at("2026-09-10"), to: at("2026-09-11"),
                                           now: at("2026-09-11 09:00"))
            let regel = csv.split(separator: "\n").map(String.init)[1]

            expect(regel.contains(",09:00,,"), "geen eindtijd: \(regel)")
            expect(regel.hasSuffix("open,controlplane,"), "status open: \(regel)")
        }

        test("een omgekeerd tijdvenster wordt geweigerd") {
            let fixture = try Fixture()
            expectThrows({
                _ = try CSVExport.export(store: fixture.store, from: at("2026-09-11"), to: at("2026-09-10"))
            })
        }

        test("duur wordt getoond als uren:minuten en als decimale uren") {
            expectEqual(Formatting.duration(0), "0:00")
            expectEqual(Formatting.duration(59), "0:00", "de klok springt pas na een hele minuut")
            expectEqual(Formatting.duration(3 * 3600 + 25 * 60), "3:25")
            expectEqual(Formatting.duration(-10), "0:00", "nooit negatief")
            expectEqual(Formatting.decimalHours(5.5 * 3600), "5.50")
        }
    }
}
