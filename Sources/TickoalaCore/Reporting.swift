import Foundation

public enum ReportPeriod: String, CaseIterable, Sendable {
    case day
    case week
    case month

    public var label: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
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
    public var label: String
    public var total: TimeInterval
}

/// The hours of one client within the window, with the hourly rate. The amount is
/// calculated from the net hours (after break deduction), because that is what
/// gets invoiced.
public struct ProfileTotal: Equatable, Sendable {
    public var label: String
    /// Recorded time, before break deduction.
    public var total: TimeInterval
    public var breakDeduction: TimeInterval
    public var hourlyRateCents: Int
    public var currency: Currency
    public var amountCents: Int

    public var net: TimeInterval { max(0, total - breakDeduction) }
    public var hasHourlyRate: Bool { hourlyRateCents > 0 }
}

public struct DayTotal: Equatable, Sendable {
    public var day: Date
    /// Recorded time, before break deduction.
    public var total: TimeInterval
    public var breakDeduction: TimeInterval

    public var net: TimeInterval { max(0, total - breakDeduction) }
}

public struct Report: Sendable {
    public var range: DateRange
    /// Gross: everything in the blocks, without break deduction.
    public var total: TimeInterval
    /// Sum of the automatic break deduction over the days in this window.
    public var breakDeduction: TimeInterval
    /// The per-project distribution stays gross: a break belongs to a day, not to a project.
    public var byProject: [ProjectTotal]
    public var byDay: [DayTotal]
    /// The distribution per client, including break deduction and the amount at the rate.
    public var byProfile: [ProfileTotal]
    public var openCount: Int
    public var runningCount: Int

    /// What remains after the deduction.
    public var netTotal: TimeInterval { max(0, total - breakDeduction) }

    /// The sum of the amounts of all clients. Clients without a rate count as
    /// zero; if there is no rate anywhere, this is zero too.
    public var amountCents: Int { byProfile.reduce(0) { $0 + $1.amountCents } }
}

public enum Reporting {
    /// Half-open window [start, end) around `date`, with Monday as the first weekday.
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
        // A break is determined per client and per day: every client has its own rule.
        var perProfileDay: [ProfileDay: TimeInterval] = [:]
        var perProfileGross: [Int64: TimeInterval] = [:]
        var total: TimeInterval = 0
        for entry in entries {
            let duration = entry.duration(now: now)
            let day = calendar.startOfDay(for: entry.startedAt)
            total += duration
            perProject[entry.projectId, default: 0] += duration
            perDay[day, default: 0] += duration
            perProfileDay[ProfileDay(profileId: entry.profileId, day: day), default: 0] += duration
            perProfileGross[entry.profileId, default: 0] += duration
        }

        // Load clients once; both the break row and the rate depend on them.
        var profileCache: [Int64: Profile] = [:]
        func loadProfile(_ id: Int64) throws -> Profile? {
            if let cached = profileCache[id] { return cached }
            let loaded = try store.profile(id: id)
            if let loaded { profileCache[id] = loaded }
            return loaded
        }

        var breakPerDay: [Date: TimeInterval] = [:]
        var breakPerProfile: [Int64: TimeInterval] = [:]
        let breakPerProfileDay = try deductions(for: perProfileDay) {
            try loadProfile($0)?.breakRule ?? .default
        }
        for (key, deduction) in breakPerProfileDay {
            breakPerDay[key.day, default: 0] += deduction
            breakPerProfile[key.profileId, default: 0] += deduction
        }
        let breakTotal = breakPerProfileDay.values.reduce(0, +)

        var byProfile: [ProfileTotal] = []
        for (profileId, gross) in perProfileGross {
            let profile = try loadProfile(profileId)
            let breakDeduction = breakPerProfile[profileId] ?? 0
            let net = max(0, gross - breakDeduction)
            let rate = profile?.hourlyRateCents ?? 0
            byProfile.append(ProfileTotal(
                label: profile?.name ?? "?",
                total: gross,
                breakDeduction: breakDeduction,
                hourlyRateCents: rate,
                currency: profile?.currency ?? .eur,
                amountCents: profile?.amountCents(for: net) ?? 0
            ))
        }
        byProfile.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }

        var byProject: [ProjectTotal] = []
        for (projectId, seconds) in perProject {
            let label: String
            if let projectId, let project = try store.project(id: projectId) {
                label = project.label
            } else {
                label = "(no project)"
            }
            byProject.append(ProjectTotal(label: label, total: seconds))
        }
        byProject.sort { ($0.total, $1.label) > ($1.total, $0.label) }

        let byDay = perDay
            .map { DayTotal(day: $0.key, total: $0.value, breakDeduction: breakPerDay[$0.key] ?? 0) }
            .sorted { $0.day < $1.day }

        return Report(
            range: range,
            total: total,
            breakDeduction: breakTotal,
            byProject: byProject,
            byDay: byDay,
            byProfile: byProfile,
            openCount: entries.filter { $0.status == .open }.count,
            runningCount: entries.filter { $0.status == .running }.count
        )
    }

    /// Deduction per client per day within a window. Used for totals and export.
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
        return try deductions(for: worked) { try store.profile(id: $0)?.breakRule ?? .default }
    }

    /// Break deduction per client per day, with each client's rule looked up once.
    /// Only days with a positive deduction appear in the result.
    static func deductions(
        for worked: [ProfileDay: TimeInterval],
        loadRule: (Int64) throws -> BreakRule
    ) rethrows -> [ProfileDay: TimeInterval] {
        var rules: [Int64: BreakRule] = [:]
        var result: [ProfileDay: TimeInterval] = [:]
        for (key, total) in worked {
            let deduction: TimeInterval
            if let cached = rules[key.profileId] {
                deduction = cached.deduction(forDayTotal: total)
            } else {
                let loaded = try loadRule(key.profileId)
                rules[key.profileId] = loaded
                deduction = loaded.deduction(forDayTotal: total)
            }
            if deduction > 0 { result[key] = deduction }
        }
        return result
    }
}

/// One client on one day: the unit over which a break is calculated.
public struct ProfileDay: Hashable, Sendable {
    public var profileId: Int64
    public var day: Date

    public init(profileId: Int64, day: Date) {
        self.profileId = profileId
        self.day = day
    }
}
