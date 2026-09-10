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
    /// Geregistreerde tijd, vóór pauzeaftrek.
    public var total: TimeInterval
    public var breakDeduction: TimeInterval

    public var net: TimeInterval { max(0, total - breakDeduction) }
}

public struct Report: Sendable {
    public var period: ReportPeriod
    public var range: DateRange
    /// Bruto: alles wat er aan blokken staat, zonder pauzeaftrek.
    public var total: TimeInterval
    /// Som van de automatische pauzeaftrek over de dagen in dit venster.
    public var breakDeduction: TimeInterval
    /// De per-project verdeling blijft bruto: pauze hangt aan een dag, niet aan een project.
    public var byProject: [ProjectTotal]
    public var byDay: [DayTotal]
    public var openCount: Int
    public var runningCount: Int

    /// Wat er onder de streep overblijft.
    public var netTotal: TimeInterval { max(0, total - breakDeduction) }
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
        // Pauze wordt per klant én per dag bepaald: elke klant heeft een eigen regel.
        var perProfileDay: [ProfileDay: TimeInterval] = [:]
        var total: TimeInterval = 0
        for entry in entries {
            let duration = entry.duration(now: now)
            let day = calendar.startOfDay(for: entry.startedAt)
            total += duration
            perProject[entry.projectId, default: 0] += duration
            perDay[day, default: 0] += duration
            perProfileDay[ProfileDay(profileId: entry.profileId, day: day), default: 0] += duration
        }

        var breakPerDay: [Date: TimeInterval] = [:]
        var breakTotal: TimeInterval = 0
        var rules: [Int64: BreakRule] = [:]
        for (key, worked) in perProfileDay {
            let rule: BreakRule
            if let cached = rules[key.profileId] {
                rule = cached
            } else {
                rule = try store.profile(id: key.profileId)?.breakRule ?? .default
                rules[key.profileId] = rule
            }
            let deduction = rule.deduction(forDayTotal: worked)
            guard deduction > 0 else { continue }
            breakPerDay[key.day, default: 0] += deduction
            breakTotal += deduction
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

        let byDay = perDay
            .map { DayTotal(day: $0.key, total: $0.value, breakDeduction: breakPerDay[$0.key] ?? 0) }
            .sorted { $0.day < $1.day }

        return Report(
            period: period,
            range: range,
            total: total,
            breakDeduction: breakTotal,
            byProject: byProject,
            byDay: byDay,
            openCount: entries.filter { $0.status == .open }.count,
            runningCount: entries.filter { $0.status == .running }.count
        )
    }

    /// Aftrek per klant per dag binnen een venster. Gebruikt voor totalen en export.
    public static func breakDeductions(
        store: Store,
        from: Date,
        to: Date,
        profileId: Int64? = nil,
        now: Date = Date(),
        calendar: Calendar = Formatting.calendar
    ) throws -> [ProfileDay: TimeInterval] {
        var worked: [ProfileDay: TimeInterval] = [:]
        for entry in try store.entries(from: from, to: to, profileId: profileId) {
            let key = ProfileDay(profileId: entry.profileId, day: calendar.startOfDay(for: entry.startedAt))
            worked[key, default: 0] += entry.duration(now: now)
        }

        var rules: [Int64: BreakRule] = [:]
        var result: [ProfileDay: TimeInterval] = [:]
        for (key, total) in worked {
            let rule: BreakRule
            if let cached = rules[key.profileId] {
                rule = cached
            } else {
                rule = try store.profile(id: key.profileId)?.breakRule ?? .default
                rules[key.profileId] = rule
            }
            let deduction = rule.deduction(forDayTotal: total)
            if deduction > 0 { result[key] = deduction }
        }
        return result
    }
}

/// Eén klant op één dag: de eenheid waarover pauze wordt berekend.
public struct ProfileDay: Hashable, Sendable {
    public var profileId: Int64
    public var day: Date

    public init(profileId: Int64, day: Date) {
        self.profileId = profileId
        self.day = day
    }
}
