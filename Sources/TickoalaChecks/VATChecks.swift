import Foundation
import TickoalaCore

func vatChecks() {
    suite("VAT return") {
        test("the quarter is found and shifted across years") {
            expectEqual(VATPeriod.containing(at("2026-02-15")).label, "Q1 2026")
            expectEqual(VATPeriod.containing(at("2026-12-31")).label, "Q4 2026")
            expectEqual(VATPeriod(year: 2026, quarter: 1).shifted(-1).label, "Q4 2025")
            expectEqual(VATPeriod(year: 2026, quarter: 4).shifted(1).label, "Q1 2027")
            expectEqual(VATPeriod(year: 2026, quarter: 1).shifted(4).label, "Q1 2027")
            expectEqual(VATPeriod(year: 2026, quarter: 2).shifted(-5).label, "Q1 2025")

            let q1 = VATPeriod(year: 2026, quarter: 1)
            expectEqual(q1.start, at("2026-01-01"))
            expectEqual(q1.end, at("2026-04-01"))
        }

        test("turnover and VAT are grouped per rate") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10000)
            try fixture.store.updateProfile(id: fixture.profileB.id, hourlyRateCents: 10000)
            try fixture.store.updateProfileInvoicing(
                id: fixture.profileB.id, billingAddress: "Client Street 2\n5678 CD City",
                vatNumber: "NL000000002B01", vatRatePercent: 9, poNumber: ""
            )
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-02-10 09:00"), endedAt: at("2026-02-10 19:00"),
                status: .completed, source: .manual, note: nil
            )
            _ = try fixture.store.createEntry(
                profileId: fixture.profileB.id, projectId: nil,
                startedAt: at("2026-02-11 09:00"), endedAt: at("2026-02-11 19:00"),
                status: .completed, source: .manual, note: nil
            )

            let report = try VAT.report(store: fixture.store, period: VATPeriod(year: 2026, quarter: 1))
            expectEqual(report.lines.count, 2, "one line per rate")
            let low = try expectNotNil(report.lines.first { $0.ratePercent == 9 })
            expectEqual(low.netCents, 100000, "10 hours at €100")
            expectEqual(low.vatCents, 9000, "9% of €1000")
            let high = try expectNotNil(report.lines.first { $0.ratePercent == 21 })
            expectEqual(high.netCents, 100000)
            expectEqual(high.vatCents, 21000)
            expectEqual(report.totalNetCents, 200000)
            expectEqual(report.totalVatCents, 30000)
        }

        test("billable expenses count towards the return") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10000)
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-02-10 09:00"), endedAt: at("2026-02-10 19:00"),
                status: .completed, source: .manual, note: nil
            )
            _ = try fixture.store.createExpense(
                profileId: fixture.profileA.id, date: at("2026-02-10"), description: "Parking", amountCents: 1250
            )
            _ = try fixture.store.createExpense(
                profileId: fixture.profileA.id, date: at("2026-02-10"), description: "Private", amountCents: 5000,
                billable: false
            )

            let report = try VAT.report(store: fixture.store, period: VATPeriod(year: 2026, quarter: 1))
            let line = try expectNotNil(report.lines.first)
            expectEqual(line.netCents, 100000 + 1250, "only the billable expense counts")
            expectEqual(line.vatCents, Int((Double(101250) * 0.21).rounded()))
        }

        test("a quarter without work declares nothing") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10000)
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-02-10 09:00"), endedAt: at("2026-02-10 19:00"),
                status: .completed, source: .manual, note: nil
            )
            let report = try VAT.report(store: fixture.store, period: VATPeriod(year: 2026, quarter: 3))
            expect(report.lines.isEmpty, "nothing in Q3")
            expectEqual(report.totalVatCents, 0)
        }
    }
}
