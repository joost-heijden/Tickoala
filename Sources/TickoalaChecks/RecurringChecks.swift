import Foundation
import TickoalaCore

func recurringChecks() {
    suite("recurring retainers") {
        test("a fixed invoice carries the retainer and nothing else") {
            let fixture = try Fixture()
            try fixture.store.setRetainer(
                profileId: fixture.profileA.id,
                description: "Support contract",
                amountCents: 150_000
            )
            let period = Reporting.range(.month, containing: at("2026-01-15"))
            let invoice = try expectNotNil(
                try Invoicing.fixedInvoice(store: fixture.store, profileId: fixture.profileA.id, period: period)
            )
            expectEqual(invoice.subtotalCents, 150_000, "just the retainer")
            expectEqual(invoice.netSeconds, 0, "no hours")
            expectEqual(invoice.lines.count, 1)
            expectEqual(invoice.lines.first?.label, "Support contract")
            expectEqual(invoice.totalCents, 150_000 + Int((150_000.0 * 21 / 100).rounded()), "VAT on top")
        }

        test("no retainer means no fixed invoice") {
            let fixture = try Fixture()
            let period = Reporting.range(.month, containing: at("2026-01-15"))
            expectEqual(
                try Invoicing.fixedInvoice(store: fixture.store, profileId: fixture.profileA.id, period: period) == nil,
                true
            )
        }

        test("an ended retainer stops from the month after its last day") {
            let fixture = try Fixture()
            try fixture.store.setRetainer(
                profileId: fixture.profileA.id, description: "Support",
                amountCents: 100_000, endsAt: at("2026-03-31")
            )
            func covers(_ start: String) -> Bool {
                (try? Invoicing.fixedInvoice(
                    store: fixture.store, profileId: fixture.profileA.id,
                    period: Reporting.range(.month, containing: at(start))
                )) != nil
            }
            expect(covers("2026-03-15"), "the last month is covered")
            expect(!covers("2026-04-15"), "the month after the end is not")
        }

        test("the end date cannot be pulled back before the current one") {
            let fixture = try Fixture()
            try fixture.store.setRetainer(
                profileId: fixture.profileA.id, description: "Support",
                amountCents: 100_000, endsAt: at("2026-12-31")
            )
            expectThrows({
                try fixture.store.setRetainer(
                    profileId: fixture.profileA.id, description: "Support",
                    amountCents: 100_000, endsAt: at("2026-06-30")
                )
            }, "a running agreement cannot be shortened by accident")
        }

        test("quarterly and yearly only bill in their months") {
            let fixture = try Fixture()
            try fixture.store.setRetainer(
                profileId: fixture.profileA.id, description: "Support",
                amountCents: 100_000, recurrence: .quarterly
            )
            let jan = Reporting.range(.month, containing: at("2026-01-15"))
            let feb = Reporting.range(.month, containing: at("2026-02-15"))
            let apr = Reporting.range(.month, containing: at("2026-04-15"))
            expect((try? Invoicing.fixedInvoice(store: fixture.store, profileId: fixture.profileA.id, period: jan)) != nil, "January")
            expect((try? Invoicing.fixedInvoice(store: fixture.store, profileId: fixture.profileA.id, period: feb)) == nil, "not February")
            expect((try? Invoicing.fixedInvoice(store: fixture.store, profileId: fixture.profileA.id, period: apr)) != nil, "April")
        }

        test("the candidate list holds every retainer that covers the month") {
            let fixture = try Fixture()
            try fixture.store.setRetainer(
                profileId: fixture.profileA.id, description: "A", amountCents: 100_000
            )
            try fixture.store.setRetainer(
                profileId: fixture.profileB.id, description: "B", amountCents: 200_000, endsAt: at("2026-01-31")
            )
            let march = Reporting.range(.month, containing: at("2026-03-15"))
            let candidates = try Invoicing.fixedInvoiceCandidates(store: fixture.store, period: march)
            expectEqual(candidates.map { $0.name }.sorted(), ["Organization A"], "B ended in January")
        }

        test("rendering twice does not allocate two numbers") {
            let fixture = try Fixture()
            try fixture.store.setRetainer(
                profileId: fixture.profileA.id, description: "Support", amountCents: 100_000
            )
            let period = Reporting.range(.month, containing: at("2026-01-15"))
            let first = try expectNotNil(
                try Invoicing.fixedInvoice(store: fixture.store, profileId: fixture.profileA.id, period: period)
            )
            let second = try expectNotNil(
                try Invoicing.fixedInvoice(store: fixture.store, profileId: fixture.profileA.id, period: period)
            )
            expectEqual(first.number, second.number, "the same period reuses its number")
        }
    }
}
