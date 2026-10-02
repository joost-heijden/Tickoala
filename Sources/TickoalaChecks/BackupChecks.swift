import Foundation
import TickoalaCore

func backupChecks() {
    suite("backup and restore") {
        test("a backup is a complete, readable copy") {
            let fixture = try Fixture()
            let project = try fixture.project(fixture.profileA)
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: project.id,
                startedAt: at("2026-01-05 09:00"), endedAt: at("2026-01-05 17:00"),
                status: .completed, source: .manual, note: "work"
            )
            let url = URL(fileURLWithPath: NSTemporaryDirectory() + "tickoala-backup-\(UUID().uuidString).sqlite3")
            defer { Fixture.remove(url.path) }

            try Backup.write(store: fixture.store, to: url)
            let peeked = try Backup.peek(at: url)
            expectEqual(peeked.profiles, 2, "both fixture clients")
            expectEqual(peeked.entries, 1)
            expectEqual(peeked.projects, 1)

            // The copy opens as a normal store with the same data.
            let reopened = try Store(path: url.path)
            let entries = try reopened.entries(from: at("2026-01-05 00:00"), to: at("2026-01-06 00:00"))
            expectEqual(entries.count, 1)
            expectEqual(entries.first?.note, "work")
        }

        test("a backup overwrites an existing file") {
            let fixture = try Fixture()
            let url = URL(fileURLWithPath: NSTemporaryDirectory() + "tickoala-backup-\(UUID().uuidString).sqlite3")
            defer { Fixture.remove(url.path) }
            try "not a database".write(to: url, atomically: true, encoding: .utf8)
            try Backup.write(store: fixture.store, to: url)
            _ = try Backup.peek(at: url)
        }

        test("peeking a non-database file is refused") {
            let url = URL(fileURLWithPath: NSTemporaryDirectory() + "not-tickoala-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: url) }
            try "hello".write(to: url, atomically: true, encoding: .utf8)
            expectThrows({ _ = try Backup.peek(at: url) }, "not a Tickoala database")
        }

        test("restoring brings back an older state, keeping the old file aside") {
            let fixture = try Fixture()
            let project = try fixture.project(fixture.profileA)
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: project.id,
                startedAt: at("2026-01-05 09:00"), endedAt: at("2026-01-05 17:00"),
                status: .completed, source: .manual, note: "before"
            )
            let backupURL = URL(fileURLWithPath: NSTemporaryDirectory() + "tickoala-backup-\(UUID().uuidString).sqlite3")
            defer { Fixture.remove(backupURL.path) }
            try Backup.write(store: fixture.store, to: backupURL)

            // Change the live database after the backup.
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: project.id,
                startedAt: at("2026-01-06 09:00"), endedAt: at("2026-01-06 17:00"),
                status: .completed, source: .manual, note: "after"
            )
            expectEqual(
                try fixture.store.entries(from: at("2026-01-01 00:00"), to: at("2026-01-31 00:00")).count, 2
            )

            // Restore needs the live database closed: drop the fixture's handle by
            // pointing restore at a fresh file path and reopening.
            let destination = URL(fileURLWithPath: NSTemporaryDirectory() + "tickoala-live-\(UUID().uuidString).sqlite3")
            defer { Fixture.remove(destination.path) }
            // Seed the destination with the current (two-entry) state.
            try Backup.write(store: fixture.store, to: destination)

            try Backup.restore(from: backupURL, to: destination)

            let restored = try Store(path: destination.path)
            let entries = try restored.entries(from: at("2026-01-01 00:00"), to: at("2026-01-31 00:00"))
            expectEqual(entries.count, 1, "the state before the extra block is back")
            expectEqual(entries.first?.note, "before")

            // The replaced database is kept aside.
            let directory = destination.deletingLastPathComponent()
            let side = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasPrefix(destination.lastPathComponent + ".pre-restore-") }
            expect(!side.isEmpty, "the previous database was kept beside it")
        }

        test("the file name is dated") {
            let name = Backup.suggestedFileName(now: at("2026-10-02 12:00"))
            expectEqual(name, "tickoala-backup-2026-10-02.sqlite3")
        }
    }
}
