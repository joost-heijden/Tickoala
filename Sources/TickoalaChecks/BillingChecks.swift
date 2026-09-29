import Foundation
import TickoalaCore

func billingChecks() {
    suite("Billing rules") {
        test("rounding goes to the nearest increment, or up when asked") {
            let nearest = BillingRules(roundingMinutes: 15)
            expectEqual(nearest.rounded(80 * 60), 75 * 60, "80 minutes to the nearest quarter")
            let up = BillingRules(roundingMinutes: 15, roundUp: true)
            expectEqual(up.rounded(80 * 60), 90 * 60, "80 minutes rounded up")
            expectEqual(BillingRules().rounded(80 * 60), 80 * 60, "no rounding by default")
        }

        test("the rules are stored per customer") {
            let fixture = try Fixture()
            expectEqual(try fixture.store.profile(id: fixture.profileA.id)?.billingRules, .default)
            try fixture.store.updateBillingRules(
                profileId: fixture.profileA.id,
                rules: BillingRules(roundingMinutes: 15, roundUp: true, minimumMinutes: 60)
            )
            let loaded = try expectNotNil(try fixture.store.profile(id: fixture.profileA.id))
            expectEqual(loaded.billingRules.roundingMinutes, 15)
            expect(loaded.billingRules.roundUp)
            expectEqual(loaded.billingRules.minimumMinutes, 60)
        }

        test("rounding is applied to the invoiced hours") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10000)
            try fixture.store.updateBillingRules(
                profileId: fixture.profileA.id, rules: BillingRules(roundingMinutes: 15)
            )
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 09:00"), endedAt: at("2026-09-10 10:20"),
                status: .completed, source: .manual, note: nil
            )
            let invoice = try Invoicing.invoice(
                store: fixture.store, profileId: fixture.profileA.id,
                period: DateRange(start: at("2026-09-10"), end: at("2026-09-11"))
            )
            expectEqual(invoice.lines.first?.seconds, 75 * 60, "80 minutes become a quarter-hour block")
            expectEqual(invoice.subtotalCents, 12500, "75 minutes at €100 per hour")
        }

        test("a minimum tops up a light period") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10000)
            try fixture.store.updateBillingRules(
                profileId: fixture.profileA.id, rules: BillingRules(minimumMinutes: 60)
            )
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 09:00"), endedAt: at("2026-09-10 09:30"),
                status: .completed, source: .manual, note: nil
            )
            let invoice = try Invoicing.invoice(
                store: fixture.store, profileId: fixture.profileA.id,
                period: DateRange(start: at("2026-09-10"), end: at("2026-09-11"))
            )
            expect(invoice.lines.contains { $0.label == "Minimum billing" }, "a minimum line is added")
            expectEqual(invoice.subtotalCents, 10000, "topped up to one hour")
        }

        test("evening hours get their surcharge line") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10000)
            try fixture.store.updateBillingRules(
                profileId: fixture.profileA.id, rules: BillingRules(eveningSurchargePercent: 25)
            )
            // 2026-09-10 is a Thursday; 18:00–20:00 is two evening hours.
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 18:00"), endedAt: at("2026-09-10 20:00"),
                status: .completed, source: .manual, kind: .work, note: nil
            )
            let invoice = try Invoicing.invoice(
                store: fixture.store, profileId: fixture.profileA.id,
                period: DateRange(start: at("2026-09-10"), end: at("2026-09-11"))
            )
            let line = invoice.lines.first { $0.label.contains("Evening surcharge") }
            expect(line != nil, "an evening surcharge line appears")
            expectEqual(line?.amountCents, 5000, "25% of two hours at €100")
            expectEqual(invoice.subtotalCents, 20000 + 5000)
        }

        test("weekend hours get their surcharge line") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10000)
            try fixture.store.updateBillingRules(
                profileId: fixture.profileA.id, rules: BillingRules(weekendSurchargePercent: 50)
            )
            // 2026-09-12 is a Saturday.
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-12 10:00"), endedAt: at("2026-09-12 12:00"),
                status: .completed, source: .manual, kind: .work, note: nil
            )
            let invoice = try Invoicing.invoice(
                store: fixture.store, profileId: fixture.profileA.id,
                period: DateRange(start: at("2026-09-12"), end: at("2026-09-13"))
            )
            let line = invoice.lines.first { $0.label.contains("Weekend surcharge") }
            expect(line != nil, "a weekend surcharge line appears")
            expectEqual(line?.amountCents, 10000, "50% of two hours at €100")
        }
    }
}
