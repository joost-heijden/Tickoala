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
    /// Recorded time with any recorded breaks already taken off, but before the
    /// automatic break deduction.
    public var total: TimeInterval
    /// Sum of the automatic break deduction over the days in this window.
    public var breakDeduction: TimeInterval
    /// The automatic deduction per client per day, so a row can show the break
    /// that applies to it. Only days with a deduction appear.
    public var breakByProfileDay: [ProfileDay: TimeInterval]
    /// The per-project distribution stays gross of the automatic deduction: that
    /// break belongs to a day, not to a project.
    public var byProject: [ProjectTotal]
    /// The same distribution after the automatic break deduction: what the
    /// invoice shows, net hours per project without a separate deduction line.
    public var byProjectNet: [ProjectTotal]
    public var byDay: [DayTotal]
    /// The distribution per client, including break deduction and the amount at the rate.
    public var byProfile: [ProfileTotal]
    /// Net seconds per kind (work, travel, commute). Work carries the automatic
    /// break deduction; travel and commute do not.
    public var byKind: [EntryKind: TimeInterval]
    /// Net work seconds per tag, sorted by size. A block with several tags counts
    /// in full for each, so the totals can overlap; empty when nothing is tagged.
    public var byTag: [ProjectTotal]
    /// Whether any block in the window carries a tag, so the tag breakdown only
    /// appears when there is something to show.
    public var hasTags: Bool
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

    /// Whether the overview anchor should follow the clock to a new day. True only
    /// when the day has rolled over since `lastDay` and the anchor was still on that
    /// day; a day the user navigated to stays put.
    public static func shouldFollowToday(
        anchor: Date,
        lastDay: Date,
        now: Date,
        calendar: Calendar = Formatting.calendar
    ) -> Bool {
        calendar.startOfDay(for: now) != lastDay && calendar.isDate(anchor, inSameDayAs: lastDay)
    }

    public static func report(
        store: Store,
        period: ReportPeriod,
        containing date: Date,
        profileId: Int64? = nil,
        now: Date = Date(),
        calendar: Calendar = Formatting.calendar
    ) throws -> Report {
        try report(
            store: store,
            range: range(period, containing: date, calendar: calendar),
            profileId: profileId,
            now: now,
            calendar: calendar
        )
    }

    /// The same over an explicit half-open window, for a period that is not one
    /// of the day/week/month shapes (such as a two-week invoice).
    public static func report(
        store: Store,
        range: DateRange,
        profileId: Int64? = nil,
        now: Date = Date(),
        calendar: Calendar = Formatting.calendar
    ) throws -> Report {
        let entries = try store.entries(from: range.start, to: range.end, profileId: profileId)

        var perProject: [Int64?: TimeInterval] = [:]
        // Per day and project, so the automatic break can be charged against the
        // project actually worked that day.
        var perProjectDay: [ProfileDay: [Int64?: TimeInterval]] = [:]
        var perDay: [Date: TimeInterval] = [:]
        // A break is determined per client and per day: every client has its own rule.
        var perProfileDay: [ProfileDay: TimeInterval] = [:]
        var perProfileGross: [Int64: TimeInterval] = [:]
        // Seconds per client and per kind, so travel and commute can be billed at
        // their own rate without touching the project breakdown.
        var perProfileKind: [Int64: [EntryKind: TimeInterval]] = [:]
        var perKind: [EntryKind: TimeInterval] = [:]
        // Tag labels keyed case-insensitively, so "Meeting" and "meeting" merge.
        var perTag: [String: TimeInterval] = [:]
        var tagLabels: [String: String] = [:]
        var hasTags = false
        // A block with a recorded break has already lost that break from its
        // duration. On such a day the automatic rule steps aside, so nothing is
        // deducted twice.
        var manualBreakDay: [ProfileDay: TimeInterval] = [:]
        var total: TimeInterval = 0
        for entry in entries {
            let duration = entry.duration(now: now)
            let day = calendar.startOfDay(for: entry.startedAt)
            total += duration
            perDay[day, default: 0] += duration
            perProfileKind[entry.profileId, default: [:]][entry.kind, default: 0] += duration
            perKind[entry.kind, default: 0] += duration
            // Tags attach to work only, like projects and the break rule.
            if entry.kind == .work, !entry.tags.isEmpty {
                hasTags = true
                for tag in entry.tags {
                    let key = tag.lowercased()
                    tagLabels[key] = tagLabels[key] ?? tag
                    perTag[key, default: 0] += duration
                }
            }
            // Only work counts towards a project and towards the break rule; travel
            // and commute are their own thing.
            guard entry.kind == .work else { continue }
            perProject[entry.projectId, default: 0] += duration
            perProjectDay[ProfileDay(profileId: entry.profileId, day: day), default: [:]][entry.projectId, default: 0] += duration
            perProfileDay[ProfileDay(profileId: entry.profileId, day: day), default: 0] += duration
            perProfileGross[entry.profileId, default: 0] += duration
            if entry.breakDuration > 0 {
                manualBreakDay[ProfileDay(profileId: entry.profileId, day: day), default: 0] += entry.breakDuration
            }
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
        let breakPerProfileDay = try deductions(for: perProfileDay, manualBreak: manualBreakDay) {
            try loadProfile($0)?.breakRule ?? .default
        }
        for (key, deduction) in breakPerProfileDay {
            breakPerDay[key.day, default: 0] += deduction
            breakPerProfile[key.profileId, default: 0] += deduction
        }
        let breakTotal = breakPerProfileDay.values.reduce(0, +)

        // Work carries the automatic break; travel and commute are untouched.
        var byKind = perKind
        byKind[.work] = max(0, (perKind[.work] ?? 0) - breakTotal)

        // Charge each day's automatic break against that day's projects, so an
        // invoice can show net hours per project without a deduction line.
        // ponytail: a day spread over several projects splits the break in
        // proportion to that day's hours per project.
        var netPerProject: [Int64?: TimeInterval] = [:]
        for (key, projects) in perProjectDay {
            let dayTotal = projects.values.reduce(0, +)
            let deducted = min(breakPerProfileDay[key] ?? 0, dayTotal)
            let share = dayTotal > 0 ? (dayTotal - deducted) / dayTotal : 1
            for (projectId, seconds) in projects {
                netPerProject[projectId, default: 0] += seconds * share
            }
        }

        var byProfile: [ProfileTotal] = []
        for (profileId, kinds) in perProfileKind {
            let profile = try loadProfile(profileId)
            let gross = kinds.values.reduce(0, +)
            let breakDeduction = breakPerProfile[profileId] ?? 0
            let workNet = max(0, (kinds[.work] ?? 0) - breakDeduction)
            let rate = profile?.hourlyRateCents ?? 0
            var amount = profile?.amountCents(for: workNet) ?? 0
            if let profile {
                amount += profile.amountCents(for: kinds[.travel] ?? 0, rateCents: profile.rateCents(for: .travel))
                amount += profile.amountCents(for: kinds[.commute] ?? 0, rateCents: profile.rateCents(for: .commute))
            }
            byProfile.append(ProfileTotal(
                label: profile?.name ?? "?",
                total: gross,
                breakDeduction: breakDeduction,
                hourlyRateCents: rate,
                currency: profile?.currency ?? .eur,
                amountCents: amount
            ))
        }
        byProfile.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }

        func projectTotals(_ seconds: [Int64?: TimeInterval]) throws -> [ProjectTotal] {
            var totals: [ProjectTotal] = []
            for (projectId, value) in seconds {
                let label: String
                if let projectId, let project = try store.project(id: projectId) {
                    label = project.label
                } else {
                    label = "(no project)"
                }
                totals.append(ProjectTotal(label: label, total: value))
            }
            totals.sort { ($0.total, $1.label) > ($1.total, $0.label) }
            return totals
        }
        let byProject = try projectTotals(perProject)
        let byProjectNet = try projectTotals(netPerProject)

        let byDay = perDay
            .map { DayTotal(day: $0.key, total: $0.value, breakDeduction: breakPerDay[$0.key] ?? 0) }
            .sorted { $0.day < $1.day }

        let byTag = perTag
            .map { ProjectTotal(label: tagLabels[$0.key] ?? $0.key, total: $0.value) }
            .sorted { ($0.total, $1.label) > ($1.total, $0.label) }

        return Report(
            range: range,
            total: total,
            breakDeduction: breakTotal,
            breakByProfileDay: breakPerProfileDay,
            byProject: byProject,
            byProjectNet: byProjectNet,
            byDay: byDay,
            byProfile: byProfile,
            byKind: byKind,
            byTag: byTag,
            hasTags: hasTags,
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
        var manualBreak: [ProfileDay: TimeInterval] = [:]
        for entry in try store.entries(from: from, to: to, profileId: profileId) where entry.kind == .work {
            let key = ProfileDay(profileId: entry.profileId, day: calendar.startOfDay(for: entry.startedAt))
            worked[key, default: 0] += entry.duration(now: now)
            manualBreak[key, default: 0] += entry.breakDuration
        }
        return try deductions(for: worked, manualBreak: manualBreak) {
            try store.profile(id: $0)?.breakRule ?? .default
        }
    }

    /// Break deduction per client per day, with each client's rule looked up once.
    /// A day with a recorded break is left alone: that break was already taken off
    /// the block, so the automatic rule would otherwise deduct twice. Only days
    /// with a positive deduction appear in the result.
    static func deductions(
        for worked: [ProfileDay: TimeInterval],
        manualBreak: [ProfileDay: TimeInterval] = [:],
        loadRule: (Int64) throws -> BreakRule
    ) rethrows -> [ProfileDay: TimeInterval] {
        var rules: [Int64: BreakRule] = [:]
        var result: [ProfileDay: TimeInterval] = [:]
        for (key, total) in worked {
            guard (manualBreak[key] ?? 0) <= 0 else { continue }
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
