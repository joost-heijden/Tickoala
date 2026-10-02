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
            expectEqual(settings.nextNumberText(on: at("2026-09-01")), "0001")

            settings.senderName = "Studio Koala"
            settings.senderIban = "NL00 TEST 0000 0000 00"
            settings.invoiceNumberPrefix = "2026-"
            settings.nextInvoiceNumber = 7
            settings.logoFileName = "logo.png"
            settings.accentColorHex = "#33405A"
            try fixture.store.updateInvoiceSettings(settings)

            let loaded = try fixture.store.invoiceSettings()
            expectEqual(loaded, settings)
            expectEqual(loaded.nextNumberText(on: at("2026-09-01")), "2026-0007")
            // The year in the prefix rolls over on its own; a prefix without a
            // year is left untouched.
            expectEqual(loaded.nextNumberText(on: at("2027-01-05")), "2027-0007")
            expectEqual(InvoiceSettings.prefix("INV-", forYear: 2027), "INV-")
        }

        test("the invoice accent reads and writes hex, greyscale when blank") {
            expectEqual(InvoiceAccent.hex(from: InvoiceAccent.color(hex: "#33405A")!), "#33405A")
            expectEqual(InvoiceAccent.hex(from: InvoiceAccent.color(hex: "33405a")!), "#33405A", "hash and case are tolerated")
            expect(InvoiceAccent.color(hex: nil) == nil, "no accent means greyscale")
            expect(InvoiceAccent.color(hex: "") == nil, "empty means greyscale")
            expect(InvoiceAccent.color(hex: "nonsense") == nil, "unreadable means greyscale")
        }

        test("a new customer starts with the default VAT rate from settings") {
            let fixture = try Fixture()
            var settings = try fixture.store.invoiceSettings()
            settings.defaultVatRatePercent = 9
            try fixture.store.updateInvoiceSettings(settings)
            expectEqual(try fixture.store.invoiceSettings().defaultVatRatePercent, 9)

            let fresh = try fixture.store.createProfile(name: "New", contexts: ["New-Net"], vatRatePercent: 9)
            expectEqual(try fixture.store.profile(id: fresh.id)?.vatRatePercent, 9)
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

            expectEqual(invoice.lines.count, 1, "the break is folded into the one work line")
            expectEqual(invoice.lines.first?.amountCents, 75000, "8 hours minus 30 minutes break at €100")
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

        test("an invoice without the customer address is refused") {
            let fixture = try Fixture()
            try fixture.store.updateProfileInvoicing(
                id: fixture.profileA.id, billingAddress: "", vatNumber: "", vatRatePercent: 21, poNumber: ""
            )
            let period = Invoicing.previousMonthRange(containing: at("2026-09-01"))
            expectThrows { _ = try Invoicing.invoice(store: fixture.store, profileId: fixture.profileA.id, period: period) }
            expectEqual(
                Invoicing.missingRequiredFields(
                    profile: try fixture.store.profile(id: fixture.profileA.id) ?? fixture.profileA,
                    sender: try fixture.store.invoiceSettings()
                ),
                ["the customer address"]
            )
        }

        test("the invoice email copies the global and the client CC addresses") {
            let fixture = try Fixture()
            var settings = try fixture.store.invoiceSettings()
            settings.smtpFromEmail = "me@example.com"
            settings.smtpCcEmails = "books@example.com, books@example.com; second@example.com"
            try fixture.store.updateInvoiceSettings(settings)
            try fixture.store.updateProfileInvoicing(
                id: fixture.profileA.id, billingAddress: "Client Street 1\n1234 AB City",
                vatNumber: "", vatRatePercent: 21,
                poNumber: "", billingEmail: "client@example.com", billingCc: "client-books@example.com"
            )
            expectEqual(try fixture.store.profile(id: fixture.profileA.id)?.billingCc, "client-books@example.com")

            let period = Invoicing.previousMonthRange(containing: at("2026-09-01"))
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-08-10 09:00"), endedAt: at("2026-08-10 17:00"),
                status: .completed, source: .manual, note: nil
            )
            let invoice = try Invoicing.invoice(store: fixture.store, profileId: fixture.profileA.id, period: period)
            let message = InvoiceEmail.message(for: invoice, to: "client@example.com", pdf: Data("x".utf8))
            expectEqual(message.cc, ["books@example.com", "second@example.com", "client-books@example.com"])
            expectEqual(
                message.attachments.map(\.name),
                ["invoice-\(invoice.number).pdf", "invoice-\(invoice.number).xml"]
            )
            expect(
                message.attachments.last?.data == UBLExport.data(for: invoice),
                "the UBL/Peppol XML travels with the invoice email"
            )
            let withoutUBL = InvoiceEmail.message(
                for: invoice, to: "client@example.com", pdf: Data("x".utf8), includeUBL: false
            )
            expectEqual(withoutUBL.attachments.map(\.name), ["invoice-\(invoice.number).pdf"])
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

        test("the history lists every issued invoice, newest month first") {
            let fixture = try Fixture()
            let july = Reporting.range(.month, containing: at("2026-07-15"))
            let august = Invoicing.previousMonthRange(containing: at("2026-09-01"))

            for (profile, period, day) in [
                (fixture.profileB, july, "2026-07-10"),
                (fixture.profileA, august, "2026-08-10"),
            ] {
                _ = try fixture.store.createEntry(
                    profileId: profile.id, projectId: nil,
                    startedAt: at("\(day) 09:00"), endedAt: at("\(day) 17:00"),
                    status: .completed, source: .manual, note: nil
                )
                _ = try Invoicing.invoice(store: fixture.store, profileId: profile.id, period: period)
            }

            let history = try fixture.store.issuedInvoices()
            expectEqual(history.map(\.number), ["0002", "0001"], "the newest month comes first")
            expectEqual(history.first?.profileName, "Organization A")
            expectEqual(Formatting.day(history.first?.periodStart ?? Date()), "2026-08-01")
            expectEqual(history.first?.currency, .eur)

            try fixture.store.deleteInvoice(number: "0001")
            expectEqual(try fixture.store.issuedInvoices().map(\.number), ["0002"], "the deleted one is gone")
            expectEqual(
                try fixture.store.issuedInvoiceNumber(profileId: fixture.profileB.id, periodStart: july.start),
                nil,
                "its number is no longer allocated"
            )
        }

        test("a week and two weeks map to Monday-based windows") {
            let week = InvoicePeriodKind.week.range(containing: at("2026-09-09 12:00"))
            expectEqual(Formatting.day(week.start), "2026-09-07", "Monday")
            expectEqual(Formatting.day(week.end), "2026-09-14", "next Monday")

            let next = InvoicePeriodKind.week.shifted(1, from: at("2026-09-09 12:00"))
            expectEqual(Formatting.day(next.start), "2026-09-14")

            let fortnight = InvoicePeriodKind.twoWeeks.range(containing: at("2026-09-09 12:00"))
            expectEqual(Formatting.day(fortnight.start), "2026-09-07")
            expectEqual(Formatting.day(fortnight.end), "2026-09-21")
            expectEqual(InvoicePeriodKind.matching(start: week.start, end: week.end), .week)
            expectEqual(InvoicePeriodKind.matching(start: fortnight.start, end: fortnight.end), .twoWeeks)
        }

        test("a weekly invoice only counts that week and keeps its own number") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10000)
            // One 8-hour day in the first week, one in the next.
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-07 09:00"), endedAt: at("2026-09-07 17:00"),
                status: .completed, source: .manual, note: nil
            )
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-14 09:00"), endedAt: at("2026-09-14 17:00"),
                status: .completed, source: .manual, note: nil
            )

            let week = InvoicePeriodKind.week.range(containing: at("2026-09-09"))
            let invoice = try Invoicing.invoice(
                store: fixture.store, profileId: fixture.profileA.id, period: week,
                issuedAt: at("2026-09-14 09:00")
            )
            expectEqual(invoice.lines.first?.amountCents, 80000, "only the 8 hours in the invoiced week")
            expectEqual(Formatting.day(invoice.periodStart), "2026-09-07")
            expectEqual(Formatting.day(invoice.periodEnd), "2026-09-14")
            expectEqual(
                Invoicing.periodText(start: invoice.periodStart, end: invoice.periodEnd),
                "2026-09-07 – 2026-09-13"
            )

            let nextWeek = InvoicePeriodKind.week.shifted(1, from: at("2026-09-09"))
            let second = try Invoicing.invoice(
                store: fixture.store, profileId: fixture.profileA.id, period: nextWeek,
                issuedAt: at("2026-09-21 09:00")
            )
            expectEqual(second.number, "0002", "a different week gets its own number")
            expectEqual(second.lines.first?.amountCents, 80000)

            let history = try fixture.store.issuedInvoices()
            expectEqual(Formatting.day(history.first?.periodEnd ?? Date()), "2026-09-21")
        }

        test("a credit note reverses an invoice with its own number") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10000)
            let period = Invoicing.previousMonthRange(containing: at("2026-09-01"))
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-08-10 09:00"), endedAt: at("2026-08-10 17:00"),
                status: .completed, source: .manual, note: nil
            )
            let original = try Invoicing.invoice(
                store: fixture.store, profileId: fixture.profileA.id, period: period,
                issuedAt: at("2026-09-01 09:00")
            )
            expectEqual(original.number, "0001")
            expectEqual(original.totalCents, 96800, "8 hours at €100 plus 21% VAT")

            let credit = try Invoicing.credit(
                store: fixture.store, originalNumber: original.number, issuedAt: at("2026-09-05 09:00")
            )
            expectEqual(credit.number, "0002", "the credit gets its own number")
            expectEqual(credit.creditForNumber, "0001", "and points at the original")
            expect(credit.isCredit)
            expectEqual(credit.subtotalCents, -80000)
            expectEqual(credit.vatCents, -16800)
            expectEqual(credit.totalCents, -96800, "the whole invoice is reversed")
            expectEqual(credit.lines.first?.amountCents, -80000)
            expectEqual(credit.dueAt, credit.issuedAt, "a credit note has no payment term")

            let history = try fixture.store.issuedInvoices()
            expectEqual(history.map(\.number), ["0002", "0001"], "the newer credit comes first")
            expectEqual(history.first?.isCredit, true)
            expectEqual(history.first?.creditForNumber, "0001")
            expectEqual(
                try fixture.store.issuedInvoiceNumber(profileId: fixture.profileA.id, periodStart: period.start),
                "0001",
                "the original still owns the period, so it is not reinvoiced"
            )

            // The reference the Belastingdienst asks for is on the document.
            let xml = UBLExport.document(for: credit)
            expect(xml.contains("<CreditNote "), "a credit is its own UBL document")
            expect(xml.contains("<cbc:CreditNoteTypeCode>381</cbc:CreditNoteTypeCode>"))
            expect(xml.contains("<cac:CreditNoteLine>"))
            expect(xml.contains("<cbc:ID>0001</cbc:ID>"), "the UBL names the invoice it reverses")

            // Crediting the same invoice twice is refused.
            expectThrows { _ = try Invoicing.credit(store: fixture.store, originalNumber: "0001") }
        }

        test("a deleted invoice's number is never handed out again") {
            let fixture = try Fixture()
            let august = Invoicing.previousMonthRange(containing: at("2026-09-01"))
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-08-10 09:00"), endedAt: at("2026-08-10 10:00"),
                status: .completed, source: .manual, note: nil
            )
            let first = try Invoicing.invoice(store: fixture.store, profileId: fixture.profileA.id, period: august)
            expectEqual(first.number, "0001")

            // The invoice was not good enough and is deleted; its number stays spent.
            try fixture.store.deleteInvoice(number: "0001")
            expectEqual(try fixture.store.issuedInvoices().count, 0)

            // Even a settings write that carries an older counter cannot rewind it.
            var settings = try fixture.store.invoiceSettings()
            settings.nextInvoiceNumber = 1
            try fixture.store.updateInvoiceSettings(settings)
            expectEqual(try fixture.store.invoiceSettings().nextInvoiceNumber, 2, "the counter never moves back")

            _ = try fixture.store.createEntry(
                profileId: fixture.profileB.id, projectId: nil,
                startedAt: at("2026-08-11 09:00"), endedAt: at("2026-08-11 10:00"),
                status: .completed, source: .manual, note: nil
            )
            let replacement = try Invoicing.invoice(store: fixture.store, profileId: fixture.profileB.id, period: august)
            expectEqual(replacement.number, "0002", "the deleted number is not reused")
        }
    }
}