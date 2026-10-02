import Foundation
import TickoalaCore

func idleChecks() {
    suite("idle detection") {
        test("discarded idle time lowers the worked duration, the block stays whole") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")
            _ = try fixture.tracker.stop(profileId: fixture.profileA.id, now: at("2026-09-10 17:00"))

            try fixture.tracker.addIdle(entryId: 1, seconds: 45 * 60)

            let entry = try expectNotNil(fixture.store.entry(id: 1))
            expectEqual(entry.startedAt, at("2026-09-10 09:00"), "the raw start is untouched")
            expectEqual(entry.endedAt, at("2026-09-10 17:00"), "the raw end is untouched")
            expectEqual(entry.grossDuration(), 8 * 3600)
            expectEqual(entry.idleSeconds, 45 * 60)
            expectEqual(entry.duration(), 8 * 3600 - 45 * 60, "idle comes off the worked time")
            expectEqual(try fixture.entries().count, 1, "still one block for the whole day")
        }

        test("idle is capped by what is left after the break") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")
            _ = try fixture.tracker.stop(profileId: fixture.profileA.id, now: at("2026-09-10 17:00"))
            _ = try fixture.store.setBreak(
                id: 1, breakStart: at("2026-09-10 12:00"), breakEnd: at("2026-09-10 12:30")
            )

            try fixture.tracker.addIdle(entryId: 1, seconds: 99 * 3600)

            let entry = try expectNotNil(fixture.store.entry(id: 1))
            expectEqual(entry.idleSeconds, 8 * 3600 - 30 * 60, "never more than is left after the break")
            expectEqual(entry.duration(), 0, "a duration never goes negative")
        }

        test("idle is accumulated and never negative") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")
            _ = try fixture.tracker.stop(profileId: fixture.profileA.id, now: at("2026-09-10 17:00"))

            try fixture.tracker.addIdle(entryId: 1, seconds: 10 * 60)
            try fixture.tracker.addIdle(entryId: 1, seconds: 20 * 60)
            try fixture.tracker.addIdle(entryId: 1, seconds: -5 * 60)

            let entry = try expectNotNil(fixture.store.entry(id: 1))
            expectEqual(entry.idleSeconds, 30 * 60, "stretches add up, a negative one is ignored")
        }

        test("idle on an unknown block is refused") {
            let fixture = try Fixture()
            expectThrows({ try fixture.tracker.addIdle(entryId: 42, seconds: 60) }, "unknown block")
        }

        test("the idle threshold setting round-trips and defaults to off") {
            let fixture = try Fixture()
            expectEqual(try fixture.store.settings().idleThresholdMinutes, 0, "off by default")
            try fixture.store.setSetting(key: "idle-threshold-minutes", value: 20)
            expectEqual(try fixture.store.settings().idleThresholdMinutes, 20)
        }

        test("a recreated block keeps its idle time") {
            let fixture = try Fixture()
            try fixture.project(fixture.profileA)
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")
            _ = try fixture.tracker.stop(profileId: fixture.profileA.id, now: at("2026-09-10 17:00"))
            try fixture.tracker.addIdle(entryId: 1, seconds: 30 * 60)

            let entry = try expectNotNil(fixture.store.entry(id: 1))
            _ = try fixture.store.createEntry(
                profileId: entry.profileId,
                projectId: entry.projectId,
                startedAt: entry.startedAt,
                endedAt: entry.endedAt,
                breakStartedAt: entry.breakStartedAt,
                breakEndedAt: entry.breakEndedAt,
                idleSeconds: entry.idleSeconds,
                status: entry.status,
                source: entry.source,
                kind: entry.kind,
                note: entry.note
            )

            let restored = try expectNotNil(fixture.store.entry(id: 2))
            expectEqual(restored.idleSeconds, 30 * 60, "a restored block keeps its idle time")
        }
    }
}
