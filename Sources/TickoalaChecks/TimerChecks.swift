import Foundation
import TickoalaCore

func timerChecks() {
    suite("Timer logic") {
        test("a start event begins a block on the active project") {
            let fixture = try Fixture()
            let project = try fixture.project(fixture.profileA)

            let outcome = try fixture.event("Office A", .start, "2026-09-10 09:00")

            expect(outcome.isStarted, "expected a started block, got \(outcome)")
            let running = try expectNotNil(try fixture.store.runningEntry(profileId: fixture.profileA.id))
            expectEqual(running.projectId, project.id, "block project")
            expectEqual(running.startedAt, at("2026-09-10 09:00"), "start time")
            expectEqual(running.source, .controlplane, "source")
        }

        test("without a chosen project the tracker does not start automatically") {
            let fixture = try Fixture()

            let outcome = try fixture.event("Office A", .start, "2026-09-10 09:00")

            expectEqual(outcome, .needsProject(profileId: fixture.profileA.id))
            expect(try fixture.store.runningEntry(profileId: fixture.profileA.id) == nil, "no timer may be running")
            expect(try fixture.store.state(profileId: fixture.profileA.id).attention != nil, "the user must get a notice")
        }

        test("a second start does not make a second block") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)

            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")
            // Well outside the dedupe window, so this event is really evaluated.
            let second = try fixture.event("Office A", .start, "2026-09-10 10:00")

            expectEqual(second, .alreadyRunning(entryId: 1))
            expectEqual(try fixture.entries().count, 1, "number of blocks")
        }

        test("repeated events within the time window are ignored") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)

            _ = try fixture.event("Office A", .start, "2026-09-10 09:00:00")
            let repeated = try fixture.event("Office A", .start, "2026-09-10 09:00:20")

            expectEqual(repeated, .ignoredDuplicate)
            expectEqual(try fixture.store.recentEvents().count, 1, "number of logged events")
        }

        test("a repeat just across the bucket boundary also counts as a repeat") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            try fixture.store.setSetting(key: "dedupe-window-seconds", value: 30)

            // 09:00:29 and 09:00:31 fall in different 30-second buckets.
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00:29")
            let repeated = try fixture.event("Office A", .start, "2026-09-10 09:00:31")

            expectEqual(repeated, .ignoredDuplicate)
        }

        test("an unknown Wi-Fi context does nothing automatically") {
            let fixture = try Fixture()

            let outcome = try fixture.event("Café", .start, "2026-09-10 09:00")

            expectEqual(outcome, .ignoredUnknownContext)
            expect(try fixture.store.runningEntries().isEmpty, "no timer may be running")
            expectEqual(try fixture.store.recentEvents().count, 1, "an ignored event is logged too")
        }

        test("an inactive profile does not react to its context") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            try fixture.store.updateProfile(id: fixture.profileA.id, active: false)

            expectEqual(try fixture.event("Office A", .start, "2026-09-10 09:00"), .ignoredInactiveProfile)
            expect(try fixture.store.runningEntries().isEmpty, "no timer may be running")
        }

        test("stop waits out the grace period and uses the moment of the signal") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            try fixture.store.setSetting(key: "stop-grace-seconds", value: 90)
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")

            let outcome = try fixture.event("Office A", .stop, "2026-09-10 17:00")
            expectEqual(outcome, .stopScheduled(effectiveAt: at("2026-09-10 17:01:30")))
            expect(try fixture.store.runningEntry(profileId: fixture.profileA.id) != nil, "the timer is still running during the grace period")

            _ = try fixture.tracker.finalizePendingStops(now: at("2026-09-10 17:00:45"))
            expect(try fixture.store.runningEntry(profileId: fixture.profileA.id) != nil, "halfway through the grace period nothing stops yet")

            let closed = try fixture.tracker.finalizePendingStops(now: at("2026-09-10 17:01:31"))
            expectEqual(closed.count, 1, "number of closed blocks")
            let entry = try expectNotNil(try fixture.store.entry(id: 1))
            expectEqual(entry.status, .completed)
            expectEqual(entry.endedAt, at("2026-09-10 17:00"), "the end is the moment of the stop signal")
            expectEqual(entry.duration(), 8 * 3600, "duration in seconds")
        }

        test("a brief Wi-Fi dropout does not close the block") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            try fixture.store.setSetting(key: "stop-grace-seconds", value: 90)
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")

            _ = try fixture.event("Office A", .stop, "2026-09-10 11:00")
            let back = try fixture.event("Office A", .start, "2026-09-10 11:00:40")

            expectEqual(back, .stopCancelled(entryId: 1))
            try fixture.tracker.tick(now: at("2026-09-10 11:05"))
            let entry = try expectNotNil(try fixture.store.entry(id: 1))
            expectEqual(entry.status, .running, "the block keeps running")
            expect(entry.endedAt == nil, "no end was recorded")
            expectEqual(try fixture.entries().count, 1, "no second block")
        }

        test("a stop from the past becomes final immediately") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")

            let outcome = try fixture.tracker.handle(
                ContextEvent(context: "Office A", kind: .stop, at: at("2026-09-10 17:00")),
                now: at("2026-09-10 17:30")
            )

            expectEqual(outcome, .stopped(entryId: 1))
            let entry = try expectNotNil(try fixture.store.entry(id: 1))
            expectEqual(entry.endedAt, at("2026-09-10 17:00"))
        }

        test("leaving without a running timer only produces a log line") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)

            let outcome = try fixture.event("Office A", .stop, "2026-09-10 17:00")

            expectEqual(outcome, .noRunningTimer)
            expect(try fixture.entries().isEmpty, "no empty block appears")
            expectEqual(try fixture.store.recentEvents().count, 1, "the departure is logged though")
        }

        test("two work contexts at once stop nothing and ask for a choice") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA, number: "2401")
            try fixture.project(fixture.profileB, number: "B-1")
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")

            let outcome = try fixture.event("Office B", .start, "2026-09-10 09:30")

            expectEqual(outcome, .conflict(runningProfileId: fixture.profileA.id))
            expect(try fixture.store.runningEntry(profileId: fixture.profileA.id) != nil, "the first block keeps running")
            expect(try fixture.store.runningEntry(profileId: fixture.profileB.id) == nil, "the second profile does not start")
            expectEqual(try fixture.tracker.status(now: at("2026-09-10 09:30")).mode, .attention)
        }

        test("pausing closes the block, resuming starts a new block") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")

            _ = try fixture.tracker.pause(profileId: fixture.profileA.id, now: at("2026-09-10 12:00"))
            expectEqual(try fixture.tracker.status(now: at("2026-09-10 12:15")).mode, .paused)

            _ = try fixture.tracker.resume(profileId: fixture.profileA.id, now: at("2026-09-10 12:30"))
            _ = try fixture.tracker.stop(profileId: fixture.profileA.id, now: at("2026-09-10 17:00"))

            let entries = try fixture.entries()
            expectEqual(entries.count, 2, "pausing splits the day into two blocks")
            expectEqual(entries.first?.duration(), 3 * 3600, "morning block")
            expectEqual(entries.last?.duration(), 4.5 * 3600, "afternoon block")
            expect(entries.allSatisfy { $0.status == .completed }, "both blocks are completed")
        }

        test("during a manual pause a context event starts nothing") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")
            _ = try fixture.tracker.pause(profileId: fixture.profileA.id, now: at("2026-09-10 12:00"))

            let outcome = try fixture.event("Office A", .start, "2026-09-10 12:10")

            expectEqual(outcome, .pausedManually)
            expect(try fixture.store.runningEntry(profileId: fixture.profileA.id) == nil, "the pause stays in place")
        }

        test("a block that runs too long becomes 'open' and asks for correction") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")

            try fixture.tracker.tick(now: at("2026-09-11 09:00"))

            let entry = try expectNotNil(try fixture.store.entry(id: 1))
            expectEqual(entry.status, .open, "status after a block that ran too long")
            expect(entry.endedAt == nil, "no end is invented")
            expectEqual(try fixture.tracker.status(now: at("2026-09-11 09:00")).mode, .attention)
        }

        test("the menu bar shows the elapsed time of the running block") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA, number: "2401", name: "Migration")
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")

            let status = try fixture.tracker.status(now: at("2026-09-10 10:35"))

            expectEqual(status.mode, .working)
            expectEqual(status.menuBarTitle, "1:35")
            expectEqual(status.primary?.project?.label, "2401 — Migration")
        }
    }
}
