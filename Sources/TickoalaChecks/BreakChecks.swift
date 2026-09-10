import Foundation
import TickoalaCore

/// De automatische pauzeaftrek is een rekenregel over de ruwe blokken heen:
/// tijdregistraties worden er nooit door aangepast.
func breakChecks() {
    suite("Automatische pauzeaftrek") {
        /// Zet één afgerond blok van `hours` uur neer op de gegeven dag.
        @discardableResult
        func werkdag(_ fixture: Fixture, _ profile: Profile, _ day: String, hours: Double) throws -> TimeEntry {
            let start = at("\(day) 09:00")
            return try fixture.store.createEntry(
                profileId: profile.id, projectId: nil,
                startedAt: start, endedAt: start.addingTimeInterval(hours * 3600),
                status: .completed, source: .controlplane, note: nil
            )
        }

        func dagrapport(_ fixture: Fixture, _ profile: Profile, _ day: String) throws -> Report {
            try Reporting.report(
                store: fixture.store, period: .day, containing: at(day),
                profileId: profile.id, now: at("\(day) 23:00")
            )
        }

        test("standaard staat de aftrek uit") {
            let fixture = try Fixture()
            expectEqual(fixture.profileA.breakRule.enabled, false)
            try werkdag(fixture, fixture.profileA, "2026-09-10", hours: 8)

            let rapport = try dagrapport(fixture, fixture.profileA, "2026-09-10")
            expectEqual(rapport.breakDeduction, 0)
            expectEqual(rapport.netTotal, 8 * 3600, "zonder regel verandert er niets")
        }

        test("vanaf de drempel gaat de pauze eraf") {
            let fixture = try Fixture()
            try fixture.store.updateBreakRule(
                profileId: fixture.profileA.id,
                rule: BreakRule(enabled: true, minutes: 30, thresholdMinutes: 360)
            )
            try werkdag(fixture, fixture.profileA, "2026-09-10", hours: 8)

            let rapport = try dagrapport(fixture, fixture.profileA, "2026-09-10")
            expectEqual(rapport.total, 8 * 3600, "bruto blijft 8 uur")
            expectEqual(rapport.breakDeduction, 30 * 60)
            expectEqual(rapport.netTotal, 7.5 * 3600)
        }

        test("de drempel telt inclusief: precies 6 uur is al genoeg") {
            let fixture = try Fixture()
            try fixture.store.updateBreakRule(
                profileId: fixture.profileA.id,
                rule: BreakRule(enabled: true, minutes: 30, thresholdMinutes: 360)
            )
            try werkdag(fixture, fixture.profileA, "2026-09-10", hours: 6)

            expectEqual(try dagrapport(fixture, fixture.profileA, "2026-09-10").breakDeduction, 30 * 60)
        }

        test("onder de drempel gaat er niets af") {
            let fixture = try Fixture()
            try fixture.store.updateBreakRule(
                profileId: fixture.profileA.id,
                rule: BreakRule(enabled: true, minutes: 30, thresholdMinutes: 360)
            )
            try werkdag(fixture, fixture.profileA, "2026-09-10", hours: 5.75)

            let rapport = try dagrapport(fixture, fixture.profileA, "2026-09-10")
            expectEqual(rapport.breakDeduction, 0)
            expectEqual(rapport.netTotal, 5.75 * 3600)
        }

        test("de aftrek geldt per dag, niet per blok") {
            let fixture = try Fixture()
            try fixture.store.updateBreakRule(
                profileId: fixture.profileA.id,
                rule: BreakRule(enabled: true, minutes: 30, thresholdMinutes: 360)
            )
            // Twee blokken op één dag, samen 8 uur: één keer pauze eraf.
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

            let rapport = try dagrapport(fixture, fixture.profileA, "2026-09-10")
            expectEqual(rapport.breakDeduction, 30 * 60, "één pauze per dag")
            expectEqual(rapport.netTotal, 7.5 * 3600)
        }

        test("elke klant heeft een eigen regel") {
            let fixture = try Fixture()
            try fixture.store.updateBreakRule(
                profileId: fixture.profileA.id,
                rule: BreakRule(enabled: true, minutes: 30, thresholdMinutes: 360)
            )
            try fixture.store.updateBreakRule(
                profileId: fixture.profileB.id,
                rule: BreakRule(enabled: true, minutes: 60, thresholdMinutes: 240)
            )
            try werkdag(fixture, fixture.profileA, "2026-09-10", hours: 8)
            try werkdag(fixture, fixture.profileB, "2026-09-10", hours: 8)

            expectEqual(try dagrapport(fixture, fixture.profileA, "2026-09-10").breakDeduction, 30 * 60)
            expectEqual(try dagrapport(fixture, fixture.profileB, "2026-09-10").breakDeduction, 60 * 60)

            // Zonder profielfilter tellen beide regels mee.
            let samen = try Reporting.report(
                store: fixture.store, period: .day, containing: at("2026-09-10"), now: at("2026-09-10 23:00")
            )
            expectEqual(samen.total, 16 * 3600)
            expectEqual(samen.breakDeduction, 90 * 60)
            expectEqual(samen.netTotal, 14.5 * 3600)
        }

        test("een uitgezette regel telt niet meer mee, ook met terugwerkende kracht") {
            let fixture = try Fixture()
            try fixture.store.updateBreakRule(
                profileId: fixture.profileA.id,
                rule: BreakRule(enabled: true, minutes: 30, thresholdMinutes: 360)
            )
            try werkdag(fixture, fixture.profileA, "2026-09-10", hours: 8)
            expectEqual(try dagrapport(fixture, fixture.profileA, "2026-09-10").netTotal, 7.5 * 3600)

            try fixture.store.updateBreakRule(
                profileId: fixture.profileA.id,
                rule: BreakRule(enabled: false, minutes: 30, thresholdMinutes: 360)
            )
            expectEqual(try dagrapport(fixture, fixture.profileA, "2026-09-10").netTotal, 8 * 3600,
                        "de brondata is nooit aangepast")
        }

        test("de weekrapportage trekt per dag af") {
            let fixture = try Fixture()
            try fixture.store.updateBreakRule(
                profileId: fixture.profileA.id,
                rule: BreakRule(enabled: true, minutes: 30, thresholdMinutes: 360)
            )
            try werkdag(fixture, fixture.profileA, "2026-09-07", hours: 8)   // maandag
            try werkdag(fixture, fixture.profileA, "2026-09-08", hours: 8)   // dinsdag
            try werkdag(fixture, fixture.profileA, "2026-09-09", hours: 3)   // woensdag, onder de drempel

            let week = try Reporting.report(
                store: fixture.store, period: .week, containing: at("2026-09-08"),
                profileId: fixture.profileA.id, now: at("2026-09-13 23:00")
            )
            expectEqual(week.total, 19 * 3600)
            expectEqual(week.breakDeduction, 60 * 60, "twee dagen boven de drempel")
            expectEqual(week.netTotal, 18 * 3600)
            expectEqual(week.byDay.count, 3)
            expectEqual(week.byDay.last?.breakDeduction, 0, "de korte woensdag blijft heel")
        }

        test("er gaat nooit meer af dan er gewerkt is") {
            let fixture = try Fixture()
            try fixture.store.updateBreakRule(
                profileId: fixture.profileA.id,
                rule: BreakRule(enabled: true, minutes: 60, thresholdMinutes: 0)
            )
            try werkdag(fixture, fixture.profileA, "2026-09-10", hours: 0.25)

            let rapport = try dagrapport(fixture, fixture.profileA, "2026-09-10")
            expectEqual(rapport.netTotal, 0, "de dag wordt niet negatief")
            expectEqual(rapport.breakDeduction, 15 * 60)
        }

        test("de menubalk toont netto dag- en weektotalen") {
            let fixture = try Fixture()
            try fixture.store.updateBreakRule(
                profileId: fixture.profileA.id,
                rule: BreakRule(enabled: true, minutes: 30, thresholdMinutes: 360)
            )
            try werkdag(fixture, fixture.profileA, "2026-09-10", hours: 8)

            let status = try fixture.tracker.status(now: at("2026-09-10 18:00"))
            let regel = try expectNotNil(status.profiles.first(where: { $0.profile.id == fixture.profileA.id }))
            expectEqual(regel.todayTotal, 7.5 * 3600, "netto")
            expectEqual(regel.todayBreak, 30 * 60)
            expectEqual(regel.todayRaw, 8 * 3600, "bruto blijft opvraagbaar")
        }

        test("export zet de pauze als aparte regel met negatieve duur") {
            let fixture = try Fixture()
            try fixture.store.updateBreakRule(
                profileId: fixture.profileA.id,
                rule: BreakRule(enabled: true, minutes: 30, thresholdMinutes: 360)
            )
            try werkdag(fixture, fixture.profileA, "2026-09-10", hours: 8)

            let csv = try CSVExport.export(
                store: fixture.store, from: at("2026-09-10"), to: at("2026-09-11"), now: at("2026-09-10 23:00")
            )
            let regels = csv.split(separator: "\n").map(String.init)
            expectEqual(regels.count, 3, "koprij, het blok en de pauzeregel")
            expect(regels[2].contains("-0.50"), "negatieve duur: \(regels[2])")
            expect(regels[2].contains("pauze,regel"), "status en bron: \(regels[2])")

            let bruto = try CSVExport.export(
                store: fixture.store, from: at("2026-09-10"), to: at("2026-09-11"),
                now: at("2026-09-10 23:00"), includeBreaks: false
            )
            expectEqual(bruto.split(separator: "\n").count, 2, "met --bruto blijven alleen de blokken over")
        }
    }
}
