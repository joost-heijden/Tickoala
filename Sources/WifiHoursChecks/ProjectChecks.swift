import Foundation
import WifiHoursCore

func projectChecks() {
    suite("Projecten") {
        test("projectnummers zijn uniek binnen een organisatie") {
            let fixture = try Fixture()
            _ = try fixture.store.createProject(profileId: fixture.profileA.id, number: "2401", name: "Migratie")

            expectThrows({
                _ = try fixture.store.createProject(profileId: fixture.profileA.id, number: "2401", name: "Iets anders")
            }, "hetzelfde nummer mag niet twee keer binnen één organisatie")

            // Hetzelfde nummer bij de andere organisatie mag wel.
            _ = try fixture.store.createProject(profileId: fixture.profileB.id, number: "2401", name: "Ander werk")
            expectEqual(try fixture.store.projects(profileId: fixture.profileB.id).count, 1)
        }

        test("een contextnaam hoort bij precies één profiel") {
            let fixture = try Fixture()
            expectThrows({
                _ = try fixture.store.createProfile(name: "Organisatie C", contexts: ["Kantoor A"])
            }, "twee profielen op dezelfde context mag niet")
        }

        test("projectwissel tijdens het werk splitst het blok") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA, number: "2401", name: "Migratie")
            let onderhoud = try fixture.store.createProject(profileId: fixture.profileA.id, number: "2402", name: "Onderhoud")
            _ = try fixture.event("Kantoor A", .start, "2026-09-10 09:00")

            _ = try fixture.tracker.selectProject(profileId: fixture.profileA.id, projectId: onderhoud.id, now: at("2026-09-10 11:00"))
            _ = try fixture.tracker.stop(profileId: fixture.profileA.id, now: at("2026-09-10 12:00"))

            let entries = try fixture.entries()
            expectEqual(entries.count, 2, "aantal blokken na een wissel")
            expectEqual(entries.first?.duration(), 2 * 3600, "tijd blijft bij het eerste project")
            expectEqual(entries.last?.projectId, onderhoud.id, "het nieuwe blok hangt aan het nieuwe project")
            expectEqual(entries.last?.duration(), 3600)
        }

        test("hetzelfde project opnieuw kiezen splitst niets") {
            let fixture = try Fixture()
            let project = try fixture.project(fixture.profileA)
            _ = try fixture.event("Kantoor A", .start, "2026-09-10 09:00")

            _ = try fixture.tracker.selectProject(profileId: fixture.profileA.id, projectId: project.id, now: at("2026-09-10 11:00"))

            expectEqual(try fixture.entries().count, 1)
        }

        test("een gedeactiveerd project laat bestaande blokken staan maar start niet meer") {
            let fixture = try Fixture()
            let project = try fixture.project(fixture.profileA)
            _ = try fixture.event("Kantoor A", .start, "2026-09-10 09:00")
            _ = try fixture.tracker.stop(profileId: fixture.profileA.id, now: at("2026-09-10 12:00"))

            try fixture.store.updateProject(id: project.id, active: false)

            expectEqual(try fixture.entries().count, 1, "de registratie blijft bestaan")
            expectEqual(try fixture.event("Kantoor A", .start, "2026-09-10 13:00"), .needsProject(profileId: fixture.profileA.id))
        }

        test("een project van een ander profiel kan niet gekozen worden") {
            let fixture = try Fixture()
            let projectB = try fixture.store.createProject(profileId: fixture.profileB.id, number: "B-1", name: "Ander werk")

            expectThrows({
                _ = try fixture.tracker.selectProject(profileId: fixture.profileA.id, projectId: projectB.id)
            }, "projecten blijven binnen hun eigen organisatie")
        }

        test("het eerste project van een organisatie wordt meteen het actieve project") {
            let fixture = try Fixture()

            let eerste = try fixture.tracker.createProject(profileId: fixture.profileA.id, number: "2401", name: "Migratie")
            expectEqual(try fixture.store.state(profileId: fixture.profileA.id).activeProjectId, eerste.id)

            // Een tweede project mag de lopende keuze niet zomaar overnemen.
            let tweede = try fixture.tracker.createProject(profileId: fixture.profileA.id, number: "2402", name: "Onderhoud")
            expectEqual(try fixture.store.state(profileId: fixture.profileA.id).activeProjectId, eerste.id,
                        "het actieve project blijft staan bij \(tweede.number)")
        }

        test("een nieuw project start meteen automatisch bij binnenkomst") {
            let fixture = try Fixture()
            _ = try fixture.tracker.createProject(profileId: fixture.profileA.id, number: "2401", name: "Migratie")

            let outcome = try fixture.event("Kantoor A", .start, "2026-09-10 09:00")

            expect(outcome.isStarted, "zonder losse projectkeuze moet dit al werken, kreeg \(outcome)")
        }

        test("een projectnummer is achteraf te wijzigen") {
            let fixture = try Fixture()
            let project = try fixture.store.createProject(profileId: fixture.profileA.id, number: "001", name: "AI Platform")
            _ = try fixture.store.createProject(profileId: fixture.profileA.id, number: "002", name: "Onderhoud")

            try fixture.store.updateProject(id: project.id, number: "2401", name: "AI Platform")
            expectEqual(try fixture.store.project(id: project.id)?.label, "2401 — AI Platform")
            expect(try fixture.store.project(profileId: fixture.profileA.id, number: "001") == nil, "het oude nummer is vrij")

            // Hernummeren naar een bestaand nummer mag niet.
            expectThrows({
                try fixture.store.updateProject(id: project.id, number: "002")
            }, "botsing met een bestaand projectnummer")
            expectEqual(try fixture.store.project(id: project.id)?.number, "2401", "het nummer bleef staan")

            // Dezelfde waarde opnieuw opslaan mag wel.
            try fixture.store.updateProject(id: project.id, number: "2401", name: "AI-platform")
            expectEqual(try fixture.store.project(id: project.id)?.name, "AI-platform")
        }

        test("hernummeren laat bestaande tijdregistraties intact") {
            let fixture = try Fixture()
            let project = try fixture.tracker.createProject(profileId: fixture.profileA.id, number: "001", name: "AI Platform")
            _ = try fixture.event("Kantoor A", .start, "2026-09-10 09:00")
            _ = try fixture.tracker.stop(profileId: fixture.profileA.id, now: at("2026-09-10 17:00"))

            try fixture.store.updateProject(id: project.id, number: "2401")

            let entry = try expectNotNil(try fixture.entries().first)
            expectEqual(entry.projectId, project.id, "het blok hangt nog aan hetzelfde project")
            expectEqual(entry.duration(), 8 * 3600)
        }

        test("het label voor de menubalk is 'nummer — naam'") {
            let fixture = try Fixture()
            let project = try fixture.project(fixture.profileA, number: "2401", name: "Migratie datawarehouse")
            expectEqual(project.label, "2401 — Migratie datawarehouse")
        }
    }
}
