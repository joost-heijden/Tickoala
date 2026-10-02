import Foundation
import TickoalaCore

func paidChecks() {
    suite("invoice payments") {
        test("an issued invoice gets a due date and can be marked paid") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10_000)
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Office A", .start, "2026-01-02 09:00")
            _ = try fixture.tracker.stop(profileId: fixture.profileA.id, now: at("2026-01-02 17:00"))

            let period = Reporting.range(.month, containing: at("2026-01-15"))
            let invoice = try Invoicing.invoice(
                store: fixture.store, profileId: fixture.profileA.id, period: period,
                issuedAt: at("2026-02-01 12:00"), now: at("2026-02-01 12:00")
            )

            let stored = try expectNotNil(fixture.store.issuedInvoice(number: invoice.number))
            expectEqual(stored.paidAt, nil, "a fresh invoice is open")
            expectEqual(stored.dueAt, at("2026-03-03 12:00"), "30 days after issue")
            expect(!stored.isOverdue(now: at("2026-03-01 12:00")), "not late before the due date")
            expect(!stored.isOverdue(now: at("2026-03-03 12:00")), "the due day itself is not late")
            expect(stored.isOverdue(now: at("2026-03-05 12:00")), "late after the due date")
            expectEqual(stored.daysLate(now: at("2026-03-05 12:00")), 2)

            try fixture.store.setInvoicePaid(number: invoice.number, paidAt: at("2026-03-04 09:00"))
            let paid = try expectNotNil(fixture.store.issuedInvoice(number: invoice.number))
            expect(paid.isPaid)
            expect(!paid.isOverdue(now: at("2026-03-10 12:00")), "a paid invoice is never overdue")

            try fixture.store.setInvoicePaid(number: invoice.number, paidAt: nil)
            expectEqual(try fixture.store.issuedInvoice(number: invoice.number)?.isPaid, false, "reopened again")
        }

        test("a credit note has nothing to pay") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10_000)
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Office A", .start, "2026-01-02 09:00")
            _ = try fixture.tracker.stop(profileId: fixture.profileA.id, now: at("2026-01-02 17:00"))

            let period = Reporting.range(.month, containing: at("2026-01-15"))
            let original = try Invoicing.invoice(
                store: fixture.store, profileId: fixture.profileA.id, period: period,
                issuedAt: at("2026-02-01 12:00"), now: at("2026-02-01 12:00")
            )
            let credit = try Invoicing.credit(
                store: fixture.store, originalNumber: original.number,
                issuedAt: at("2026-02-10 12:00"), now: at("2026-02-10 12:00")
            )
            let stored = try expectNotNil(fixture.store.issuedInvoice(number: credit.number))
            expect(stored.isCredit)
            expect(!stored.isOverdue(now: at("2027-01-01 12:00")), "a credit is never overdue")
            expectThrows(
                { try fixture.store.setInvoicePaid(number: credit.number, paidAt: Date()) },
                "a credit note cannot be marked paid"
            )
        }

        test("marking an unknown invoice paid is refused") {
            let fixture = try Fixture()
            expectThrows(
                { try fixture.store.setInvoicePaid(number: "does-not-exist", paidAt: Date()) },
                "unknown invoice"
            )
        }

        test("an invoice without a stored due date is backfilled from the term") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10_000)
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Office A", .start, "2026-01-02 09:00")
            _ = try fixture.tracker.stop(profileId: fixture.profileA.id, now: at("2026-01-02 17:00"))

            let period = Reporting.range(.month, containing: at("2026-01-15"))
            let invoice = try Invoicing.invoice(
                store: fixture.store, profileId: fixture.profileA.id, period: period,
                issuedAt: at("2026-02-01 12:00"), now: at("2026-02-01 12:00")
            )
            try fixture.store.database.run(
                "UPDATE invoices SET due_at = NULL WHERE number = ?;", [.text(invoice.number)]
            )
            let stored = try expectNotNil(fixture.store.issuedInvoice(number: invoice.number))
            expectEqual(stored.dueAt, at("2026-03-03 12:00"), "computed from the payment term")
        }
    }
}
