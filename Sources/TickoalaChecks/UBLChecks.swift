import Foundation
import TickoalaCore

func ublChecks() {
    suite("UBL / Peppol export") {
        test("a plain invoice produces a UBL document with both parties and totals") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10000)
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 09:00"), endedAt: at("2026-09-10 17:00"),
                status: .completed, source: .manual, note: nil
            )
            let invoice = try Invoicing.invoice(
                store: fixture.store, profileId: fixture.profileA.id,
                period: DateRange(start: at("2026-09-01"), end: at("2026-10-01"))
            )
            let xml = UBLExport.document(for: invoice)
            expect(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"), "starts with the XML declaration")
            expect(xml.contains("<cbc:ID>\(invoice.number)</cbc:ID>"), "carries the invoice number")
            expect(xml.contains("<cbc:InvoiceTypeCode>380</cbc:InvoiceTypeCode>"), "is a commercial invoice")
            expect(xml.contains("Studio Koala"), "names the supplier")
            expect(xml.contains("Organization A"), "names the customer")
            expect(xml.contains("currencyID=\"EUR\""), "uses the client currency")
            expect(xml.contains(">800.00</cbc:LineExtensionAmount>"), "8 hours at €100")
            expect(xml.contains(">168.00</cbc:TaxAmount>"), "21% VAT over 800")
            expect(xml.contains("unitCode=\"HUR\""), "hours use the HUR unit")
        }

        test("a VAT number and a zero rate become a reverse-charge line") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10000)
            try fixture.store.updateProfileInvoicing(
                id: fixture.profileA.id, billingAddress: "Client Street 1\n1234 AB City",
                vatNumber: "DE123456789", vatRatePercent: 0, poNumber: ""
            )
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 09:00"), endedAt: at("2026-09-10 17:00"),
                status: .completed, source: .manual, note: nil
            )
            let invoice = try Invoicing.invoice(
                store: fixture.store, profileId: fixture.profileA.id,
                period: DateRange(start: at("2026-09-01"), end: at("2026-10-01"))
            )
            let xml = UBLExport.document(for: invoice)
            expect(xml.contains("<cbc:ID>AE</cbc:ID>"), "reverse charge is category AE")
            expect(xml.contains("TaxExemptionReason"), "explains the exemption")
            expect(xml.contains(">0.00</cbc:TaxAmount>"), "no VAT is charged")
        }

        test("an expense and mileage become their own lines with units") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10000)
            _ = try fixture.store.createExpense(
                profileId: fixture.profileA.id, date: at("2026-09-10"), description: "Parking", amountCents: 1250
            )
            _ = try fixture.store.createExpense(
                profileId: fixture.profileA.id, date: at("2026-09-10"), description: "Travel",
                kind: .mileage, quantity: 120, unitRateCents: 23,
                amountCents: Expense.mileageAmountCents(kilometres: 120, rateCentsPerKm: 23)
            )
            let invoice = try Invoicing.invoice(
                store: fixture.store, profileId: fixture.profileA.id,
                period: DateRange(start: at("2026-09-01"), end: at("2026-10-01"))
            )
            let xml = UBLExport.document(for: invoice)
            expect(xml.contains(">Parking<"), "the expense line is there")
            expect(xml.contains("unitCode=\"KMT\""), "mileage uses the kilometre unit")
            expect(xml.contains(">120</cbc:InvoicedQuantity>"), "120 kilometres")
        }

        test("XML metacharacters in names are escaped") {
            let escaped = UBLExport.escaped("A & B <C>")
            expectEqual(escaped, "A &amp; B &lt;C&gt;")
        }

        test("the address heuristic splits a Dutch address") {
            let parts = UBLExport.address("Keizersgracht 1\n1015 CJ Amsterdam\nNetherlands")
            expectEqual(parts.streetLines, ["Keizersgracht 1"])
            expectEqual(parts.postalCode, "1015 CJ")
            expectEqual(parts.city, "Amsterdam")
            expectEqual(parts.countryCode, "NL")
        }

        test("a foreign address keeps its country code") {
            let parts = UBLExport.address("Rue de la Loi 1\n1000 Brussels\nBE")
            expectEqual(parts.countryCode, "BE")
            expectEqual(parts.city, "Brussels")
        }
    }
}
