import Foundation
import TickoalaCore

func projectChecks() {
    suite("Projects") {
        test("project numbers are unique within an organization") {
            let fixture = try Fixture()
            _ = try fixture.store.createProject(profileId: fixture.profileA.id, number: "2401", name: "Migration")

            expectThrows({
                _ = try fixture.store.createProject(profileId: fixture.profileA.id, number: "2401", name: "Something else")
            }, "the same number may not appear twice within one organization")

            // The same number at the other organization is fine.
            _ = try fixture.store.createProject(profileId: fixture.profileB.id, number: "2401", name: "Other work")
            expectEqual(try fixture.store.projects(profileId: fixture.profileB.id).count, 1)
        }

        test("a context name belongs to exactly one profile") {
            let fixture = try Fixture()
            expectThrows({
                _ = try fixture.store.createProfile(name: "Organization C", contexts: ["Office A"])
            }, "two profiles on the same context is not allowed")
        }

        test("switching projects during work splits the block") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA, number: "2401", name: "Migration")
            let maintenance = try fixture.store.createProject(profileId: fixture.profileA.id, number: "2402", name: "Maintenance")
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")

            _ = try fixture.tracker.selectProject(profileId: fixture.profileA.id, projectId: maintenance.id, now: at("2026-09-10 11:00"))
            _ = try fixture.tracker.stop(profileId: fixture.profileA.id, now: at("2026-09-10 12:00"))

            let entries = try fixture.entries()
            expectEqual(entries.count, 2, "number of blocks after a switch")
            expectEqual(entries.first?.duration(), 2 * 3600, "time stays with the first project")
            expectEqual(entries.last?.projectId, maintenance.id, "the new block belongs to the new project")
            expectEqual(entries.last?.duration(), 3600)
        }

        test("choosing the same project again does not split anything") {
            let fixture = try Fixture()
            let project = try fixture.project(fixture.profileA)
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")

            _ = try fixture.tracker.selectProject(profileId: fixture.profileA.id, projectId: project.id, now: at("2026-09-10 11:00"))

            expectEqual(try fixture.entries().count, 1)
        }

        test("a deactivated project leaves existing blocks alone but no longer starts") {
            let fixture = try Fixture()
            let project = try fixture.project(fixture.profileA)
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")
            _ = try fixture.tracker.stop(profileId: fixture.profileA.id, now: at("2026-09-10 12:00"))

            try fixture.store.updateProject(id: project.id, active: false)

            expectEqual(try fixture.entries().count, 1, "the registration remains")
            expectEqual(try fixture.event("Office A", .start, "2026-09-10 13:00"), .needsProject(profileId: fixture.profileA.id))
        }

        test("a project of another profile cannot be chosen") {
            let fixture = try Fixture()
            let projectB = try fixture.store.createProject(profileId: fixture.profileB.id, number: "B-1", name: "Other work")

            expectThrows({
                _ = try fixture.tracker.selectProject(profileId: fixture.profileA.id, projectId: projectB.id)
            }, "projects stay within their own organization")
        }

        test("the first project of an organization immediately becomes the active project") {
            let fixture = try Fixture()

            let first = try fixture.tracker.createProject(profileId: fixture.profileA.id, number: "2401", name: "Migration")
            expectEqual(try fixture.store.state(profileId: fixture.profileA.id).activeProjectId, first.id)

            // A second project must not just take over the running choice.
            let second = try fixture.tracker.createProject(profileId: fixture.profileA.id, number: "2402", name: "Maintenance")
            expectEqual(try fixture.store.state(profileId: fixture.profileA.id).activeProjectId, first.id,
                        "the active project stays put at \(second.number)")
        }

        test("a new project starts automatically on arrival right away") {
            let fixture = try Fixture()
            _ = try fixture.tracker.createProject(profileId: fixture.profileA.id, number: "2401", name: "Migration")

            let outcome = try fixture.event("Office A", .start, "2026-09-10 09:00")

            expect(outcome.isStarted, "without a separate project choice this should already work, got \(outcome)")
        }

        test("a project number can be changed afterwards") {
            let fixture = try Fixture()
            let project = try fixture.store.createProject(profileId: fixture.profileA.id, number: "001", name: "AI Platform")
            _ = try fixture.store.createProject(profileId: fixture.profileA.id, number: "002", name: "Maintenance")

            try fixture.store.updateProject(id: project.id, number: "2401", name: "AI Platform")
            expectEqual(try fixture.store.project(id: project.id)?.label, "2401 — AI Platform")
            expect(try fixture.store.project(profileId: fixture.profileA.id, number: "001") == nil, "the old number is free")

            // Renumbering to an existing number is not allowed.
            expectThrows({
                try fixture.store.updateProject(id: project.id, number: "002")
            }, "collision with an existing project number")
            expectEqual(try fixture.store.project(id: project.id)?.number, "2401", "the number stayed put")

            // Saving the same value again is allowed.
            try fixture.store.updateProject(id: project.id, number: "2401", name: "AI platform")
            expectEqual(try fixture.store.project(id: project.id)?.name, "AI platform")
        }

        test("renumbering leaves existing time entries intact") {
            let fixture = try Fixture()
            let project = try fixture.tracker.createProject(profileId: fixture.profileA.id, number: "001", name: "AI Platform")
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")
            _ = try fixture.tracker.stop(profileId: fixture.profileA.id, now: at("2026-09-10 17:00"))

            try fixture.store.updateProject(id: project.id, number: "2401")

            let entry = try expectNotNil(try fixture.entries().first)
            expectEqual(entry.projectId, project.id, "the block still belongs to the same project")
            expectEqual(entry.duration(), 8 * 3600)
        }

        test("the menu bar label is 'number — name'") {
            let fixture = try Fixture()
            let project = try fixture.project(fixture.profileA, number: "2401", name: "Data warehouse migration")
            expectEqual(project.label, "2401 — Data warehouse migration")
        }

        test("multiple active projects ask for a choice") {
            let fixture = try Fixture()
            let project1 = try fixture.store.createProject(profileId: fixture.profileA.id, number: "2401", name: "Migration")
            let project2 = try fixture.store.createProject(profileId: fixture.profileA.id, number: "2402", name: "Maintenance")

            let outcome = try fixture.event("Office A", .start, "2026-09-10 09:00")

            if case .needsProjectChoice(let profileId, let projectIds) = outcome {
                expectEqual(profileId, fixture.profileA.id)
                expectEqual(projectIds.count, 2)
                expect(projectIds.contains(project1.id), "project1 must be in the list")
                expect(projectIds.contains(project2.id), "project2 must be in the list")
            } else {
                Harness.record("expected needsProjectChoice, got \(outcome)")
            }

            expect(try fixture.store.runningEntry(profileId: fixture.profileA.id) == nil, "no timer may be running")
        }

        test("one active project without a chosen project gives needsProject") {
            let fixture = try Fixture()
            _ = try fixture.store.createProject(profileId: fixture.profileA.id, number: "2401", name: "Migration")

            let outcome = try fixture.event("Office A", .start, "2026-09-10 09:00")

            expectEqual(outcome, .needsProject(profileId: fixture.profileA.id))
        }
    }
}
