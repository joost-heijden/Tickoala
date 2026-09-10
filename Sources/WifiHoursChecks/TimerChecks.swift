import Foundation
import WifiHoursCore

func timerChecks() {
    suite("Timerlogica") {
        test("een startevent begint een blok op het actieve project") {
            let fixture = try Fixture()
            let project = try fixture.project(fixture.profileA)

            let outcome = try fixture.event("Kantoor A", .start, "2026-09-10 09:00")

            expect(outcome.isStarted, "verwachtte een gestart blok, kreeg \(outcome)")
            let running = try expectNotNil(try fixture.store.runningEntry(profileId: fixture.profileA.id))
            expectEqual(running.projectId, project.id, "project van het blok")
            expectEqual(running.startedAt, at("2026-09-10 09:00"), "starttijd")
            expectEqual(running.source, .controlplane, "bron")
        }

        test("zonder gekozen project start de tracker niet automatisch") {
            let fixture = try Fixture()

            let outcome = try fixture.event("Kantoor A", .start, "2026-09-10 09:00")

            expectEqual(outcome, .needsProject(profileId: fixture.profileA.id))
            expect(try fixture.store.runningEntry(profileId: fixture.profileA.id) == nil, "er mag geen timer lopen")
            expect(try fixture.store.state(profileId: fixture.profileA.id).attention != nil, "de gebruiker moet een melding krijgen")
        }

        test("een tweede start maakt geen tweede blok") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)

            _ = try fixture.event("Kantoor A", .start, "2026-09-10 09:00")
            // Ruim buiten het dedupe-venster, dus dit event wordt echt beoordeeld.
            let second = try fixture.event("Kantoor A", .start, "2026-09-10 10:00")

            expectEqual(second, .alreadyRunning(entryId: 1))
            expectEqual(try fixture.entries().count, 1, "aantal blokken")
        }

        test("herhaalde events binnen het tijdvenster worden genegeerd") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)

            _ = try fixture.event("Kantoor A", .start, "2026-09-10 09:00:00")
            let repeated = try fixture.event("Kantoor A", .start, "2026-09-10 09:00:20")

            expectEqual(repeated, .ignoredDuplicate)
            expectEqual(try fixture.store.recentEvents().count, 1, "aantal gelogde events")
        }

        test("een herhaling net over de bucketgrens telt ook als herhaling") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            try fixture.store.setSetting(key: "dedupe-window-seconds", value: 30)

            // 09:00:29 en 09:00:31 vallen in verschillende tijdvakken van 30 seconden.
            _ = try fixture.event("Kantoor A", .start, "2026-09-10 09:00:29")
            let repeated = try fixture.event("Kantoor A", .start, "2026-09-10 09:00:31")

            expectEqual(repeated, .ignoredDuplicate)
        }

        test("onbekende wifi-context doet niets automatisch") {
            let fixture = try Fixture()

            let outcome = try fixture.event("Café", .start, "2026-09-10 09:00")

            expectEqual(outcome, .ignoredUnknownContext)
            expect(try fixture.store.runningEntries().isEmpty, "er mag geen timer lopen")
            expectEqual(try fixture.store.recentEvents().count, 1, "ook een genegeerd event wordt gelogd")
        }

        test("een inactief profiel reageert niet op zijn context") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            try fixture.store.updateProfile(id: fixture.profileA.id, active: false)

            expectEqual(try fixture.event("Kantoor A", .start, "2026-09-10 09:00"), .ignoredInactiveProfile)
            expect(try fixture.store.runningEntries().isEmpty, "er mag geen timer lopen")
        }

        test("stop wacht de wachttijd af en gebruikt het moment van het signaal") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            try fixture.store.setSetting(key: "stop-grace-seconds", value: 90)
            _ = try fixture.event("Kantoor A", .start, "2026-09-10 09:00")

            let outcome = try fixture.event("Kantoor A", .stop, "2026-09-10 17:00")
            expectEqual(outcome, .stopScheduled(effectiveAt: at("2026-09-10 17:01:30")))
            expect(try fixture.store.runningEntry(profileId: fixture.profileA.id) != nil, "de timer loopt nog tijdens de wachttijd")

            _ = try fixture.tracker.finalizePendingStops(now: at("2026-09-10 17:00:45"))
            expect(try fixture.store.runningEntry(profileId: fixture.profileA.id) != nil, "halverwege de wachttijd stopt er nog niets")

            let closed = try fixture.tracker.finalizePendingStops(now: at("2026-09-10 17:01:31"))
            expectEqual(closed.count, 1, "aantal afgesloten blokken")
            let entry = try expectNotNil(try fixture.store.entry(id: 1))
            expectEqual(entry.status, .completed)
            expectEqual(entry.endedAt, at("2026-09-10 17:00"), "het einde is het moment van het stopsignaal")
            expectEqual(entry.duration(), 8 * 3600, "duur in seconden")
        }

        test("korte wifi-uitval sluit het blok niet af") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            try fixture.store.setSetting(key: "stop-grace-seconds", value: 90)
            _ = try fixture.event("Kantoor A", .start, "2026-09-10 09:00")

            _ = try fixture.event("Kantoor A", .stop, "2026-09-10 11:00")
            let back = try fixture.event("Kantoor A", .start, "2026-09-10 11:00:40")

            expectEqual(back, .stopCancelled(entryId: 1))
            try fixture.tracker.tick(now: at("2026-09-10 11:05"))
            let entry = try expectNotNil(try fixture.store.entry(id: 1))
            expectEqual(entry.status, .running, "het blok loopt door")
            expect(entry.endedAt == nil, "er is geen einde vastgelegd")
            expectEqual(try fixture.entries().count, 1, "geen tweede blok")
        }

        test("een stop uit het verleden wordt meteen definitief") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Kantoor A", .start, "2026-09-10 09:00")

            let outcome = try fixture.tracker.handle(
                ContextEvent(context: "Kantoor A", kind: .stop, at: at("2026-09-10 17:00")),
                now: at("2026-09-10 17:30")
            )

            expectEqual(outcome, .stopped(entryId: 1))
            let entry = try expectNotNil(try fixture.store.entry(id: 1))
            expectEqual(entry.endedAt, at("2026-09-10 17:00"))
        }

        test("vertrek zonder lopende timer levert alleen een logregel op") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)

            let outcome = try fixture.event("Kantoor A", .stop, "2026-09-10 17:00")

            expectEqual(outcome, .noRunningTimer)
            expect(try fixture.entries().isEmpty, "er ontstaat geen leeg blok")
            expectEqual(try fixture.store.recentEvents().count, 1, "het vertrek is wel gelogd")
        }

        test("twee werkcontexten tegelijk stoppen niets en vragen om een keuze") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA, number: "2401")
            try fixture.project(fixture.profileB, number: "B-1")
            _ = try fixture.event("Kantoor A", .start, "2026-09-10 09:00")

            let outcome = try fixture.event("Kantoor B", .start, "2026-09-10 09:30")

            expectEqual(outcome, .conflict(runningProfileId: fixture.profileA.id))
            expect(try fixture.store.runningEntry(profileId: fixture.profileA.id) != nil, "het eerste blok blijft lopen")
            expect(try fixture.store.runningEntry(profileId: fixture.profileB.id) == nil, "het tweede profiel start niet")
            expectEqual(try fixture.tracker.status(now: at("2026-09-10 09:30")).mode, .attention)
        }

        test("pauzeren sluit het blok af, hervatten begint een nieuw blok") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Kantoor A", .start, "2026-09-10 09:00")

            _ = try fixture.tracker.pause(profileId: fixture.profileA.id, now: at("2026-09-10 12:00"))
            expectEqual(try fixture.tracker.status(now: at("2026-09-10 12:15")).mode, .paused)

            _ = try fixture.tracker.resume(profileId: fixture.profileA.id, now: at("2026-09-10 12:30"))
            _ = try fixture.tracker.stop(profileId: fixture.profileA.id, now: at("2026-09-10 17:00"))

            let entries = try fixture.entries()
            expectEqual(entries.count, 2, "pauze splitst de dag in twee blokken")
            expectEqual(entries.first?.duration(), 3 * 3600, "ochtendblok")
            expectEqual(entries.last?.duration(), 4.5 * 3600, "middagblok")
            expect(entries.allSatisfy { $0.status == .completed }, "beide blokken zijn afgerond")
        }

        test("tijdens een handmatige pauze start een contextevent niets") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Kantoor A", .start, "2026-09-10 09:00")
            _ = try fixture.tracker.pause(profileId: fixture.profileA.id, now: at("2026-09-10 12:00"))

            let outcome = try fixture.event("Kantoor A", .start, "2026-09-10 12:10")

            expectEqual(outcome, .pausedManually)
            expect(try fixture.store.runningEntry(profileId: fixture.profileA.id) == nil, "de pauze blijft staan")
        }

        test("een blok dat te lang loopt wordt 'open' en vraagt om correctie") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Kantoor A", .start, "2026-09-10 09:00")

            try fixture.tracker.tick(now: at("2026-09-11 09:00"))

            let entry = try expectNotNil(try fixture.store.entry(id: 1))
            expectEqual(entry.status, .open, "status na een te lang blok")
            expect(entry.endedAt == nil, "er wordt geen einde verzonnen")
            expectEqual(try fixture.tracker.status(now: at("2026-09-11 09:00")).mode, .attention)
        }

        test("de menubalk toont de verstreken tijd van het lopende blok") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA, number: "2401", name: "Migratie")
            _ = try fixture.event("Kantoor A", .start, "2026-09-10 09:00")

            let status = try fixture.tracker.status(now: at("2026-09-10 10:35"))

            expectEqual(status.mode, .working)
            expectEqual(status.menuBarTitle, "1:35")
            expectEqual(status.primary?.project?.label, "2401 — Migratie")
        }
    }
}
