import Foundation
import TickoalaCore

func tagChecks() {
    suite("tags") {
        test("tags are trimmed, split on commas and semicolons, and deduplicated") {
            expectEqual(Tags.parse("Meeting, admin, , meeting"), ["Meeting", "admin"])
            expectEqual(Tags.parse("a;b; c "), ["a", "b", "c"])
            expectEqual(Tags.parse(nil), [])
            expectEqual(Tags.parse("   "), [])
            expectEqual(Tags.join(["x", "x", ""]), "x")
            expectEqual(Tags.text(["meeting", "admin"]), "meeting, admin")
        }

        test("a block stores its tags and can have them changed or cleared") {
            let fixture = try Fixture()
            let project = try fixture.project(fixture.profileA)
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: project.id,
                startedAt: at("2026-01-05 09:00"), endedAt: at("2026-01-05 10:00"),
                tags: ["meeting", "admin"], status: .completed, source: .manual, note: nil
            )
            expectEqual(try fixture.store.entry(id: 1)?.tags, ["meeting", "admin"])

            try fixture.store.updateEntry(id: 1, tags: ["research"])
            expectEqual(try fixture.store.entry(id: 1)?.tags, ["research"])

            try fixture.store.updateEntry(id: 1, tags: [])
            expectEqual(try fixture.store.entry(id: 1)?.tags, [], "an empty list clears the tags")
        }

        test("a duplicated block keeps its tags") {
            let fixture = try Fixture()
            let project = try fixture.project(fixture.profileA)
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: project.id,
                startedAt: at("2026-01-05 09:00"), endedAt: at("2026-01-05 10:00"),
                tags: ["meeting"], status: .completed, source: .manual, note: "x"
            )
            let copy = try fixture.store.duplicateEntry(id: 1)
            expectEqual(copy.tags, ["meeting"])
        }

        test("the CSV export carries the tags") {
            let fixture = try Fixture()
            let project = try fixture.project(fixture.profileA)
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: project.id,
                startedAt: at("2026-01-05 09:00"), endedAt: at("2026-01-05 10:00"),
                tags: ["meeting", "admin"], status: .completed, source: .manual, note: nil
            )
            let csv = try CSVExport.export(
                store: fixture.store, from: at("2026-01-05 00:00"), to: at("2026-01-06 00:00")
            )
            expect(csv.contains("tags"), "the header has a tags column")
            expect(csv.contains("\"meeting, admin\""), "the tags travel as one quoted field")
        }

        test("an import brings the Tags column across when tags are on") {
            let fixture = try Fixture()
            let csv = """
            Client,Project,Description,Tags,Start date,Start time,End date,End time
            Acme,Website,Copy,"meeting, admin",2026-01-05,09:00:00,2026-01-05,10:00:00
            """
            let entries = try Importer.parse(csv, format: .toggl)
            expectEqual(entries.first?.tags, ["meeting", "admin"])
            _ = try Importer.apply(entries, to: fixture.store, tagsEnabled: true)
            let day = try fixture.store.entries(from: at("2026-01-05 00:00"), to: at("2026-01-06 00:00"))
            expectEqual(day.first?.tags, ["meeting", "admin"])
            expectEqual(day.first?.importedTags, [])
        }

        test("with tags off, an import holds the labels aside, not on the block") {
            let fixture = try Fixture()
            let csv = """
            Client,Project,Description,Tags,Start date,Start time,End date,End time
            Acme,Website,Copy,"meeting",2026-01-05,09:00:00,2026-01-05,10:00:00
            """
            let entries = try Importer.parse(csv, format: .toggl)
            _ = try Importer.apply(entries, to: fixture.store, tagsEnabled: false)
            let day = try fixture.store.entries(from: at("2026-01-05 00:00"), to: at("2026-01-06 00:00"))
            expectEqual(day.first?.tags, [], "not shown while tags are off")
            expectEqual(day.first?.importedTags, ["meeting"], "but kept for later")
        }

        test("the report breaks hours down per tag") {
            let fixture = try Fixture()
            let project = try fixture.project(fixture.profileA)
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: project.id,
                startedAt: at("2026-01-05 09:00"), endedAt: at("2026-01-05 11:00"),
                tags: ["meeting"], status: .completed, source: .manual, note: nil
            )
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: project.id,
                startedAt: at("2026-01-05 11:00"), endedAt: at("2026-01-05 12:00"),
                tags: ["meeting", "admin"], status: .completed, source: .manual, note: nil
            )
            let report = try Reporting.report(
                store: fixture.store, period: .day, containing: at("2026-01-05 12:00")
            )
            expect(report.hasTags)
            let meeting = report.byTag.first { $0.label == "meeting" }
            let admin = report.byTag.first { $0.label == "admin" }
            expectEqual(meeting?.total, 3 * 3600, "both blocks carry meeting")
            expectEqual(admin?.total, 3600)
        }

        test("the tags setting round-trips and defaults to off") {
            let fixture = try Fixture()
            expectEqual(try fixture.store.settings().tagsEnabled, false)
            try fixture.store.setSetting(key: "tags-enabled", value: 1)
            expectEqual(try fixture.store.settings().tagsEnabled, true)
        }
    }
}
