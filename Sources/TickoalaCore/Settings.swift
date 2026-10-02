import Foundation

/// Whether an automatic start asks which project to work on, and when.
public enum ProjectPrompt: Int, CaseIterable, Sendable {
    /// Start straight away on the active project.
    case never = 0
    /// Ask on the first start of the day; later arrivals start on the active project.
    case firstOfDay = 1
    /// Ask on every arrival at a client.
    case everyArrival = 2

    public var label: String {
        switch self {
        case .never: return "Never ask"
        case .firstOfDay: return "On the first start of the day"
        case .everyArrival: return "On every arrival"
        }
    }
}

/// Configurable thresholds. Stored in the `settings` table.
public struct TrackerSettings: Equatable, Sendable {
    /// Time window within which identical ControlPlane events count as a repeat.
    public var dedupeWindowSeconds: Int
    /// A running block longer than this is not credible (sleep, crash) and needs correction.
    public var maxEntrySeconds: Int
    /// Minutes since midnight at which the workday ends. A block that saw a stop
    /// signal or that never got a signal is closed here instead of running into
    /// the night; it is the default last moment of the day.
    public var workdayEndMinutes: Int
    /// Minutes since midnight at which the workday starts. Automatic check-ins
    /// within half an hour of it are recorded as this time, so arriving at 08:07
    /// with an 08:00 start still counts from 08:00.
    public var workdayStartMinutes: Int
    /// Whether an automatic start asks which project to work on, and when.
    public var projectPrompt: ProjectPrompt
    /// Whether reaching a project's hour budget is warned about at 80% and 100%.
    /// Off by default: a project budget alone turns the burn-down on, this switch
    /// only adds the notification, so nothing is enforced.
    public var budgetWarningsEnabled: Bool
    /// How long without keyboard or mouse input counts as being away, in minutes.
    /// While a block runs, coming back after longer than this asks whether to
    /// discard that time. Zero turns the check off, which is the default.
    public var idleThresholdMinutes: Int
    /// Whether tags are shown and editable at all. Off by default: the field,
    /// the overview column and the tag filter stay hidden, and imported tags are
    /// kept in the database but not surfaced until this is switched on.
    public var tagsEnabled: Bool
    /// How much to work on a day, in minutes, across all clients. Zero turns the
    /// daily goal off, which is the default.
    public var dailyGoalMinutes: Int
    /// How much to work in a week, in minutes, across all clients. Zero turns the
    /// weekly goal off, which is the default.
    public var weeklyGoalMinutes: Int

    public static let `default` = TrackerSettings(
        dedupeWindowSeconds: 30,
        maxEntrySeconds: 16 * 3600,
        workdayEndMinutes: 18 * 60,
        workdayStartMinutes: 8 * 60,
        projectPrompt: .never,
        budgetWarningsEnabled: false,
        idleThresholdMinutes: 0,
        tagsEnabled: false,
        dailyGoalMinutes: 0,
        weeklyGoalMinutes: 0
    )

    public init(
        dedupeWindowSeconds: Int,
        maxEntrySeconds: Int,
        workdayEndMinutes: Int = 18 * 60,
        workdayStartMinutes: Int = 8 * 60,
        projectPrompt: ProjectPrompt = .never,
        budgetWarningsEnabled: Bool = false,
        idleThresholdMinutes: Int = 0,
        tagsEnabled: Bool = false,
        dailyGoalMinutes: Int = 0,
        weeklyGoalMinutes: Int = 0
    ) {
        self.dedupeWindowSeconds = dedupeWindowSeconds
        self.maxEntrySeconds = maxEntrySeconds
        self.workdayEndMinutes = workdayEndMinutes
        self.workdayStartMinutes = workdayStartMinutes
        self.projectPrompt = projectPrompt
        self.budgetWarningsEnabled = budgetWarningsEnabled
        self.idleThresholdMinutes = max(0, idleThresholdMinutes)
        self.tagsEnabled = tagsEnabled
        self.dailyGoalMinutes = max(0, dailyGoalMinutes)
        self.weeklyGoalMinutes = max(0, weeklyGoalMinutes)
    }

    static let keys = [
        "dedupe-window-seconds", "max-entry-seconds",
        "workday-end-minutes", "workday-start-minutes",
        "project-prompt", "budget-warnings", "idle-threshold-minutes",
        "tags-enabled", "daily-goal-minutes", "weekly-goal-minutes",
    ]

    mutating func set(_ key: String, _ value: Int) -> Bool {
        switch key {
        case "dedupe-window-seconds": dedupeWindowSeconds = value
        case "max-entry-seconds": maxEntrySeconds = value
        case "workday-end-minutes": workdayEndMinutes = min(max(0, value), 24 * 60)
        case "workday-start-minutes": workdayStartMinutes = min(max(0, value), 24 * 60)
        case "project-prompt":
            projectPrompt = ProjectPrompt(rawValue: min(max(0, value), ProjectPrompt.allCases.count - 1)) ?? .never
        case "budget-warnings": budgetWarningsEnabled = value != 0
        case "idle-threshold-minutes": idleThresholdMinutes = min(max(0, value), 24 * 60)
        case "tags-enabled": tagsEnabled = value != 0
        case "daily-goal-minutes": dailyGoalMinutes = min(max(0, value), 24 * 60)
        case "weekly-goal-minutes": weeklyGoalMinutes = min(max(0, value), 7 * 24 * 60)
        default: return false
        }
        return true
    }

    /// The configured end of the workday on the day of `date`.
    public func endOfWorkday(for date: Date) -> Date {
        dayTime(workdayEndMinutes, on: date)
    }

    /// The configured start of the workday on the day of `date`.
    public func startOfWorkday(for date: Date) -> Date {
        dayTime(workdayStartMinutes, on: date)
    }

    private func dayTime(_ minutes: Int, on date: Date) -> Date {
        let calendar = Formatting.calendar
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .minute, value: minutes, to: start) ?? start
    }

    /// A detected moment rounded to the nearest whole or half hour. Within half an
    /// hour of the workday start it becomes that start, so an early check-in is
    /// not counted from a random minute.
    public func roundedStart(_ date: Date) -> Date {
        let start = startOfWorkday(for: date)
        if abs(date.timeIntervalSince(start)) <= 30 * 60 { return start }
        return Self.roundedToHalfHour(date)
    }

    /// A detected moment rounded to the nearest whole or half hour.
    public func roundedEnd(_ date: Date) -> Date {
        Self.roundedToHalfHour(date)
    }

    private static func roundedToHalfHour(_ date: Date) -> Date {
        let calendar = Formatting.calendar
        let startOfDay = calendar.startOfDay(for: date)
        let halfHour: TimeInterval = 30 * 60
        let rounded = (date.timeIntervalSince(startOfDay) / halfHour).rounded() * halfHour
        return startOfDay.addingTimeInterval(rounded)
    }
}
