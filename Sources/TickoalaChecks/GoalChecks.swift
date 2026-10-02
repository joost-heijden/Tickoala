import Foundation
import TickoalaCore

func goalChecks() {
    suite("goals") {
        test("a zero target means the goal is off") {
            expect(Goal(minutes: 0, workedSeconds: 3600) == nil)
            let off = Goal(targetSeconds: 0, workedSeconds: 3600)
            expect(!off.isSet)
            expectEqual(off.fraction, 0)
            expectEqual(off.percent, 0)
        }

        test("progress, remainder and percentage") {
            let goal = try expectNotNil(Goal(minutes: 8 * 60, workedSeconds: 4 * 3600))
            expectEqual(goal.targetSeconds, 8 * 3600)
            expectEqual(goal.fraction, 0.5)
            expectEqual(goal.percent, 50)
            expectEqual(goal.remainingSeconds, 4 * 3600)
            expect(!goal.isReached)
        }

        test("reaching and passing the goal") {
            let reached = try expectNotNil(Goal(minutes: 6 * 60, workedSeconds: 6 * 3600))
            expect(reached.isReached)
            expectEqual(reached.remainingSeconds, 0)
            expectEqual(reached.fraction, 1, "the bar never overflows")

            let over = try expectNotNil(Goal(minutes: 6 * 60, workedSeconds: 9 * 3600))
            expect(over.isReached)
            expectEqual(over.percent, 150, "the percentage can pass 100")
            expectEqual(over.overSeconds, 3 * 3600)
            expectEqual(over.fraction, 1)
        }

        test("the goal is a calculation, not stored time") {
            let goal = try expectNotNil(Goal(minutes: 60, workedSeconds: 1800))
            expectEqual(goal.summary, "0:30 of 1:00 · 50%")
        }

        test("the goal settings round-trip through the store, off by default") {
            let fixture = try Fixture()
            expectEqual(try fixture.store.settings().dailyGoalMinutes, 0, "off by default")
            expectEqual(try fixture.store.settings().weeklyGoalMinutes, 0)
            try fixture.store.setSetting(key: "daily-goal-minutes", value: 480)
            try fixture.store.setSetting(key: "weekly-goal-minutes", value: 2400)
            expectEqual(try fixture.store.settings().dailyGoalMinutes, 480)
            expectEqual(try fixture.store.settings().weeklyGoalMinutes, 2400)
        }
    }
}
