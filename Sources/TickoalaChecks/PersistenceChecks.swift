import Foundation
import TickoalaCore

func persistenceChecks() {
    suite("Storage and restart") {
        test("a running timer survives restarting the app") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")
            let path = fixture.path

            // Second process: same file, new connection.
            let restart = Tracker(store: try Store(path: path))
            let status = try restart.status(now: at("2026-09-10 10:00"))

            expectEqual(status.mode, .working)
            expectEqual(status.menuBarTitle, "1:00")
            expectEqual(status.primary?.profile.name, "Organization A")
        }

        test("a delayed stop survives a restart and still closes cleanly") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            try fixture.store.setSetting(key: "stop-grace-seconds", value: 90)
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")
            _ = try fixture.event("Office A", .stop, "2026-09-10 17:00")
            let path = fixture.path

            let restart = Tracker(store: try Store(path: path))
            try restart.tick(now: at("2026-09-10 17:05"))

            let entry = try expectNotNil(try restart.store.entry(id: 1))
            expectEqual(entry.status, .completed)
            expectEqual(entry.endedAt, at("2026-09-10 17:00"), "the end stays the moment of departure")
        }

        test("the schema is only created once") {
            let path = NSTemporaryDirectory() + "tickoala-check-\(UUID().uuidString).sqlite3"
            defer { Fixture.remove(path) }
            let first = try Store(path: path)
            _ = try first.createProfile(name: "Organization A", contexts: ["Office A"])

            let second = try Store(path: path)
            expectEqual(try second.profiles().count, 1, "migrations do not run again")
        }

        test("settings are persisted") {
            let fixture = try Fixture()
            try fixture.store.setSetting(key: "stop-grace-seconds", value: 120)
            let again = try Store(path: fixture.path)
            expectEqual(try again.settings().stopGraceSeconds, 120)
            expectThrows({ try fixture.store.setSetting(key: "junk", value: 1) }, "unknown keys are refused")
        }

        test("correcting and deleting blocks works") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")
            _ = try fixture.tracker.stop(profileId: fixture.profileA.id, now: at("2026-09-10 12:00"))

            try fixture.store.updateEntry(id: 1, endedAt: .some(at("2026-09-10 12:30")), note: .some("catch-up meeting"))
            var entry = try expectNotNil(try fixture.store.entry(id: 1))
            expectEqual(entry.duration(), 3.5 * 3600)
            expectEqual(entry.note, "catch-up meeting")

            try fixture.store.updateEntry(id: 1, note: .some(nil))
            entry = try expectNotNil(try fixture.store.entry(id: 1))
            expect(entry.note == nil, "a note can also be removed again")

            try fixture.store.deleteEntry(id: 1)
            expect(try fixture.entries().isEmpty, "the block was deleted")
            expectThrows({ try fixture.store.deleteEntry(id: 1) }, "an unknown block gives an error")
        }

        test("blocks can be duplicated") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")
            _ = try fixture.tracker.stop(profileId: fixture.profileA.id, now: at("2026-09-10 12:00"))
            try fixture.store.updateEntry(id: 1, note: .some("catch-up meeting"))

            let original = try expectNotNil(try fixture.store.entry(id: 1))
            let copy = try expectNotNil(try fixture.store.duplicateEntry(id: 1))

            expect(copy.id != original.id, "a copy gets a new id")
            expectEqual(copy.profileId, original.profileId)
            expectEqual(copy.projectId, original.projectId)
            expectEqual(copy.startedAt, original.startedAt)
            expectEqual(copy.endedAt, original.endedAt)
            expectEqual(copy.status, original.status)
            expectEqual(copy.source, original.source)
            expectEqual(copy.note, original.note)
            expectEqual(try fixture.entries().count, 2, "the original stays")
        }

        test("a running block cannot be duplicated") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")

            expectThrows({ _ = try fixture.store.duplicateEntry(id: 1) }, "a running block is refused")
            expectEqual(try fixture.entries().count, 1, "no copy is created")
        }

        test("an open block can be duplicated") {
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

            let copy = try expectNotNil(try fixture.store.duplicateEntry(id: 1))
            expectEqual(copy.status, .open)
            expect(copy.endedAt == nil, "an open block keeps no end")
            expectEqual(try fixture.entries().count, 2)
        }

        test("an unknown block cannot be duplicated") {
            let fixture = try Fixture()
            expectThrows({ _ = try fixture.store.duplicateEntry(id: 42) }, "an unknown block is refused")
        }

        test("a block can be cut in two around a break") {
            let fixture = try Fixture()
            let project = try fixture.project(fixture.profileA)
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id,
                projectId: project.id,
                startedAt: at("2026-09-10 09:00"),
                endedAt: at("2026-09-10 17:00"),
                status: .completed,
                source: .manual,
                note: "meeting"
            )

            let second = try fixture.store.splitEntry(
                id: 1,
                pauseStart: at("2026-09-10 12:00"),
                pauseEnd: at("2026-09-10 12:30")
            )

            let first = try expectNotNil(try fixture.store.entry(id: 1))
            expectEqual(first.endedAt, at("2026-09-10 12:00"), "the first block stops at the break")
            expectEqual(first.duration(), 3 * 3600)
            expectEqual(second.startedAt, at("2026-09-10 12:30"), "the second block begins after the break")
            expectEqual(second.endedAt, at("2026-09-10 17:00"))
            expectEqual(second.projectId, project.id)
            expectEqual(second.note, "meeting")
            expectEqual(second.duration(), 4.5 * 3600)
            expectEqual(try fixture.entries().count, 2, "the break is a gap, not a third block")
        }

        test("a break outside the block is refused") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")
            _ = try fixture.tracker.stop(profileId: fixture.profileA.id, now: at("2026-09-10 17:00"))

            expectThrows({ _ = try fixture.store.splitEntry(id: 1, pauseStart: at("2026-09-10 08:00"), pauseEnd: at("2026-09-10 08:30")) }, "break before the start")
            expectThrows({ _ = try fixture.store.splitEntry(id: 1, pauseStart: at("2026-09-10 17:00"), pauseEnd: at("2026-09-10 17:30")) }, "break after the end")
            expectThrows({ _ = try fixture.store.splitEntry(id: 1, pauseStart: at("2026-09-10 12:30"), pauseEnd: at("2026-09-10 12:00")) }, "reversed break")
            expectEqual(try fixture.entries().count, 1, "nothing was split")
        }

        test("a running block cannot be split") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")

            expectThrows({ _ = try fixture.store.splitEntry(id: 1, pauseStart: at("2026-09-10 10:00"), pauseEnd: at("2026-09-10 10:30")) }, "a running block is refused")
            expectEqual(try fixture.entries().count, 1)
        }
    }
}
