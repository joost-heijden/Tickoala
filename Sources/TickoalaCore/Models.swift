import Foundation

/// Automatic break deduction per client. The deduction is a calculation applied
/// on top of the raw blocks: time entries are never modified by it, so the rule
/// can always be adjusted or switched off.
public struct BreakRule: Equatable, Sendable {
    /// Is the automatic deduction enabled for this client?
    public var enabled: Bool
    /// How much break is taken off the hours per worked day.
    public var minutes: Int
    /// The threshold: the deduction only applies from this many worked minutes
    /// on a day. Set independently of the break duration itself.
    public var thresholdMinutes: Int

    /// Off by default; 30 minutes of break from 6 hours of work on a day.
    public static let `default` = BreakRule(enabled: false, minutes: 30, thresholdMinutes: 360)

    public init(enabled: Bool, minutes: Int, thresholdMinutes: Int) {
        self.enabled = enabled
        self.minutes = minutes
        self.thresholdMinutes = thresholdMinutes
    }

    /// Deduction for a single day on which `worked` seconds were recorded.
    /// The threshold is inclusive: at exactly 6 hours the break is already
    /// deducted. It never deducts more than was worked that day, so a day never
    /// goes negative.
    public func deduction(forDayTotal worked: TimeInterval) -> TimeInterval {
        guard enabled, minutes > 0, worked > 0 else { return 0 }
        guard worked >= TimeInterval(thresholdMinutes) * 60 else { return 0 }
        return min(TimeInterval(minutes) * 60, worked)
    }

    /// Short description for lists and menus.
    public var summary: String {
        guard enabled, minutes > 0 else { return "no automatic break deduction" }
        return "\(minutes) min break from \(Formatting.duration(TimeInterval(thresholdMinutes) * 60)) per day"
    }
}

/// How a client's hours are turned into a bill. Everything is off by default:
/// zero rounding, no minimum, no surcharges, which leaves the invoice untouched.
/// Applied when the invoice is built, never to the recorded time.
public struct BillingRules: Equatable, Sendable {
    /// Round invoiced time to this many minutes (15 for quarter hours). 0 = off.
    public var roundingMinutes: Int
    /// Round up instead of to the nearest increment.
    public var roundUp: Bool
    /// Bill at least this many minutes per invoice; 0 = no minimum.
    public var minimumMinutes: Int
    /// Extra percentage on hours worked in the evening (0 = off).
    public var eveningSurchargePercent: Int
    /// Extra percentage on hours worked on Saturday and Sunday (0 = off).
    public var weekendSurchargePercent: Int
    /// When the evening starts, minutes since midnight (default 18:00).
    public var eveningStartMinutes: Int

    public static let `default` = BillingRules()

    public init(
        roundingMinutes: Int = 0,
        roundUp: Bool = false,
        minimumMinutes: Int = 0,
        eveningSurchargePercent: Int = 0,
        weekendSurchargePercent: Int = 0,
        eveningStartMinutes: Int = 18 * 60
    ) {
        self.roundingMinutes = max(0, roundingMinutes)
        self.roundUp = roundUp
        self.minimumMinutes = max(0, minimumMinutes)
        self.eveningSurchargePercent = max(0, eveningSurchargePercent)
        self.weekendSurchargePercent = max(0, weekendSurchargePercent)
        self.eveningStartMinutes = min(max(0, eveningStartMinutes), 24 * 60)
    }

    /// Is any rule set? If not, the invoice is built exactly as before.
    public var isActive: Bool {
        roundingMinutes > 0 || minimumMinutes > 0
            || eveningSurchargePercent > 0 || weekendSurchargePercent > 0
    }

    /// The invoiced time after rounding. Nothing changes while `roundingMinutes`
    /// is zero.
    public func rounded(_ seconds: TimeInterval) -> TimeInterval {
        guard roundingMinutes > 0, seconds > 0 else { return max(0, seconds) }
        let increment = TimeInterval(roundingMinutes) * 60
        let units = seconds / increment
        return (roundUp ? units.rounded(.up) : units.rounded()) * increment
    }

    /// Short description for lists and menus.
    public var summary: String {
        guard isActive else { return "no billing rules" }
        var parts: [String] = []
        if roundingMinutes > 0 {
            parts.append("round \(roundingMinutes) min \(roundUp ? "up" : "nearest")")
        }
        if minimumMinutes > 0 { parts.append("minimum \(Formatting.duration(TimeInterval(minimumMinutes) * 60))") }
        if eveningSurchargePercent > 0 { parts.append("evening +\(eveningSurchargePercent)%") }
        if weekendSurchargePercent > 0 { parts.append("weekend +\(weekendSurchargePercent)%") }
        return parts.joined(separator: ", ")
    }
}

/// The currency in which a client invoices. Only the symbol and the code differ;
/// amounts are always stored in whole cents.
public enum Currency: String, CaseIterable, Sendable {
    case eur = "EUR"
    case usd = "USD"

    public var symbol: String {
        switch self {
        case .eur: return "€"
        case .usd: return "$"
        }
    }

    public var label: String {
        switch self {
        case .eur: return "Euro (€)"
        case .usd: return "Dollar ($)"
        }
    }
}

/// What decides whether you are at a client: the network name or a location.
public enum PresenceSource: String, CaseIterable, Sendable {
    case wifi
    case location

    public var label: String {
        switch self {
        case .wifi: return "Wi-Fi network"
        case .location: return "Location"
        }
    }
}

/// An organization/profile. Can be linked to multiple ControlPlane contexts
/// (Wi-Fi networks), for example a guest and a staff network at the same client.
/// The hourly rate is stored in whole cents, so rounding errors never creep into
/// amounts.
public struct Profile: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var name: String
    public var contexts: [String]
    public var active: Bool
    public var breakRule: BreakRule
    /// Rounding, minimum and surcharges for the invoice of this client.
    public var billingRules: BillingRules
    public var hourlyRateCents: Int
    public var currency: Currency
    /// Free-form billing address, shown on the invoice. Multi-line is allowed.
    public var billingAddress: String?
    /// VAT identification number of the client, if they need it on the invoice.
    public var vatNumber: String?
    /// VAT percentage charged on this client's invoice. 21 for most Dutch work.
    public var vatRatePercent: Int
    /// Default purchase-order reference, pre-fills the invoice dialog.
    public var poNumber: String?
    /// Where the invoice is emailed when you send it from the app.
    public var billingEmail: String?
    /// Extra addresses that get a copy of this client's invoice (CC), on top of
    /// the ones in the invoice settings. Several, separated by commas or new lines.
    public var billingCc: String?
    /// Coordinates and radius that mark this client on the map, for location
    /// detection. `nil` when the client is only recognised by network name.
    public var latitude: Double?
    public var longitude: Double?
    public var presenceRadiusMeters: Int
    /// Default mileage rate for this client, in cents per kilometre. Used to
    /// pre-fill a new mileage entry; the amount is fixed when the entry is made.
    /// Zero means no rate yet.
    public var kmRateCents: Int
    /// Hourly rate for travel to this client. Zero means travel is billed at the
    /// normal hourly rate. Negative is not allowed.
    public var travelRateCents: Int
    /// Hourly rate for the commute. Zero means the commute is not invoiced at all.
    public var commuteRateCents: Int

    public init(
        id: Int64,
        name: String,
        contexts: [String],
        active: Bool = true,
        breakRule: BreakRule = .default,
        billingRules: BillingRules = .default,
        hourlyRateCents: Int = 0,
        currency: Currency = .eur,
        billingAddress: String? = nil,
        vatNumber: String? = nil,
        vatRatePercent: Int = 21,
        poNumber: String? = nil,
        billingEmail: String? = nil,
        billingCc: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        presenceRadiusMeters: Int = 150,
        kmRateCents: Int = 0,
        travelRateCents: Int = 0,
        commuteRateCents: Int = 0
    ) {
        self.id = id
        self.name = name
        self.contexts = contexts
        self.active = active
        self.breakRule = breakRule
        self.billingRules = billingRules
        self.hourlyRateCents = hourlyRateCents
        self.currency = currency
        self.billingAddress = billingAddress
        self.vatNumber = vatNumber
        self.vatRatePercent = vatRatePercent
        self.poNumber = poNumber
        self.billingEmail = billingEmail
        self.billingCc = billingCc
        self.latitude = latitude
        self.longitude = longitude
        self.presenceRadiusMeters = presenceRadiusMeters
        self.kmRateCents = kmRateCents
        self.travelRateCents = max(0, travelRateCents)
        self.commuteRateCents = max(0, commuteRateCents)
    }

    /// Is there a rate set that can be used for calculations?
    public var hasHourlyRate: Bool { hourlyRateCents > 0 }

    /// Amount for a number of worked seconds at this rate, in cents.
    public func amountCents(for interval: TimeInterval) -> Int {
        amountCents(for: interval, rateCents: hourlyRateCents)
    }

    /// The same at an explicit rate, for travel and commute lines.
    public func amountCents(for interval: TimeInterval, rateCents: Int) -> Int {
        guard rateCents > 0, interval > 0 else { return 0 }
        return Int((interval / 3600 * Double(rateCents)).rounded())
    }

    /// The network contexts, without the hidden `geo:<id>` marker that location
    /// detection uses.
    public var wifiContexts: [String] {
        contexts.filter { !$0.hasPrefix("geo:") }
    }

    /// Is a location stored for this client?
    public var hasLocation: Bool { latitude != nil && longitude != nil }

    /// The hidden context that lets a location signal resolve to this client, just
    /// like a network name would.
    public var geoContext: String { "geo:\(id)" }

    /// The rate a block of this kind is billed at. Travel falls back to the
    /// normal hourly rate; the commute is zero unless its own rate is set.
    public func rateCents(for kind: EntryKind) -> Int {
        switch kind {
        case .work: return hourlyRateCents
        case .travel: return travelRateCents > 0 ? travelRateCents : hourlyRateCents
        case .commute: return commuteRateCents
        }
    }

    /// Is a block of this kind invoiced? The commute is only billable with a rate.
    public func isBillable(kind: EntryKind) -> Bool {
        kind != .commute || commuteRateCents > 0
    }

    /// Display in lists: all linked Wi-Fi contexts on one line.
    public var contextsLabel: String {
        if !wifiContexts.isEmpty { return wifiContexts.joined(separator: ", ") }
        return hasLocation ? "location" : "(no Wi-Fi context)"
    }
}

/// A project within an organization. The number is unique within the profile.
public struct Project: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var profileId: Int64
    public var number: String
    public var name: String
    public var active: Bool
    /// Optional hour budget for this project, in minutes. Zero means no budget,
    /// which is the default, so nothing is tracked or warned until it is set.
    public var budgetMinutes: Int

    public init(
        id: Int64,
        profileId: Int64,
        number: String,
        name: String,
        active: Bool = true,
        budgetMinutes: Int = 0
    ) {
        self.id = id
        self.profileId = profileId
        self.number = number
        self.name = name
        self.active = active
        self.budgetMinutes = budgetMinutes
    }

    /// Display in the menu bar: `number — name`.
    public var label: String { "\(number) — \(name)" }

    /// Is a budget set for this project?
    public var hasBudget: Bool { budgetMinutes > 0 }

    /// The budget as a number of seconds.
    public var budgetSeconds: TimeInterval { TimeInterval(budgetMinutes) * 60 }
}

/// How much of a project's hour budget is used. The burn-down is calculated on
/// top of the recorded blocks, exactly like a break deduction: no time entry is
/// changed by it, so a budget can be set or cleared at any moment.
public struct ProjectBudget: Equatable, Sendable {
    /// The thresholds at which the app warns. Ordered, so "did we pass one?" is
    /// a comparison rather than a chain of ifs.
    public enum Level: Int, Equatable, Sendable, Comparable {
        /// No budget set.
        case none = 0
        /// Under 80% used.
        case ok = 1
        /// 80% or more used, but not over.
        case nearLimit = 80
        /// 100% or more used.
        case exceeded = 100

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var budgetSeconds: TimeInterval
    public var usedSeconds: TimeInterval

    public init(budgetSeconds: TimeInterval, usedSeconds: TimeInterval) {
        self.budgetSeconds = max(0, budgetSeconds)
        self.usedSeconds = max(0, usedSeconds)
    }

    /// The fraction of the budget used, for a progress bar. Zero without a budget.
    public var fraction: Double { budgetSeconds > 0 ? usedSeconds / budgetSeconds : 0 }

    /// True once the budget is reached or passed.
    public var isOver: Bool { budgetSeconds > 0 && usedSeconds >= budgetSeconds }

    /// What is left; zero when over.
    public var remainingSeconds: TimeInterval { max(0, budgetSeconds - usedSeconds) }

    /// How far over budget, so the display can show it.
    public var overSeconds: TimeInterval { max(0, usedSeconds - budgetSeconds) }

    public var level: Level {
        guard budgetSeconds > 0 else { return .none }
        if usedSeconds >= budgetSeconds { return .exceeded }
        if usedSeconds >= budgetSeconds * 0.8 { return .nearLimit }
        return .ok
    }

    /// The threshold that was passed when moving from `previous` to the current
    /// level, or `nil` when no warning threshold was newly crossed. Used to warn
    /// exactly once per threshold instead of on every tick.
    public func crossedLevel(above previous: Level) -> Level? {
        let current = level
        guard current > previous, current == .nearLimit || current == .exceeded else { return nil }
        return current
    }

    /// Short description for lists and menus.
    public var summary: String {
        guard budgetSeconds > 0 else { return "no budget" }
        if isOver {
            return "\(Formatting.duration(usedSeconds)) used of \(Formatting.duration(budgetSeconds)) — over by \(Formatting.duration(overSeconds))"
        }
        return "\(Formatting.duration(usedSeconds)) used of \(Formatting.duration(budgetSeconds)) — \(Formatting.duration(remainingSeconds)) left"
    }
}

/// What a block counts as. Work is what the timer records; travel to a client
/// and the commute to the office are recorded the same way but billed at their
/// own rate (or not at all) and shown as their own invoice line.
public enum EntryKind: String, CaseIterable, Sendable {
    case work
    case travel
    /// Home-to-office travel, Dutch "woon-werkverkeer". Usually not billable.
    case commute

    public var label: String {
        switch self {
        case .work: return "Work"
        case .travel: return "Travel"
        case .commute: return "Commute"
        }
    }
}

public enum EntryStatus: String, Sendable {
    /// Timer is currently running.
    case running
    /// Block was closed cleanly.
    case completed
    /// Block is missing a credible end and needs correction.
    case open
}

public enum EntrySource: String, Sendable {
    /// The app itself saw a Wi-Fi network change.
    case wifi
    /// The app itself saw the Mac arrive at or leave a stored location.
    case location
    /// Supplied by an external helper via the adapter command.
    case controlplane
    case manual
    /// Brought in from another time tracker with the importer.
    case imported
}

/// Free-form labels on a block, alongside the client and project hierarchy:
/// "meeting", "admin", "research". A tag is a plain word; commas or semicolons
/// separate them in text, and duplicates (ignoring case) are dropped.
public enum Tags {
    public static func parse(_ text: String?) -> [String] {
        guard let text else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for piece in text.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let tag = piece.trimmingCharacters(in: .whitespaces)
            guard !tag.isEmpty, seen.insert(tag.lowercased()).inserted else { continue }
            result.append(tag)
        }
        return result
    }

    /// Stored form: one comma-separated string, or `nil` when there are none.
    public static func join(_ tags: [String]) -> String? {
        let cleaned = parse(tags.joined(separator: ","))
        return cleaned.isEmpty ? nil : cleaned.joined(separator: ",")
    }

    /// Display form: `a, b`.
    public static func text(_ tags: [String]) -> String { tags.joined(separator: ", ") }
}

/// A single work block. Pausing closes a block, resuming starts a new one.
/// A break belongs to the whole block: it is recorded on the block itself, so a
/// day stays one row instead of being cut into two.
public struct TimeEntry: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var profileId: Int64
    public var projectId: Int64?
    public var startedAt: Date
    public var endedAt: Date?
    public var breakStartedAt: Date?
    public var breakEndedAt: Date?
    /// Idle time that was discarded on this block, in seconds. Like the break
    /// deduction it is a calculation on top of the raw block: the recorded start
    /// and end are never changed, the idle time only lowers the worked duration.
    public var idleSeconds: TimeInterval
    /// Free-form labels on the block; see `Tags`.
    public var tags: [String]
    /// Tags that came in with an import while the tags feature was off. Kept
    /// here so switching tags on later does not lose the imported labels.
    /// Empty in normal use.
    public var importedTags: [String]
    public var status: EntryStatus
    public var source: EntrySource
    /// Work, travel or commute. Everything recorded before this existed is work.
    public var kind: EntryKind
    public var note: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64,
        profileId: Int64,
        projectId: Int64?,
        startedAt: Date,
        endedAt: Date?,
        breakStartedAt: Date? = nil,
        breakEndedAt: Date? = nil,
        idleSeconds: TimeInterval = 0,
        tags: [String] = [],
        importedTags: [String] = [],
        status: EntryStatus,
        source: EntrySource,
        kind: EntryKind = .work,
        note: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.profileId = profileId
        self.projectId = projectId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.breakStartedAt = breakStartedAt
        self.breakEndedAt = breakEndedAt
        self.idleSeconds = max(0, idleSeconds)
        self.tags = Tags.parse(tags.joined(separator: ","))
        self.importedTags = Tags.parse(importedTags.joined(separator: ","))
        self.status = status
        self.source = source
        self.kind = kind
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Span of the block, break included; for a running block measured up to `now`.
    public func grossDuration(now: Date = Date()) -> TimeInterval {
        let end = endedAt ?? (status == .running ? now : startedAt)
        return max(0, end.timeIntervalSince(startedAt))
    }

    /// The recorded break, zero when none was set. Never longer than the block.
    public var breakDuration: TimeInterval {
        guard let start = breakStartedAt, let end = breakEndedAt else { return 0 }
        return max(0, min(end.timeIntervalSince(start), grossDuration()))
    }

    /// Discarded idle time on the block, never more than what is left after the
    /// recorded break. For a running block measured up to `now`.
    public func idleDuration(now: Date = Date()) -> TimeInterval {
        max(0, min(idleSeconds, grossDuration(now: now) - breakDuration))
    }

    /// Net worked time: the span minus the break and any discarded idle time. For
    /// a running block measured up to `now`.
    public func duration(now: Date = Date()) -> TimeInterval {
        max(0, grossDuration(now: now) - breakDuration - idleDuration(now: now))
    }
}

/// Separate status per profile: chosen project, pause and delayed stop.
public struct ProfileState: Equatable, Sendable {
    public var profileId: Int64
    public var activeProjectId: Int64?
    public var paused: Bool
    public var pendingStopAt: Date?
    public var pendingStopEntryId: Int64?
    public var attention: String?

    public init(
        profileId: Int64,
        activeProjectId: Int64? = nil,
        paused: Bool = false,
        pendingStopAt: Date? = nil,
        pendingStopEntryId: Int64? = nil,
        attention: String? = nil
    ) {
        self.profileId = profileId
        self.activeProjectId = activeProjectId
        self.paused = paused
        self.pendingStopAt = pendingStopAt
        self.pendingStopEntryId = pendingStopEntryId
        self.attention = attention
    }
}

/// An expense or a mileage claim for a client. Expenses are billed on top of the
/// hours; a mileage entry stores the kilometres and the rate used at the moment,
/// so later changing the client's default rate does not alter old claims.
public enum ExpenseKind: String, CaseIterable, Sendable {
    case expense
    case mileage

    public var label: String {
        switch self {
        case .expense: return "Expense"
        case .mileage: return "Mileage"
        }
    }
}

public struct Expense: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var profileId: Int64
    public var date: Date
    public var description: String
    public var kind: ExpenseKind
    /// Kilometres for mileage; 1 for a plain expense.
    public var quantity: Double
    /// Cents per kilometre for mileage; the amount itself for an expense.
    public var unitRateCents: Int
    /// Net amount in cents, excluding VAT.
    public var amountCents: Int
    /// Include this on the invoice (and in the VAT return).
    public var billable: Bool
    public var note: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64,
        profileId: Int64,
        date: Date,
        description: String,
        kind: ExpenseKind = .expense,
        quantity: Double = 1,
        unitRateCents: Int = 0,
        amountCents: Int,
        billable: Bool = true,
        note: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.profileId = profileId
        self.date = date
        self.description = description
        self.kind = kind
        self.quantity = quantity
        self.unitRateCents = unitRateCents
        self.amountCents = amountCents
        self.billable = billable
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The amount a mileage entry works out to, or the entered amount for a plain
    /// expense. Rounded to whole cents.
    public static func mileageAmountCents(kilometres: Double, rateCentsPerKm: Int) -> Int {
        guard kilometres > 0, rateCentsPerKm > 0 else { return 0 }
        return Int((kilometres * Double(rateCentsPerKm)).rounded())
    }

    /// How the quantity reads on the invoice: `120 km` for mileage, otherwise the
    /// count with trailing zeros dropped.
    public var quantityText: String {
        kind == .mileage
            ? "\(Formatting.quantity(quantity)) km"
            : Formatting.quantity(quantity)
    }
}

/// A fixed monthly amount for a client, put on the invoice automatically. A
/// retainer is a line on top of the hours, not a replacement for them.
public struct Retainer: Equatable, Sendable {
    public var profileId: Int64
    public var description: String
    public var amountCents: Int
    public var active: Bool
    /// The last day the retainer runs, or `nil` for an open-ended one. A dated
    /// retainer is only billed up to and including this day.
    public var endsAt: Date?

    /// How the retainer recurs when the automatic monthly invoice is generated.
    /// The retainer is always a whole amount per billable month; this decides
    /// which months it lands in.
    public var recurrence: RetainerRecurrence

    public init(
        profileId: Int64,
        description: String,
        amountCents: Int,
        active: Bool = true,
        endsAt: Date? = nil,
        recurrence: RetainerRecurrence = .monthly
    ) {
        self.profileId = profileId
        self.description = description
        self.amountCents = max(0, amountCents)
        self.active = active
        self.endsAt = endsAt
        self.recurrence = recurrence
    }

    /// Is there something to put on an invoice? A retainer of zero is not set.
    public var isSet: Bool { active && amountCents > 0 }

    public var label: String {
        description.trimmingCharacters(in: .whitespaces).isEmpty ? "Retainer" : description
    }

    /// Does the retainer cover the month that `date` falls in? Used to decide
    /// whether the automatic monthly invoice should carry it. An ended retainer
    /// stops from the month after its last day.
    public func coversMonth(containing date: Date, calendar: Calendar = Formatting.calendar) -> Bool {
        guard let endsAt else { return true }
        let endMonth = calendar.dateInterval(of: .month, for: endsAt)
        let month = calendar.dateInterval(of: .month, for: date)
        guard let endMonth, let month else { return date <= endsAt }
        return month.start <= endMonth.start
    }
}

/// How often a retainer recurs. Monthly is the default; quarterly and yearly
/// suit a support contract that is invoiced a few times a year.
public enum RetainerRecurrence: String, CaseIterable, Sendable {
    case monthly
    case quarterly
    case yearly

    public var label: String {
        switch self {
        case .monthly: return "Monthly"
        case .quarterly: return "Quarterly"
        case .yearly: return "Yearly"
        }
    }

    /// The months of the year (1–12) in which this recurrence bills. Monthly is
    /// every month; quarterly starts in January, April, July and October; yearly
    /// bills in January.
    public func billingMonths(calendar: Calendar = Formatting.calendar) -> Set<Int> {
        switch self {
        case .monthly: return Set(1...12)
        case .quarterly: return [1, 4, 7, 10]
        case .yearly: return [1]
        }
    }
}

/// A day that is not a normal working day: a public holiday or a vacation day.
/// Marked by the user; the tracker does not expect work and does not cut the day
/// off at the usual workday end.
public enum NonWorkingKind: String, CaseIterable, Sendable {
    case holiday
    case vacation

    public var label: String {
        switch self {
        case .holiday: return "Holiday"
        case .vacation: return "Vacation"
        }
    }
}

public struct NonWorkingDay: Equatable, Identifiable, Sendable {
    /// Start of the day, in local time.
    public var date: Date
    public var label: String
    public var kind: NonWorkingKind

    public var id: Date { date }

    public init(date: Date, label: String = "", kind: NonWorkingKind = .holiday) {
        self.date = date
        self.label = label.trimmingCharacters(in: .whitespaces)
        self.kind = kind
    }

    /// What to show: the label if there is one, otherwise the kind.
    public var display: String { label.isEmpty ? kind.label : label }
}

public enum EventKind: String, Sendable {
    case start
    case stop
}

/// An incoming context signal from the adapter.
public struct ContextEvent: Equatable, Sendable {
    public var context: String
    public var kind: EventKind
    public var at: Date
    public var source: EntrySource

    public init(context: String, kind: EventKind, at: Date = Date(), source: EntrySource = .controlplane) {
        self.context = context
        self.kind = kind
        self.at = at
        self.source = source
    }
}

/// What the tracker did with an event. Everything is logged, including ignoring it.
public enum EventOutcome: Equatable, Sendable {
    case started(entryId: Int64)
    case alreadyRunning(entryId: Int64)
    case ignoredDuplicate
    case ignoredUnknownContext
    case ignoredInactiveProfile
    case needsProject(profileId: Int64)
    case needsProjectChoice(profileId: Int64, projectIds: [Int64])
    case conflict(runningProfileId: Int64)
    case stopScheduled(effectiveAt: Date)
    case stopped(entryId: Int64)
    case stopCancelled(entryId: Int64)
    case noRunningTimer
    case pausedManually

    public var summary: String {
        switch self {
        case .started(let id): return "started (block \(id))"
        case .alreadyRunning(let id): return "timer already running (block \(id))"
        case .ignoredDuplicate: return "ignored: duplicate event"
        case .ignoredUnknownContext: return "ignored: unknown context"
        case .ignoredInactiveProfile: return "ignored: profile inactive"
        case .needsProject: return "no active project selected"
        case .needsProjectChoice: return "choose a project to start"
        case .conflict: return "conflict: another work context is already active"
        case .stopScheduled(let at): return "stop pending, block keeps running until the day is over (\(Formatting.timestamp(at)))"
        case .stopped(let id): return "stopped (block \(id))"
        case .stopCancelled(let id): return "context returned, timer keeps running (block \(id))"
        case .noRunningTimer: return "no running timer"
        case .pausedManually: return "manual pause active, timer stays paused"
        }
    }
}
