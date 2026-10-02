import Foundation
import TickoalaCore

func importChecks() {
    suite("import from another tracker") {
        test("a Toggl export becomes blocks, commas in quotes included") {
            let csv = """
            User,Email,Client,Project,Task,Description,Billable,Start date,Start time,End date,End time,Duration,Tags,Amount
            Jane,jane@example.com,Acme,Website,Design,"Homepage copy",Yes,2026-01-05,09:00:00,2026-01-05,10:30:00,01:30:00,,0.00
            Jane,jane@example.com,Acme,Website,,"Standup, with comma",No,2026-01-05,10:30:00,2026-01-05,10:45:00,00:15:00,,0.00
            """
            let entries = try Importer.parse(csv, format: .toggl)
            expectEqual(entries.count, 2)
            expectEqual(entries[0].client, "Acme")
            expectEqual(entries[0].project, "Website")
            expectEqual(entries[0].note, "Homepage copy")
            expectEqual(entries[0].startedAt, at("2026-01-05 09:00"))
            expectEqual(entries[0].endedAt, at("2026-01-05 10:30"))
            expectEqual(entries[1].note, "Standup, with comma", "a quoted comma stays in the note")
        }

        test("a Clockify export can fall back to the duration column") {
            let csv = """
            Project,Client,Description,Task,Start Date,Start Time,End Date,End Time,Duration (h),Duration (decimal)
            Website,Acme,Design,Task,2026-01-06,09:00:00,,,,00:45:00,
            Website,Acme,Standup,,2026-01-06,10:00:00,2026-01-06,10:30:00,00:30:00,0.50
            """
            let entries = try Importer.parse(csv, format: .clockify)
            expectEqual(entries.count, 2)
            expectEqual(entries[0].note, "Design", "the description wins over the task")
            expectEqual(entries[0].startedAt, at("2026-01-06 09:00"))
            expectEqual(entries[0].endedAt, at("2026-01-06 09:45"), "the duration column fills the end")
            expectEqual(entries[1].startedAt, at("2026-01-06 10:00"))
            expectEqual(entries[1].endedAt, at("2026-01-06 10:30"))
        }

        test("a Harvest export with only hours is laid out back to back") {
            let csv = """
            Date,Client,Project,Task,Notes,Hours,Billable?
            2026-01-05,Acme,Website,Design,Homepage copy,1.5,Yes
            2026-01-05,Acme,Website,Design,Second task,2.0,Yes
            """
            let entries = try Importer.parse(csv, format: .harvest)
            expectEqual(entries.count, 2)
            expectEqual(entries[0].startedAt, at("2026-01-05 09:00"))
            expectEqual(entries[0].endedAt, at("2026-01-05 10:30"))
            expectEqual(entries[1].startedAt, at("2026-01-05 10:30"), "the next block continues")
            expectEqual(entries[1].endedAt, at("2026-01-05 12:30"))
            expectEqual(entries[1].note, "Second task")
        }

        test("a team export can be narrowed to one user") {
            let csv = """
            User,Email,Client,Project,Description,Start date,Start time,End date,End time,Duration
            Jane,jane@example.com,Acme,Website,Copy,2026-01-05,09:00:00,2026-01-05,10:00:00,01:00:00
            Bob,bob@example.com,Acme,Website,Design,2026-01-05,10:00:00,2026-01-05,11:00:00,01:00:00
            """
            expectEqual(try Importer.parse(csv, format: .toggl).count, 2, "without a filter, everyone")
            let jane = try Importer.parse(csv, format: .toggl, user: "jane")
            expectEqual(jane.count, 1)
            expectEqual(jane.first?.note, "Copy")
        }

        test("a Harvest export can be narrowed by employee") {
            let csv = """
            Date,Client,Project,Employee,Notes,Hours
            2026-01-05,Acme,Website,Jane,Task A,1.0
            2026-01-05,Acme,Website,Bob,Task B,2.0
            """
            let bob = try Importer.parse(csv, format: .harvest, user: "Bob")
            expectEqual(bob.count, 1)
            expectEqual(bob.first?.note, "Task B")
            expectEqual(bob.first?.endedAt.timeIntervalSince(bob.first!.startedAt), 2 * 3600)
        }

        test("importing writes clients, projects and imported blocks") {
            let fixture = try Fixture()
            let csv = """
            Client,Project,Description,Start date,Start time,End date,End time
            Acme,Website,Homepage copy,2026-01-05,09:00:00,2026-01-05,10:30:00
            Acme,Website,Standup,2026-01-05,10:30:00,2026-01-05,10:45:00
            """
            let entries = try Importer.parse(csv, format: .toggl)
            let summary = try Importer.apply(entries, to: fixture.store)

            expectEqual(summary.entries, 2)
            expectEqual(summary.profilesCreated, 1, "one new client")
            expectEqual(summary.projectsCreated, 1, "one new project")

            let acme = try expectNotNil(
                try fixture.store.profiles().first { $0.name == "Acme" }
            )
            expect(acme.contexts.isEmpty, "an imported client has no Wi-Fi network yet")
            let projects = try fixture.store.projects(profileId: acme.id)
            expectEqual(projects.count, 1)
            expectEqual(projects.first?.name, "Website")

            let day = try fixture.store.entries(
                from: at("2026-01-05 00:00"), to: at("2026-01-06 00:00")
            )
            expectEqual(day.count, 2)
            expectEqual(day.first?.source, .imported)
            expectEqual(day.first?.kind, .work)
            expectEqual(day.first?.status, .completed)
            expectEqual(day.first?.duration(), 90 * 60)
        }

        test("importing the same file twice adds nothing") {
            let fixture = try Fixture()
            let csv = """
            Client,Project,Description,Start date,Start time,End date,End time
            Acme,Website,Homepage copy,2026-01-05,09:00:00,2026-01-05,10:30:00
            """
            let entries = try Importer.parse(csv, format: .toggl)
            _ = try Importer.apply(entries, to: fixture.store)
            let second = try Importer.apply(entries, to: fixture.store)
            expectEqual(second.entries, 0)
            expectEqual(second.skipped, 1, "already there")
            expectEqual(
                try fixture.store.entries(from: at("2026-01-05 00:00"), to: at("2026-01-06 00:00")).count,
                1
            )
        }

        test("a client name given on the command line overrides the file") {
            let fixture = try Fixture()
            let csv = """
            Client,Project,Description,Start date,Start time,End date,End time
            ,Website,Homepage copy,2026-01-05,09:00:00,2026-01-05,10:30:00
            """
            let entries = try Importer.parse(csv, format: .toggl).map { entry -> ImportedEntry in
                var copy = entry
                copy.client = "Solo"
                return copy
            }
            let summary = try Importer.apply(entries, to: fixture.store)
            expectEqual(summary.profilesCreated, 1)
            _ = try expectNotNil(try fixture.store.profiles().first { $0.name == "Solo" })
        }
    }
}
