import Foundation
import TickoalaCore

func invoiceChecks() {
    suite("Invoicing and the monthly reminder") {
        test("the reminder slides a weekend 1st to Monday") {
            // Saturday 2026-08-01 -> Monday 2026-08-03.
            expectEqual(Formatting.day(Invoicing.reminderDate(forMonthContaining: at("2026-08-01"))), "2026-08-03")
            // Sunday 2026-11-01 -> Monday 2026-11-02.
            expectEqual(Formatting.day(Invoicing.reminderDate(forMonthContaining: at("2026-11-01"))), "2026-11-02")
            // Tuesday 2026-09-01 stays put.
            expectEqual(Formatting.day(Invoicing.reminderDate(forMonthContaining: at("2026-09-01"))), "2026-09-01")
            // Friday 2026-05-01 stays put.
            expectEqual(Formatting.day(Invoicing.reminderDate(forMonthContaining: at("2026-05-01"))), "2026-05-01")
        }

        test("the reminder is due from the reminder day until month end") {
            expect(!Invoicing.isReminderDue(now: at("2026-08-02 12:00")), "Sunday before the Monday")
            expect(Invoicing.isReminderDue(now: at("2026-08-03 09:00")), "the Monday itself")
            expect(Invoicing.isReminderDue(now: at("2026-08-20 09:00")), "later in the month")
            expect(Invoicing.isReminderDue(now: at("2026-09-01 09:00")), "the next month starts its own reminder")
        }

        test("the invoice period is the previous month") {
            let range = Invoicing.previousMonthRange(containing: at("2026-09-01"))
            expectEqual(Formatting.day(range.start), "2026-08-01")
            expectEqual(Formatting.day(range.end), "2026-09-01")
        }

        test("invoice settings survive a round trip and the number is padded") {
            let fixture = try Fixture()
            var settings = try fixture.store.invoiceSettings()
            expectEqual(settings.nextNumberText, "0001")

            settings.senderName = "Studio Koala"
            settings.senderIban = "NL00 TEST 0000 0000 00"
            settings.invoiceNumberPrefix = "2026-"
            settings.nextInvoiceNumber = 7
            settings.logoFileName = "logo.png"
            try fixture.store.updateInvoiceSettings(settings)

            let loaded = try fixture.store.invoiceSettings()
            expectEqual(loaded, settings)
            expectEqual(loaded.nextNumberText, "2026-0007")
        }

        test("an invoice allocates a number once and reuses it") {
            let fixture = try Fixture()
            let period = Invoicing.previousMonthRange(containing: at("2026-09-01"))
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-08-10 09:00"), endedAt: at("2026-08-10 17:00"),
                status: .completed, source: .manual, note: nil
            )
            let first = try Invoicing.invoice(store: fixture.store, profileId: fixture.profileA.id, period: period, issuedAt: at("2026-09-01 09:00"))
            let again = try Invoicing.invoice(store: fixture.store, profileId: fixture.profileA.id, period: period, issuedAt: at("2026-09-02 09:00"))
            expectEqual(first.number, "0001")
            expectEqual(again.number, "0001", "the same month keeps its number")

            // A different client gets the next number in the shared sequence.
            _ = try fixture.store.createEntry(
                profileId: fixture.profileB.id, projectId: nil,
                startedAt: at("2026-08-11 09:00"), endedAt: at("2026-08-11 17:00"),
                status: .completed, source: .manual, note: nil
            )
            let other = try Invoicing.invoice(store: fixture.store, profileId: fixture.profileB.id, period: period, issuedAt: at("2026-09-01 09:00"))
            expectEqual(other.number, "0002")
        }

        test("an invoice adds the hours, deducts the break and charges VAT") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10000)
            try fixture.store.updateBreakRule(
                profileId: fixture.profileA.id,
                rule: BreakRule(enabled: true, minutes: 30, thresholdMinutes: 360)
            )
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-08-10 09:00"), endedAt: at("2026-08-10 17:00"),
                status: .completed, source: .manual, note: nil
            )
            let period = Invoicing.previousMonthRange(containing: at("2026-09-01"))
            let invoice = try Invoicing.invoice(
                store: fixture.store, profileId: fixture.profileA.id, period: period,
                poNumber: "PO-42", issuedAt: at("2026-09-01 09:00")
            )

            expectEqual(invoice.lines.count, 2, "one work line and one break line")
            expectEqual(invoice.lines.first?.amountCents, 80000, "8 hours x €100")
            expectEqual(invoice.lines.last?.amountCents, -5000, "30 minutes break")
            expectEqual(invoice.subtotalCents, 75000)
            expectEqual(invoice.vatRatePercent, 21)
            expectEqual(invoice.vatCents, 15750)
            expectEqual(invoice.totalCents, 90750)
            expectEqual(invoice.currency, .eur)
            expectEqual(invoice.poNumber, "PO-42")
            expectEqual(invoice.dueAt, at("2026-10-01 09:00"), "default 30-day term")
            expectEqual(Formatting.day(invoice.periodStart), "2026-08-01")
        }

        test("client billing fields are stored and cleared") {
            let fixture = try Fixture()
            try fixture.store.updateProfileInvoicing(
                id: fixture.profileA.id,
                billingAddress: "Street 1\n1234 AB City",
                vatNumber: "NL123456789B01",
                vatRatePercent: 9,
                poNumber: "PO-7"
            )
            var profile = try fixture.store.profile(id: fixture.profileA.id)
            expectEqual(profile?.billingAddress, "Street 1\n1234 AB City")
            expectEqual(profile?.vatNumber, "NL123456789B01")
            expectEqual(profile?.vatRatePercent, 9)
            expectEqual(profile?.poNumber, "PO-7")

            try fixture.store.updateProfileInvoicing(
                id: fixture.profileA.id, billingAddress: "", vatNumber: "", vatRatePercent: 21, poNumber: ""
            )
            profile = try fixture.store.profile(id: fixture.profileA.id)
            expectEqual(profile?.billingAddress, nil)
            expectEqual(profile?.vatNumber, nil)
            expectEqual(profile?.vatRatePercent, 21)
            expectEqual(profile?.poNumber, nil)
        }

        test("a manual number edit skips numbers that already exist") {
            let fixture = try Fixture()
            let period = Invoicing.previousMonthRange(containing: at("2026-09-01"))
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-08-10 09:00"), endedAt: at("2026-08-10 10:00"),
                status: .completed, source: .manual, note: nil
            )
            _ = try Invoicing.invoice(store: fixture.store, profileId: fixture.profileA.id, period: period)

            // Someone rewinds the counter to 1; the next allocation must skip 0001.
            var settings = try fixture.store.invoiceSettings()
            settings.nextInvoiceNumber = 1
            try fixture.store.updateInvoiceSettings(settings)

            _ = try fixture.store.createEntry(
                profileId: fixture.profileB.id, projectId: nil,
                startedAt: at("2026-08-11 09:00"), endedAt: at("2026-08-11 10:00"),
                status: .completed, source: .manual, note: nil
            )
            let other = try Invoicing.invoice(store: fixture.store, profileId: fixture.profileB.id, period: period)
            expectEqual(other.number, "0002")
        }
    }
}