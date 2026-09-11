import Foundation
import TickoalaCore

func rateChecks() {
    suite("Uurtarief en bedragen") {
        test("een uurtarief wordt bewaard en is te wijzigen") {
            let fixture = try Fixture()
            let profile = try fixture.store.createProfile(name: "Klant R", contexts: ["Kw"], hourlyRateCents: 8750)
            expectEqual(try fixture.store.profile(id: profile.id)?.hourlyRateCents, 8750)

            try fixture.store.updateProfile(id: profile.id, hourlyRateCents: 10000)
            expectEqual(try fixture.store.profile(id: profile.id)?.hourlyRateCents, 10000)

            // Negatieve invoer wordt stil op nul gezet; een tarief is nooit negatief.
            try fixture.store.updateProfile(id: profile.id, hourlyRateCents: -5)
            expectEqual(try fixture.store.profile(id: profile.id)?.hourlyRateCents, 0)
        }

        test("een tarief wordt als geld en als CSV-getal weergegeven") {
            expectEqual(Formatting.money(cents: 8750), "€ 87,50")
            expectEqual(Formatting.money(cents: 123456), "€ 1.234,56")
            expectEqual(Formatting.money(cents: -8750), "-€ 87,50")
            expectEqual(Formatting.money(cents: 0), "€ 0,00")
            expectEqual(Formatting.decimalAmount(cents: 8750), "87.50")
            expectEqual(Formatting.decimalAmount(cents: -8750), "-87.50")
        }

        test("een tarief lezen accepteert komma, punt en duizendtallen") {
            expectEqual(Formatting.parseMoneyCents("87,50"), 8750)
            expectEqual(Formatting.parseMoneyCents("87.50"), 8750)
            expectEqual(Formatting.parseMoneyCents("87"), 8700)
            expectEqual(Formatting.parseMoneyCents("1.234,56"), 123456)
            expectEqual(Formatting.parseMoneyCents("€ 100"), 10000)
            expect(Formatting.parseMoneyCents("onzin") == nil, "rommel geeft nil")
            expect(Formatting.parseMoneyCents("-1") == nil, "negatief geeft nil")
        }

        test("het rapport rekent netto uren keer het tarief") {
            let fixture = try Fixture()
            // 8 uur werk à € 100; met 30 minuten pauzeaftrek vanaf 6 uur blijft 7,5 uur over.
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10000)
            try fixture.store.updateBreakRule(
                profileId: fixture.profileA.id,
                rule: BreakRule(enabled: true, minutes: 30, thresholdMinutes: 360)
            )
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 09:00"), endedAt: at("2026-09-10 17:00"),
                status: .completed, source: .manual, note: nil
            )

            let rapport = try Reporting.report(store: fixture.store, period: .day, containing: at("2026-09-10"), now: at("2026-09-10 18:00"))
            expectEqual(rapport.total, 8 * 3600)
            expectEqual(rapport.breakDeduction, 30 * 60)
            expectEqual(rapport.byProfile.count, 1)
            expectEqual(rapport.byProfile.first?.net, 7.5 * 3600)
            expectEqual(rapport.byProfile.first?.hourlyRateCents, 10000)
            expectEqual(rapport.amountCents, 75000, "7,5 uur x € 100")
        }

        test("zonder tarief is het bedrag nul") {
            let fixture = try Fixture()
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 09:00"), endedAt: at("2026-09-10 10:00"),
                status: .completed, source: .manual, note: nil
            )
            let rapport = try Reporting.report(store: fixture.store, period: .day, containing: at("2026-09-10"), now: at("2026-09-10 18:00"))
            expectEqual(rapport.amountCents, 0)
            expectEqual(rapport.byProfile.first?.amountCents, 0)
        }

        test("de export heeft tarief- en bedragkolommen en een negatieve pauzeregel") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10000)
            try fixture.store.updateBreakRule(
                profileId: fixture.profileA.id,
                rule: BreakRule(enabled: true, minutes: 30, thresholdMinutes: 360)
            )
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 09:00"), endedAt: at("2026-09-10 17:00"),
                status: .completed, source: .manual, note: nil
            )

            let csv = try CSVExport.export(store: fixture.store, from: at("2026-09-10"), to: at("2026-09-11"), now: at("2026-09-10 18:00"))
            let regels = csv.split(separator: "\n").map(String.init)
            expect(regels[0].contains("duur_minuten,uurtarief,bedrag,status"), "koprij: \(regels[0])")
            expect(regels[1].contains(",8.00,480,100.00,800.00,completed"), "blokregel: \(regels[1])")
            expect(regels.last?.contains("pauze") == true, "de laatste regel is de pauze: \(regels.last ?? "")")
            expect(regels.last?.contains("100.00,-50.00") == true, "pauzekorting: \(regels.last ?? "")")
        }
    }
}
