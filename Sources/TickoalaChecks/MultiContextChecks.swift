import Foundation
import TickoalaCore

/// One customer can have multiple Wi-Fi networks (guest + staff, or several
/// locations). These checks cover that a profile can then start, stop and roam
/// through each of those contexts without creating a second block.
func multiContextChecks() {
    suite("Multiple Wi-Fi networks per customer") {
        test("a profile can be created with multiple contexts") {
            let fixture = try Fixture()
            let profile = try fixture.store.createProfile(name: "Acme", contexts: ["Acme-Guest", "Acme-Staff"])

            expectEqual(Set(profile.contexts), Set(["Acme-Guest", "Acme-Staff"]))
            expectEqual(try fixture.store.profile(context: "acme-guest")?.id, profile.id, "matching is case-insensitive")
            expectEqual(try fixture.store.profile(context: "Acme-Staff")?.id, profile.id)
        }

        test("a profile without contexts is refused") {
            let fixture = try Fixture()
            expectThrows({ _ = try fixture.store.createProfile(name: "Empty", contexts: []) }, "at least one context is required")
        }

        test("adding and removing a second context works") {
            let fixture = try Fixture()
            let profile = try fixture.store.createProfile(name: "Acme", contexts: ["Acme-Guest"])

            let expanded = try fixture.store.addContext(profileId: profile.id, context: "Acme-Staff")
            expectEqual(Set(expanded.contexts), Set(["Acme-Guest", "Acme-Staff"]))

            let reduced = try fixture.store.removeContext(profileId: profile.id, context: "Acme-Guest")
            expectEqual(reduced.contexts, ["Acme-Staff"])
        }

        test("the same context cannot be linked to a second profile") {
            let fixture = try Fixture()
            let acme = try fixture.store.createProfile(name: "Acme", contexts: ["Acme-Guest"])
            let other = try fixture.store.createProfile(name: "Other customer", contexts: ["Other-Guest"])

            expectThrows({
                _ = try fixture.store.addContext(profileId: other.id, context: "Acme-Guest")
            }, "a context belongs to only one profile")
            expectEqual(try fixture.store.profile(context: "Acme-Guest")?.id, acme.id, "the link stayed with Acme")
        }

        test("starting through each of the linked networks opens the same profile") {
            let fixture = try Fixture()
            let profile = try fixture.store.createProfile(name: "Acme", contexts: ["Acme-Guest", "Acme-Staff"])
            let project = try fixture.store.createProject(profileId: profile.id, number: "1", name: "Maintenance")
            _ = try fixture.tracker.selectProject(profileId: profile.id, projectId: project.id)

            let outcome = try fixture.tracker.handle(
                ContextEvent(context: "Acme-Staff", kind: .start, at: at("2026-09-10 09:00")),
                now: at("2026-09-10 09:00")
            )

            expect(outcome.isStarted, "starting through the second network must work too")
            let running = try expectNotNil(try fixture.store.runningEntry(profileId: profile.id))
            expectEqual(running.profileId, profile.id)
        }

        test("roaming between two networks of the same customer does not split the block") {
            let fixture = try Fixture()
            let profile = try fixture.store.createProfile(name: "Acme", contexts: ["Acme-Guest", "Acme-Staff"])
            let project = try fixture.store.createProject(profileId: profile.id, number: "1", name: "Maintenance")
            _ = try fixture.tracker.selectProject(profileId: profile.id, projectId: project.id)
            try fixture.store.setSetting(key: "stop-grace-seconds", value: 90)

            _ = try fixture.tracker.handle(
                ContextEvent(context: "Acme-Guest", kind: .start, at: at("2026-09-10 09:00")), now: at("2026-09-10 09:00")
            )
            // Moves from the guest network to the staff network: stop on one,
            // start on the other, well within the grace period.
            _ = try fixture.tracker.handle(
                ContextEvent(context: "Acme-Guest", kind: .stop, at: at("2026-09-10 11:00")), now: at("2026-09-10 11:00")
            )
            let back = try fixture.tracker.handle(
                ContextEvent(context: "Acme-Staff", kind: .start, at: at("2026-09-10 11:00:30")), now: at("2026-09-10 11:00:30")
            )

            expectEqual(back, .stopCancelled(entryId: 1), "the switch between networks counts as a brief interruption")
            try fixture.tracker.tick(now: at("2026-09-10 11:05"))
            let entry = try expectNotNil(try fixture.store.entry(id: 1))
            expectEqual(entry.status, .running, "the block keeps running on the other network")
            expectEqual(try fixture.entries().count, 1, "no second block appeared")
        }

        test("CSV export shows all linked contexts of the profile") {
            let fixture = try Fixture()
            let profile = try fixture.store.createProfile(name: "Acme", contexts: ["Acme-Guest", "Acme-Staff"])
            let project = try fixture.store.createProject(profileId: profile.id, number: "1", name: "Maintenance")
            _ = try fixture.store.createEntry(
                profileId: profile.id, projectId: project.id,
                startedAt: at("2026-09-10 09:00"), endedAt: at("2026-09-10 12:00"),
                status: .completed, source: .controlplane, note: nil
            )

            let csv = try CSVExport.export(store: fixture.store, from: at("2026-09-10"), to: at("2026-09-11"))
            expect(csv.contains("Acme-Guest; Acme-Staff"), "both contexts are in the export row: \(csv)")
        }
    }
}
