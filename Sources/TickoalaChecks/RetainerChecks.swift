import Foundation
import TickoalaCore

func retainerChecks() {
    suite("Retainer") {
        test("a retainer is stored per customer and can be cleared") {
            let fixture = try Fixture()
            expect(try fixture.store.retainer(profileId: fixture.profileA.id) == nil, "none by default")
            try fixture.store.setRetainer(
                profileId: fixture.profileA.id, description: "Support contract", amountCents: 150000
            )
            let retainer = try expectNotNil(try fixture.store.retainer(profileId: fixture.profileA.id))
            expectEqual(retainer.amountCents, 150000)
            expectEqual(retainer.label, "Support contract")
            expect(retainer.isSet, "a positive amount is set")

            try fixture.store.clearRetainer(profileId: fixture.profileA.id)
            expect(try fixture.store.retainer(profileId: fixture.profileA.id) == nil, "cleared")
        }

        test("a zero retainer is never billed") {
            let fixture = try Fixture()
            try fixture.store.setRetainer(profileId: fixture.profileA.id, description: "None", amountCents: 0)
            let retainer = try expectNotNil(try fixture.store.retainer(profileId: fixture.profileA.id))
            expect(!retainer.isSet, "a zero amount stays off the invoice")
        }

        test("the retainer lands on the invoice as its own line, with VAT over it") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10000)
            try fixture.store.setRetainer(
                profileId: fixture.profileA.id, description: "Support contract", amountCents: 150000
            )
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 09:00"), endedAt: at("2026-09-10 17:00"),
                status: .completed, source: .manual, note: nil
            )
            let invoice = try Invoicing.invoice(
                store: fixture.store, profileId: fixture.profileA.id,
                period: DateRange(start: at("2026-09-10"), end: at("2026-09-11"))
            )
            expectEqual(invoice.subtotalCents, 80000 + 150000, "8 hours plus the retainer")
            expect(invoice.lines.contains { $0.label == "Support contract" && $0.amountCents == 150000 }, "retainer is its own line")
            expectEqual(invoice.vatCents, Int((Double(invoice.subtotalCents) * 0.21).rounded()), "VAT over hours and retainer")
        }

        test("an inactive retainer stays off the invoice") {
            let fixture = try Fixture()
            try fixture.store.updateProfile(id: fixture.profileA.id, hourlyRateCents: 10000)
            try fixture.store.setRetainer(
                profileId: fixture.profileA.id, description: "Paused", amountCents: 150000, active: false
            )
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: nil,
                startedAt: at("2026-09-10 09:00"), endedAt: at("2026-09-10 17:00"),
                status: .completed, source: .manual, note: nil
            )
            let invoice = try Invoicing.invoice(
                store: fixture.store, profileId: fixture.profileA.id,
                period: DateRange(start: at("2026-09-10"), end: at("2026-09-11"))
            )
            expectEqual(invoice.subtotalCents, 80000)
            expect(invoice.lines.allSatisfy { $0.label != "Paused" }, "no retainer line")
        }

        test("deleting a customer takes the retainer along and undo restores it") {
            let fixture = try Fixture()
            try fixture.store.setRetainer(profileId: fixture.profileA.id, description: "Support", amountCents: 50000)
            let backup = try fixture.store.deleteProfile(id: fixture.profileA.id)
            expect(try fixture.store.retainer(profileId: fixture.profileA.id) == nil, "gone with the customer")

            try fixture.store.restoreProfile(backup)
            let restored = try expectNotNil(try fixture.store.retainer(profileId: fixture.profileA.id))
            expectEqual(restored.amountCents, 50000)
        }
    }
}
