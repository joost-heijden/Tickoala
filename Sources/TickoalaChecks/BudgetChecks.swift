import Foundation
import TickoalaCore

func budgetChecks() {
    suite("Project budgets") {
        test("a budget is stored per project and can be changed or cleared") {
            let fixture = try Fixture()
            let project = try fixture.store.createProject(
                profileId: fixture.profileA.id, number: "2401", name: "Fixed price", budgetMinutes: 4800
            )
            expectEqual(try fixture.store.project(id: project.id)?.budgetMinutes, 4800)
            expect(try fixture.store.project(id: project.id)?.hasBudget == true, "4800 minutes is a budget")

            try fixture.store.updateProject(id: project.id, budgetMinutes: 9600)
            expectEqual(try fixture.store.project(id: project.id)?.budgetMinutes, 9600)

            // Clearing the budget switches the burn-down off again.
            try fixture.store.updateProject(id: project.id, budgetMinutes: 0)
            expect(try fixture.store.project(id: project.id)?.hasBudget == false, "zero means no budget")

            // A negative budget is never stored.
            try fixture.store.updateProject(id: project.id, budgetMinutes: -10)
            expectEqual(try fixture.store.project(id: project.id)?.budgetMinutes, 0)
        }

        test("a new project has no budget, so the feature is off by default") {
            let fixture = try Fixture()
            let project = try fixture.store.createProject(profileId: fixture.profileA.id, number: "2401", name: "Migration")
            expectEqual(project.budgetMinutes, 0)
            expect(project.hasBudget == false, "no budget until one is set")
        }

        test("the burn-down counts every block of the project, breaks taken off") {
            let fixture = try Fixture()
            let project = try fixture.tracker.createProject(
                profileId: fixture.profileA.id, number: "2401", name: "Fixed price", budgetMinutes: 240
            )
            // 4 hours with a recorded half-hour break: 3.5 hours count.
            let entry = try fixture.store.createEntry(
                profileId: fixture.profileA.id, projectId: project.id,
                startedAt: at("2026-09-10 09:00"), endedAt: at("2026-09-10 13:00"),
                status: .completed, source: .manual, note: nil
            )
            try fixture.store.setBreak(id: entry.id, breakStart: at("2026-09-10 12:00"), breakEnd: at("2026-09-10 12:30"))

            let usage = try fixture.store.projectUsageSeconds(now: at("2026-09-10 18:00"))
            expectEqual(usage[project.id], 3.5 * 3600, "the recorded break is not counted")

            let budget = ProjectBudget(
                budgetSeconds: project.budgetSeconds, usedSeconds: usage[project.id] ?? 0
            )
            expectEqual(budget.remainingSeconds, 0.5 * 3600)
            expectEqual(budget.level, .nearLimit, "3.5 of 4 hours is past 80%")
        }

        test("the burn-down counts a running block up to now") {
            let fixture = try Fixture()
            let project = try fixture.tracker.createProject(
                profileId: fixture.profileA.id, number: "2401", name: "Fixed price", budgetMinutes: 480
            )
            _ = try fixture.event("Office A", .start, "2026-09-10 09:00")

            let usage = try fixture.store.projectUsageSeconds(now: at("2026-09-10 12:00"))
            expectEqual(usage[project.id], 3 * 3600, "a running block counts to the measurement moment")
        }

        test("the level crosses at 80% and 100%") {
            let budget: TimeInterval = 100 * 3600
            expectEqual(ProjectBudget(budgetSeconds: budget, usedSeconds: 79 * 3600).level, .ok)
            expectEqual(ProjectBudget(budgetSeconds: budget, usedSeconds: 80 * 3600).level, .nearLimit)
            expectEqual(ProjectBudget(budgetSeconds: budget, usedSeconds: 99 * 3600).level, .nearLimit)
            expectEqual(ProjectBudget(budgetSeconds: budget, usedSeconds: 100 * 3600).level, .exceeded)
            expectEqual(ProjectBudget(budgetSeconds: budget, usedSeconds: 130 * 3600).level, .exceeded)
            expectEqual(ProjectBudget(budgetSeconds: 0, usedSeconds: 10 * 3600).level, .none, "no budget, no level")
        }

        test("crossedLevel warns once per threshold") {
            let budget: TimeInterval = 100 * 3600
            let near = ProjectBudget(budgetSeconds: budget, usedSeconds: 80 * 3600)
            let over = ProjectBudget(budgetSeconds: budget, usedSeconds: 100 * 3600)

            expectEqual(near.crossedLevel(above: .none), .nearLimit, "the first crossing warns")
            expect(near.crossedLevel(above: .nearLimit) == nil, "the same threshold does not warn twice")
            expectEqual(over.crossedLevel(above: .nearLimit), .exceeded, "the next threshold warns")
            expect(over.crossedLevel(above: .exceeded) == nil, "past 100% nothing warns again")
            expect(ProjectBudget(budgetSeconds: budget, usedSeconds: 79 * 3600).crossedLevel(above: .none) == nil)
        }

        test("over budget reports how far over, and the summary reads well") {
            let budget = ProjectBudget(budgetSeconds: 20 * 3600, usedSeconds: 23 * 3600)
            expect(budget.isOver, "past the budget")
            expectEqual(budget.remainingSeconds, 0, "nothing left when over")
            expectEqual(budget.overSeconds, 3 * 3600)
            expectEqual(budget.summary, "23:00 used of 20:00 — over by 3:00")
            expectEqual(ProjectBudget(budgetSeconds: 20 * 3600, usedSeconds: 5 * 3600).summary,
                        "5:00 used of 20:00 — 15:00 left")
        }

        test("an hour budget is read as hours, decimal or h:mm") {
            expectEqual(Formatting.parseHoursMinutes("80"), 4800)
            expectEqual(Formatting.parseHoursMinutes("80.5"), 4830)
            expectEqual(Formatting.parseHoursMinutes("80,5"), 4830)
            expectEqual(Formatting.parseHoursMinutes("1:30"), 90)
            expectEqual(Formatting.parseHoursMinutes("80h"), 4800)
            expectEqual(Formatting.parseHoursMinutes("0"), 0)
            expect(Formatting.parseHoursMinutes("junk") == nil, "junk gives nil")
            expect(Formatting.parseHoursMinutes("-4") == nil, "negative gives nil")
            expect(Formatting.parseHoursMinutes("1:75") == nil, "minutes past the hour give nil")
        }

        test("budget warnings are off by default and can be switched on") {
            let fixture = try Fixture()
            expect(try fixture.store.settings().budgetWarningsEnabled == false, "off by default")

            try fixture.store.setSetting(key: "budget-warnings", value: 1)
            expect(try fixture.store.settings().budgetWarningsEnabled, "switched on")

            try fixture.store.setSetting(key: "budget-warnings", value: 0)
            expect(try fixture.store.settings().budgetWarningsEnabled == false, "switched off again")
        }
    }
}
