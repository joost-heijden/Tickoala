import Foundation
import TickoalaCore

func expenseChecks() {
    suite("Expenses and mileage") {
        test("an expense is stored with its amount and description") {
            let fixture = try Fixture()
            let expense = try fixture.store.createExpense(
                profileId: fixture.profileA.id, date: at("2026-09-10"),
                description: "Parking", amountCents: 1250
            )
            expectEqual(expense.amountCents, 1250)
            let loaded = try expectNotNil(try fixture.store.expense(id: expense.id))
            expectEqual(loaded.description, "Parking")
            expectEqual(loaded.kind, .expense)
            expect(loaded.billable, "a new expense is billable by default")
        }

        test("mileage works out to kilometres times the rate") {
            expectEqual(Expense.mileageAmountCents(kilometres: 120, rateCentsPerKm: 23), 2760)
            expectEqual(Expense.mileageAmountCents(kilometres: 0, rateCentsPerKm: 23), 0)
            expectEqual(Expense.mileageAmountCents(kilometres: 120, rateCentsPerKm: 0), 0)

            let fixture = try Fixture()
            let expense = try fixture.store.createExpense(
                profileId: fixture.profileA.id, date: at("2026-09-10"),
                description: "Client visit", kind: .mileage,
                quantity: 120, unitRateCents: 23,
                amountCents: Expense.mileageAmountCents(kilometres: 120, rateCentsPerKm: 23)
            )
            expectEqual(expense.amountCents, 2760)
            expectEqual(expense.quantityText, "120 km")
        }

        test("the mileage rate is stored per customer") {
            let fixture = try Fixture()
            expectEqual(try fixture.store.profile(id: fixture.profileA.id)?.kmRateCents, 0, "no rate by default")
            try fixture.store.updateProfile(id: fixture.profileA.id, kmRateCents: 23)
            expectEqual(try fixture.store.profile(id: fixture.profileA.id)?.kmRateCents, 23)
            try fixture.store.updateProfile(id: fixture.profileA.id, kmRateCents: -5)
            expectEqual(try fixture.store.profile(id: fixture.profileA.id)?.kmRateCents, 0, "never negative")
        }

        test("a billable expense is added to the invoice as its own line") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10000)
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 09:00"), endedAt: at("2026-09-10 17:00"),
                status: .completed, source: .manual, note: nil
            )
            _ = try fixture.store.createExpense(
                profileId: fixture.profileA.id, date: at("2026-09-10"),
                description: "Parking", amountCents: 1250
            )

            let invoice = try Invoicing.invoice(
                store: fixture.store, profileId: fixture.profileA.id,
                period: DateRange(start: at("2026-09-10"), end: at("2026-09-11"))
            )
            expectEqual(invoice.expensesCents, 1250)
            expectEqual(invoice.subtotalCents, 80000 + 1250, "8 hours at €100 plus the expense")
            expect(invoice.lines.contains { $0.label == "Parking" && $0.amountCents == 1250 }, "the expense is its own line")
            // VAT is charged over hours and expenses together.
            expectEqual(invoice.vatCents, Int((Double(invoice.subtotalCents) * 0.21).rounded()))
            expectEqual(invoice.totalCents, invoice.subtotalCents + invoice.vatCents)
        }

        test("a non-billable expense stays off the invoice") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10000)
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 09:00"), endedAt: at("2026-09-10 17:00"),
                status: .completed, source: .manual, note: nil
            )
            _ = try fixture.store.createExpense(
                profileId: fixture.profileA.id, date: at("2026-09-10"),
                description: "Private", amountCents: 5000, billable: false
            )

            let invoice = try Invoicing.invoice(
                store: fixture.store, profileId: fixture.profileA.id,
                period: DateRange(start: at("2026-09-10"), end: at("2026-09-11"))
            )
            expectEqual(invoice.expensesCents, 0)
            expectEqual(invoice.subtotalCents, 80000)
            expect(invoice.lines.allSatisfy { $0.label != "Private" }, "the private cost is not invoiced")
        }

        test("an expense-only period still produces a usable invoice") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10000)
            _ = try fixture.store.createExpense(
                profileId: fixture.profileA.id, date: at("2026-09-10"),
                description: "Materials", amountCents: 5000
            )

            let invoice = try Invoicing.invoice(
                store: fixture.store, profileId: fixture.profileA.id,
                period: DateRange(start: at("2026-09-10"), end: at("2026-09-11"))
            )
            expectEqual(invoice.lines.count, 1, "only the expense line, no empty-hours placeholder")
            expectEqual(invoice.lines.first?.amountCents, 5000)
            expectEqual(invoice.subtotalCents, 5000)
        }

        test("expenses are filtered by the invoice period") {
            let fixture = try Fixture()
            _ = try fixture.store.createExpense(
                profileId: fixture.profileA.id, date: at("2026-09-10"), description: "September", amountCents: 1000
            )
            _ = try fixture.store.createExpense(
                profileId: fixture.profileA.id, date: at("2026-10-02"), description: "October", amountCents: 2000
            )

            let september = try fixture.store.expenses(
                profileId: fixture.profileA.id, from: at("2026-09-01"), to: at("2026-10-01")
            )
            expectEqual(september.count, 1)
            expectEqual(september.first?.description, "September")
        }

        test("the invoice PDF renders with an expense line") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10000)
            _ = try fixture.store.createExpense(
                profileId: fixture.profileA.id, date: at("2026-09-10"), description: "Parking", amountCents: 1250
            )
            let invoice = try Invoicing.invoice(
                store: fixture.store, profileId: fixture.profileA.id,
                period: DateRange(start: at("2026-09-10"), end: at("2026-09-11"))
            )
            let data = InvoicePDF.data(for: invoice)
            expect(data.count > 1000, "the PDF has content")
        }

        test("deleting a customer takes the expenses and undo brings them back") {
            let fixture = try Fixture()
            _ = try fixture.store.createExpense(
                profileId: fixture.profileA.id, date: at("2026-09-10"), description: "Parking", amountCents: 1250
            )
            let backup = try fixture.store.deleteProfile(id: fixture.profileA.id)
            expectEqual(try fixture.store.expenses(profileId: fixture.profileA.id).count, 0, "gone with the customer")

            try fixture.store.restoreProfile(backup)
            let restored = try fixture.store.expenses(profileId: fixture.profileA.id)
            expectEqual(restored.count, 1, "restored with the customer")
            expectEqual(restored.first?.amountCents, 1250)
        }
    }
}
