import Foundation
import TickoalaCore

func rateChecks() {
    suite("Hourly rate and amounts") {
        test("an hourly rate is stored and can be changed") {
            let fixture = try Fixture()
            let profile = try fixture.store.createProfile(name: "Customer R", contexts: ["Cr"], hourlyRateCents: 8750)
            expectEqual(try fixture.store.profile(id: profile.id)?.hourlyRateCents, 8750)

            try fixture.store.updateProfile(id: profile.id, hourlyRateCents: 10000)
            expectEqual(try fixture.store.profile(id: profile.id)?.hourlyRateCents, 10000)

            // Negative input is silently set to zero; a rate is never negative.
            try fixture.store.updateProfile(id: profile.id, hourlyRateCents: -5)
            expectEqual(try fixture.store.profile(id: profile.id)?.hourlyRateCents, 0)
        }

        test("a rate is shown as money and as a CSV number") {
            expectEqual(Formatting.money(cents: 8750), "€87.50")
            expectEqual(Formatting.money(cents: 123456), "€1,234.56")
            expectEqual(Formatting.money(cents: -8750), "-€87.50")
            expectEqual(Formatting.money(cents: 0), "€0.00")
            expectEqual(Formatting.decimalAmount(cents: 8750), "87.50")
            expectEqual(Formatting.decimalAmount(cents: -8750), "-87.50")
        }

        test("reading a rate accepts comma, dot and thousands separators") {
            expectEqual(Formatting.parseMoneyCents("87,50"), 8750)
            expectEqual(Formatting.parseMoneyCents("87.50"), 8750)
            expectEqual(Formatting.parseMoneyCents("87"), 8700)
            expectEqual(Formatting.parseMoneyCents("1.234,56"), 123456)
            expectEqual(Formatting.parseMoneyCents("€ 100"), 10000)
            expect(Formatting.parseMoneyCents("junk") == nil, "junk gives nil")
            expect(Formatting.parseMoneyCents("-1") == nil, "negative gives nil")
        }

        test("the report calculates net hours times the rate") {
            let fixture = try Fixture()
            // 8 hours of work at €100; with 30 minutes of break deduction from
            // 6 hours, 7.5 hours remain.
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

            let report = try Reporting.report(store: fixture.store, period: .day, containing: at("2026-09-10"), now: at("2026-09-10 18:00"))
            expectEqual(report.total, 8 * 3600)
            expectEqual(report.breakDeduction, 30 * 60)
            expectEqual(report.byProfile.count, 1)
            expectEqual(report.byProfile.first?.net, 7.5 * 3600)
            expectEqual(report.byProfile.first?.hourlyRateCents, 10000)
            expectEqual(report.amountCents, 75000, "7.5 hours x €100")
        }

        test("without a rate the amount is zero") {
            let fixture = try Fixture()
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 09:00"), endedAt: at("2026-09-10 10:00"),
                status: .completed, source: .manual, note: nil
            )
            let report = try Reporting.report(store: fixture.store, period: .day, containing: at("2026-09-10"), now: at("2026-09-10 18:00"))
            expectEqual(report.amountCents, 0)
            expectEqual(report.byProfile.first?.amountCents, 0)
        }

        test("the export has rate and amount columns and a negative break row") {
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
            let rows = csv.split(separator: "\n").map(String.init)
            expect(rows[0].contains("duration_minutes,hourly_rate,amount,currency,status"), "header row: \(rows[0])")
            expect(rows[1].contains(",8.00,480,100.00,800.00,EUR,completed"), "block row: \(rows[1])")
            expect(rows.last?.contains("break") == true, "the last row is the break: \(rows.last ?? "")")
            expect(rows.last?.contains("100.00,-50.00,EUR") == true, "break deduction: \(rows.last ?? "")")
        }

        test("the currency is per customer and can be changed") {
            let fixture = try Fixture()
            let profile = try fixture.store.createProfile(name: "Customer D", contexts: ["Cd"], hourlyRateCents: 10000)
            expectEqual(try fixture.store.profile(id: profile.id)?.currency, Currency.eur, "default euro")

            try fixture.store.updateProfile(id: profile.id, currency: .usd)
            expectEqual(try fixture.store.profile(id: profile.id)?.currency, .usd)
            expectEqual(Formatting.money(cents: 10000, currency: .usd), "$100.00")
            expectEqual(try fixture.store.profile(id: profile.id)?.currency.symbol, "$")
        }

        test("the export names the customer's currency") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10000, currency: .usd)
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 09:00"), endedAt: at("2026-09-10 17:00"),
                status: .completed, source: .manual, note: nil
            )

            let csv = try CSVExport.export(store: fixture.store, from: at("2026-09-10"), to: at("2026-09-11"), now: at("2026-09-10 18:00"))
            expect(csv.contains("800.00,USD,completed"), "currency column: \(csv)")
        }
    }
}
