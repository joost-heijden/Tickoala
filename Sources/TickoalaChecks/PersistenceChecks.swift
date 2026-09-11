import Foundation
import TickoalaCore

func persistenceChecks() {
    suite("Opslag en herstart") {
        test("een lopende timer overleeft het herstarten van de app") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Kantoor A", .start, "2026-09-10 09:00")
            let path = fixture.path

            // Tweede proces: zelfde bestand, nieuwe verbinding.
            let herstart = Tracker(store: try Store(path: path))
            let status = try herstart.status(now: at("2026-09-10 10:00"))

            expectEqual(status.mode, .working)
            expectEqual(status.menuBarTitle, "1:00")
            expectEqual(status.primary?.profile.name, "Organisatie A")
        }

        test("een uitgestelde stop overleeft een herstart en sluit alsnog netjes af") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            try fixture.store.setSetting(key: "stop-grace-seconds", value: 90)
            _ = try fixture.event("Kantoor A", .start, "2026-09-10 09:00")
            _ = try fixture.event("Kantoor A", .stop, "2026-09-10 17:00")
            let path = fixture.path

            let herstart = Tracker(store: try Store(path: path))
            try herstart.tick(now: at("2026-09-10 17:05"))

            let entry = try expectNotNil(try herstart.store.entry(id: 1))
            expectEqual(entry.status, .completed)
            expectEqual(entry.endedAt, at("2026-09-10 17:00"), "het einde blijft het moment van vertrek")
        }

        test("het schema wordt maar één keer aangelegd") {
            let path = NSTemporaryDirectory() + "tickoala-check-\(UUID().uuidString).sqlite3"
            defer { Fixture.remove(path) }
            let eerste = try Store(path: path)
            _ = try eerste.createProfile(name: "Organisatie A", contexts: ["Kantoor A"])

            let tweede = try Store(path: path)
            expectEqual(try tweede.profiles().count, 1, "migraties draaien niet opnieuw")
        }

        test("instellingen blijven bewaard") {
            let fixture = try Fixture()
            try fixture.store.setSetting(key: "stop-grace-seconds", value: 120)
            let opnieuw = try Store(path: fixture.path)
            expectEqual(try opnieuw.settings().stopGraceSeconds, 120)
            expectThrows({ try fixture.store.setSetting(key: "onzin", value: 1) }, "onbekende sleutels worden geweigerd")
        }

        test("blokken corrigeren en verwijderen werkt") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Kantoor A", .start, "2026-09-10 09:00")
            _ = try fixture.tracker.stop(profileId: fixture.profileA.id, now: at("2026-09-10 12:00"))

            try fixture.store.updateEntry(id: 1, endedAt: .some(at("2026-09-10 12:30")), note: .some("nagekomen overleg"))
            var entry = try expectNotNil(try fixture.store.entry(id: 1))
            expectEqual(entry.duration(), 3.5 * 3600)
            expectEqual(entry.note, "nagekomen overleg")

            try fixture.store.updateEntry(id: 1, note: .some(nil))
            entry = try expectNotNil(try fixture.store.entry(id: 1))
            expect(entry.note == nil, "een notitie kan ook weer weg")

            try fixture.store.deleteEntry(id: 1)
            expect(try fixture.entries().isEmpty, "het blok is verwijderd")
            expectThrows({ try fixture.store.deleteEntry(id: 1) }, "een onbekend blok geeft een fout")
        }

        test("blokken kunnen worden gedupliceerd") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Kantoor A", .start, "2026-09-10 09:00")
            _ = try fixture.tracker.stop(profileId: fixture.profileA.id, now: at("2026-09-10 12:00"))
            try fixture.store.updateEntry(id: 1, note: .some("nagekomen overleg"))

            let origineel = try expectNotNil(try fixture.store.entry(id: 1))
            let kopie = try expectNotNil(try fixture.store.duplicateEntry(id: 1))

            expect(kopie.id != origineel.id, "een kopie krijgt een nieuw id")
            expectEqual(kopie.profileId, origineel.profileId)
            expectEqual(kopie.projectId, origineel.projectId)
            expectEqual(kopie.startedAt, origineel.startedAt)
            expectEqual(kopie.endedAt, origineel.endedAt)
            expectEqual(kopie.status, origineel.status)
            expectEqual(kopie.source, origineel.source)
            expectEqual(kopie.note, origineel.note)
            expectEqual(try fixture.entries().count, 2, "het origineel blijft staan")
        }

        test("een lopend blok kan niet worden gedupliceerd") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Kantoor A", .start, "2026-09-10 09:00")

            expectThrows({ _ = try fixture.store.duplicateEntry(id: 1) }, "een lopend blok wordt geweigerd")
            expectEqual(try fixture.entries().count, 1, "er wordt geen kopie aangemaakt")
        }

        test("een open blok kan wel worden gedupliceerd") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id,
                projectId: nil,
                startedAt: at("2026-09-10 09:00"),
                endedAt: nil,
                status: .open,
                source: .manual,
                note: nil
            )

            let kopie = try expectNotNil(try fixture.store.duplicateEntry(id: 1))
            expectEqual(kopie.status, .open)
            expect(kopie.endedAt == nil, "een open blok houdt geen einde")
            expectEqual(try fixture.entries().count, 2)
        }

        test("een onbekend blok kan niet worden gedupliceerd") {
            let fixture = try Fixture()
            expectThrows({ _ = try fixture.store.duplicateEntry(id: 42) }, "een onbekend blok wordt geweigerd")
        }

        test("een blok kan met een pauze in tweeën worden geknipt") {
            let fixture = try Fixture()
            let project = try fixture.project(fixture.profileA)
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id,
                projectId: project.id,
                startedAt: at("2026-09-10 09:00"),
                endedAt: at("2026-09-10 17:00"),
                status: .completed,
                source: .manual,
                note: "overleg"
            )

            let tweede = try fixture.store.splitEntry(
                id: 1,
                pauseStart: at("2026-09-10 12:00"),
                pauseEnd: at("2026-09-10 12:30")
            )

            let eerste = try expectNotNil(try fixture.store.entry(id: 1))
            expectEqual(eerste.endedAt, at("2026-09-10 12:00"), "het eerste blok stopt bij de pauze")
            expectEqual(eerste.duration(), 3 * 3600)
            expectEqual(tweede.startedAt, at("2026-09-10 12:30"), "het tweede blok begint na de pauze")
            expectEqual(tweede.endedAt, at("2026-09-10 17:00"))
            expectEqual(tweede.projectId, project.id)
            expectEqual(tweede.note, "overleg")
            expectEqual(tweede.duration(), 4.5 * 3600)
            expectEqual(try fixture.entries().count, 2, "de pauze is een gat, geen derde blok")
        }

        test("een pauze buiten het blok wordt geweigerd") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Kantoor A", .start, "2026-09-10 09:00")
            _ = try fixture.tracker.stop(profileId: fixture.profileA.id, now: at("2026-09-10 17:00"))

            expectThrows({ _ = try fixture.store.splitEntry(id: 1, pauseStart: at("2026-09-10 08:00"), pauseEnd: at("2026-09-10 08:30")) }, "pauze voor het begin")
            expectThrows({ _ = try fixture.store.splitEntry(id: 1, pauseStart: at("2026-09-10 17:00"), pauseEnd: at("2026-09-10 17:30")) }, "pauze na het einde")
            expectThrows({ _ = try fixture.store.splitEntry(id: 1, pauseStart: at("2026-09-10 12:30"), pauseEnd: at("2026-09-10 12:00")) }, "omgekeerde pauze")
            expectEqual(try fixture.entries().count, 1, "er is niets gesplitst")
        }

        test("een lopend blok kan niet worden gesplitst") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Kantoor A", .start, "2026-09-10 09:00")

            expectThrows({ _ = try fixture.store.splitEntry(id: 1, pauseStart: at("2026-09-10 10:00"), pauseEnd: at("2026-09-10 10:30")) }, "een lopend blok wordt geweigerd")
            expectEqual(try fixture.entries().count, 1)
        }
    }
}
