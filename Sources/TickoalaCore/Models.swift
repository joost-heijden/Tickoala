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
    /// Coordinates and radius that mark this client on the map, for location
    /// detection. `nil` when the client is only recognised by network name.
    public var latitude: Double?
    public var longitude: Double?
    public var presenceRadiusMeters: Int

    public init(
        id: Int64,
        name: String,
        contexts: [String],
        active: Bool = true,
        breakRule: BreakRule = .default,
        hourlyRateCents: Int = 0,
        currency: Currency = .eur,
        billingAddress: String? = nil,
        vatNumber: String? = nil,
        vatRatePercent: Int = 21,
        poNumber: String? = nil,
        billingEmail: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        presenceRadiusMeters: Int = 150
    ) {
        self.id = id
        self.name = name
        self.contexts = contexts
        self.active = active
        self.breakRule = breakRule
        self.hourlyRateCents = hourlyRateCents
        self.currency = currency
        self.billingAddress = billingAddress
        self.vatNumber = vatNumber
        self.vatRatePercent = vatRatePercent
        self.poNumber = poNumber
        self.billingEmail = billingEmail
        self.latitude = latitude
        self.longitude = longitude
        self.presenceRadiusMeters = presenceRadiusMeters
    }

    /// Is there a rate set that can be used for calculations?
    public var hasHourlyRate: Bool { hourlyRateCents > 0 }

    /// Amount for a number of worked seconds at this rate, in cents.
    public func amountCents(for interval: TimeInterval) -> Int {
        guard hourlyRateCents > 0, interval > 0 else { return 0 }
        return Int((interval / 3600 * Double(hourlyRateCents)).rounded())
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

    public init(id: Int64, profileId: Int64, number: String, name: String, active: Bool = true) {
        self.id = id
        self.profileId = profileId
        self.number = number
        self.name = name
        self.active = active
    }

    /// Display in the menu bar: `number — name`.
    public var label: String { "\(number) — \(name)" }
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
    public var status: EntryStatus
    public var source: EntrySource
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
        status: EntryStatus,
        source: EntrySource,
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
        self.status = status
        self.source = source
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

    /// Net worked time: the span minus the break. For a running block measured
    /// up to `now`.
    public func duration(now: Date = Date()) -> TimeInterval {
        max(0, grossDuration(now: now) - breakDuration)
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
