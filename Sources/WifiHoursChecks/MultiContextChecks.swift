import Foundation
import WifiHoursCore

/// Eén klant kan meerdere wifinetwerken hebben (gast + personeel, of meerdere
/// vestigingen). Deze checks dekken dat een profiel dan via elk van die
/// contexten kan starten, stoppen en roamen zonder een tweede blok te maken.
func multiContextChecks() {
    suite("Meerdere wifinetwerken per klant") {
        test("een profiel kan met meerdere contexten worden aangemaakt") {
            let fixture = try Fixture()
            let profile = try fixture.store.createProfile(name: "Efteling", contexts: ["Efteling-Guest", "Efteling-Staff"])

            expectEqual(Set(profile.contexts), Set(["Efteling-Guest", "Efteling-Staff"]))
            expectEqual(try fixture.store.profile(context: "efteling-guest")?.id, profile.id, "matching is niet hoofdlettergevoelig")
            expectEqual(try fixture.store.profile(context: "Efteling-Staff")?.id, profile.id)
        }

        test("een profiel zonder contexten wordt geweigerd") {
            let fixture = try Fixture()
            expectThrows({ _ = try fixture.store.createProfile(name: "Leeg", contexts: []) }, "minstens één context is verplicht")
        }

        test("een tweede context toevoegen en verwijderen werkt") {
            let fixture = try Fixture()
            let profile = try fixture.store.createProfile(name: "Efteling", contexts: ["Efteling-Guest"])

            let uitgebreid = try fixture.store.addContext(profileId: profile.id, context: "Efteling-Staff")
            expectEqual(Set(uitgebreid.contexts), Set(["Efteling-Guest", "Efteling-Staff"]))

            let verkleind = try fixture.store.removeContext(profileId: profile.id, context: "Efteling-Guest")
            expectEqual(verkleind.contexts, ["Efteling-Staff"])
        }

        test("dezelfde context kan niet aan een tweede profiel gekoppeld worden") {
            let fixture = try Fixture()
            let efteling = try fixture.store.createProfile(name: "Efteling", contexts: ["Efteling-Guest"])
            let andere = try fixture.store.createProfile(name: "Ander park", contexts: ["Ander-Guest"])

            expectThrows({
                _ = try fixture.store.addContext(profileId: andere.id, context: "Efteling-Guest")
            }, "een context hoort maar bij één profiel")
            expectEqual(try fixture.store.profile(context: "Efteling-Guest")?.id, efteling.id, "de koppeling bleef bij Efteling")
        }

        test("starten via elk van de gekoppelde netwerken opent hetzelfde profiel") {
            let fixture = try Fixture()
            let profile = try fixture.store.createProfile(name: "Efteling", contexts: ["Efteling-Guest", "Efteling-Staff"])
            let project = try fixture.store.createProject(profileId: profile.id, number: "1", name: "Onderhoud")
            _ = try fixture.tracker.selectProject(profileId: profile.id, projectId: project.id)

            let outcome = try fixture.tracker.handle(
                ContextEvent(context: "Efteling-Staff", kind: .start, at: at("2026-09-10 09:00")),
                now: at("2026-09-10 09:00")
            )

            expect(outcome.isStarted, "starten via het tweede netwerk moet ook werken")
            let running = try expectNotNil(try fixture.store.runningEntry(profileId: profile.id))
            expectEqual(running.profileId, profile.id)
        }

        test("roamen tussen twee netwerken van dezelfde klant splitst het blok niet") {
            let fixture = try Fixture()
            let profile = try fixture.store.createProfile(name: "Efteling", contexts: ["Efteling-Guest", "Efteling-Staff"])
            let project = try fixture.store.createProject(profileId: profile.id, number: "1", name: "Onderhoud")
            _ = try fixture.tracker.selectProject(profileId: profile.id, projectId: project.id)
            try fixture.store.setSetting(key: "stop-grace-seconds", value: 90)

            _ = try fixture.tracker.handle(
                ContextEvent(context: "Efteling-Guest", kind: .start, at: at("2026-09-10 09:00")), now: at("2026-09-10 09:00")
            )
            // Loopt van het gastnetwerk naar het personeelsnetwerk: stop op de ene,
            // start op de andere, ruim binnen de wachttijd.
            _ = try fixture.tracker.handle(
                ContextEvent(context: "Efteling-Guest", kind: .stop, at: at("2026-09-10 11:00")), now: at("2026-09-10 11:00")
            )
            let terug = try fixture.tracker.handle(
                ContextEvent(context: "Efteling-Staff", kind: .start, at: at("2026-09-10 11:00:30")), now: at("2026-09-10 11:00:30")
            )

            expectEqual(terug, .stopCancelled(entryId: 1), "de wisseling tussen netwerken telt als een korte onderbreking")
            try fixture.tracker.tick(now: at("2026-09-10 11:05"))
            let entry = try expectNotNil(try fixture.store.entry(id: 1))
            expectEqual(entry.status, .running, "het blok loopt door op het andere netwerk")
            expectEqual(try fixture.entries().count, 1, "er is geen tweede blok ontstaan")
        }

        test("CSV-export toont alle gekoppelde contexten van het profiel") {
            let fixture = try Fixture()
            let profile = try fixture.store.createProfile(name: "Efteling", contexts: ["Efteling-Guest", "Efteling-Staff"])
            let project = try fixture.store.createProject(profileId: profile.id, number: "1", name: "Onderhoud")
            _ = try fixture.store.createEntry(
                profileId: profile.id, projectId: project.id,
                startedAt: at("2026-09-10 09:00"), endedAt: at("2026-09-10 12:00"),
                status: .completed, source: .controlplane, note: nil
            )

            let csv = try CSVExport.export(store: fixture.store, from: at("2026-09-10"), to: at("2026-09-11"))
            expect(csv.contains("Efteling-Guest; Efteling-Staff"), "beide contexten staan in de exportregel: \(csv)")
        }
    }
}
