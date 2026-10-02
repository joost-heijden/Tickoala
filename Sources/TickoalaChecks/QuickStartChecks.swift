import Foundation
import TickoalaCore

func quickStartChecks() {
    suite("quick start") {
        test("recent projects list the newest client+project pairs first") {
            let fixture = try Fixture()
            let acme = try fixture.project(fixture.profileA)
            let beta = try fixture.project(fixture.profileB)
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: acme.id,
                startedAt: at("2026-01-01 09:00"), endedAt: at("2026-01-01 10:00"),
                status: .completed, source: .manual, note: nil
            )
            _ = try fixture.store.createEntry(
                profileId: fixture.profileB.id, projectId: beta.id,
                startedAt: at("2026-01-05 09:00"), endedAt: at("2026-01-05 10:00"),
                status: .completed, source: .manual, note: nil
            )
            let recents = try fixture.store.recentProjects(now: at("2026-01-06 12:00"))
            expectEqual(recents.count, 2)
            expectEqual(recents.first?.profileId, fixture.profileB.id, "the newest pair comes first")
            expectEqual(recents.first?.projectId, beta.id)
        }

        test("the same pair appears once, with its latest start") {
            let fixture = try Fixture()
            let acme = try fixture.project(fixture.profileA)
            for day in ["2026-01-01", "2026-01-03", "2026-01-02"] {
                _ = try fixture.store.createEntry(
                    profileId: fixture.profileA.id, projectId: acme.id,
                    startedAt: at("\(day) 09:00"), endedAt: at("\(day) 10:00"),
                    status: .completed, source: .manual, note: nil
                )
            }
            let recents = try fixture.store.recentProjects(now: at("2026-01-04 12:00"))
            expectEqual(recents.count, 1, "one row per pair")
            expectEqual(recents.first?.startedAt, at("2026-01-03 09:00"), "the latest start")
        }

        test("pairs older than the look-back window are left out") {
            let fixture = try Fixture()
            let acme = try fixture.project(fixture.profileA)
            _ = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: acme.id,
                startedAt: at("2026-01-01 09:00"), endedAt: at("2026-01-01 10:00"),
                status: .completed, source: .manual, note: nil
            )
            _ = try fixture.store.createEntry(
                profileId: fixture.profileB.id, projectId: nil,
                startedAt: at("2026-06-01 09:00"), endedAt: at("2026-06-01 10:00"),
                status: .completed, source: .manual, note: nil
            )
            let recents = try fixture.store.recentProjects(days: 30, now: at("2026-06-02 12:00"))
            expectEqual(recents.count, 1, "only the recent one")
            expectEqual(recents.first?.projectId, nil, "a block without a project still counts")
        }

        test("the limit caps the list") {
            let fixture = try Fixture()
            for index in 0..<6 {
                let project = try fixture.store.createProject(
                    profileId: fixture.profileA.id, number: "\(index)", name: "P\(index)"
                )
                _ = try fixture.store.createEntry(
                    profileId: fixture.profileA.id, projectId: project.id,
                    startedAt: at("2026-01-0\(index + 1) 09:00"),
                    endedAt: at("2026-01-0\(index + 1) 10:00"),
                    status: .completed, source: .manual, note: nil
                )
            }
            expectEqual(try fixture.store.recentProjects(limit: 3, now: at("2026-01-10 12:00")).count, 3)
        }
    }
}
