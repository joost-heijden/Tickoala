import Foundation

public enum ReportPeriod: String, CaseIterable, Sendable {
    case day
    case week
    case month

    public var label: String {
        switch self {
        case .day: return "Dag"
        case .week: return "Week"
        case .month: return "Maand"
        }
    }
}

public struct DateRange: Equatable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

public struct ProjectTotal: Equatable, Sendable {
    public var projectId: Int64?
    public var label: String
    public var total: TimeInterval
}

public struct DayTotal: Equatable, Sendable {
    public var day: Date
    public var total: TimeInterval
}

public struct Report: Sendable {
    public var period: ReportPeriod
    public var range: DateRange
    public var total: TimeInterval
    public var byProject: [ProjectTotal]
    public var byDay: [DayTotal]
    public var openCount: Int
    public var runningCount: Int
}

public enum Reporting {
    /// Halfopen venster [start, end) rond `date`, met maandag als eerste weekdag.
    public static func range(_ period: ReportPeriod, containing date: Date, calendar: Calendar = Formatting.calendar) -> DateRange {
        let component: Calendar.Component
        switch period {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        }
        guard let interval = calendar.dateInterval(of: component, for: date) else {
            let start = calendar.startOfDay(for: date)
            return DateRange(start: start, end: calendar.date(byAdding: .day, value: 1, to: start) ?? date)
        }
        return DateRange(start: interval.start, end: interval.end)
    }

    public static func report(
        store: Store,
        period: ReportPeriod,
        containing date: Date,
        profileId: Int64? = nil,
        now: Date = Date(),
        calendar: Calendar = Formatting.calendar
    ) throws -> Report {
        let range = range(period, containing: date, calendar: calendar)
        let entries = try store.entries(from: range.start, to: range.end, profileId: profileId)

        var perProject: [Int64?: TimeInterval] = [:]
        var perDay: [Date: TimeInterval] = [:]
        var total: TimeInterval = 0
        for entry in entries {
            let duration = entry.duration(now: now)
            total += duration
            perProject[entry.projectId, default: 0] += duration
            perDay[calendar.startOfDay(for: entry.startedAt), default: 0] += duration
        }

        var byProject: [ProjectTotal] = []
        for (projectId, seconds) in perProject {
            let label: String
            if let projectId, let project = try store.project(id: projectId) {
                label = project.label
            } else {
                label = "(geen project)"
            }
            byProject.append(ProjectTotal(projectId: projectId, label: label, total: seconds))
        }
        byProject.sort { ($0.total, $1.label) > ($1.total, $0.label) }

        let byDay = perDay.map { DayTotal(day: $0.key, total: $0.value) }.sorted { $0.day < $1.day }

        return Report(
            period: period,
            range: range,
            total: total,
            byProject: byProject,
            byDay: byDay,
            openCount: entries.filter { $0.status == .open }.count,
            runningCount: entries.filter { $0.status == .running }.count
        )
    }
}
