import Foundation

/// Automatische pauzeaftrek per klant. De aftrek is een rekenregel over de ruwe
/// blokken heen: tijdregistraties worden er nooit door aangepast, zodat de regel
/// altijd aan te passen of uit te zetten is.
public struct BreakRule: Equatable, Sendable {
    /// Staat de automatische aftrek aan voor deze klant?
    public var enabled: Bool
    /// Hoeveel pauze er per gewerkte dag van de uren af gaat.
    public var minutes: Int
    /// De drempel: er wordt pas afgetrokken vanaf dit aantal gewerkte minuten op een dag.
    /// Los instelbaar van de pauzeduur zelf.
    public var thresholdMinutes: Int

    /// Standaard uit; 30 minuten pauze vanaf 6 uur werk op een dag.
    public static let `default` = BreakRule(enabled: false, minutes: 30, thresholdMinutes: 360)

    public init(enabled: Bool, minutes: Int, thresholdMinutes: Int) {
        self.enabled = enabled
        self.minutes = minutes
        self.thresholdMinutes = thresholdMinutes
    }

    /// Aftrek voor één dag waarop `worked` seconden geregistreerd staan.
    /// De drempel telt inclusief: bij precies 6 uur gaat de pauze er al af.
    /// Er gaat nooit meer af dan er die dag gewerkt is, dus een dag wordt niet negatief.
    public func deduction(forDayTotal worked: TimeInterval) -> TimeInterval {
        guard enabled, minutes > 0, worked > 0 else { return 0 }
        guard worked >= TimeInterval(thresholdMinutes) * 60 else { return 0 }
        return min(TimeInterval(minutes) * 60, worked)
    }

    /// Korte omschrijving voor lijsten en menu's.
    public var summary: String {
        guard enabled, minutes > 0 else { return "geen automatische pauzeaftrek" }
        return "\(minutes) min pauze vanaf \(Formatting.duration(TimeInterval(thresholdMinutes) * 60)) per dag"
    }
}

/// Een organisatie/profiel. Kan aan meerdere ControlPlane-contexten (wifinetwerken)
/// hangen, bijvoorbeeld een gast- en een personeelsnetwerk bij dezelfde klant.
public struct Profile: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var name: String
    public var contexts: [String]
    public var active: Bool
    public var breakRule: BreakRule

    public init(
        id: Int64,
        name: String,
        contexts: [String],
        active: Bool = true,
        breakRule: BreakRule = .default
    ) {
        self.id = id
        self.name = name
        self.contexts = contexts
        self.active = active
        self.breakRule = breakRule
    }

    /// Weergave in lijsten: alle gekoppelde wifi-contexten op een rij.
    public var contextsLabel: String {
        contexts.isEmpty ? "(geen wifi-context)" : contexts.joined(separator: ", ")
    }
}

/// Een project binnen een organisatie. Het nummer is uniek binnen het profiel.
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

    /// Weergave in de menubalk: `nummer — naam`.
    public var label: String { "\(number) — \(name)" }
}

public enum EntryStatus: String, Sendable {
    /// Timer loopt op dit moment.
    case running
    /// Blok is netjes afgesloten.
    case completed
    /// Blok mist een geloofwaardig einde en vraagt om correctie.
    case open
}

public enum EntrySource: String, Sendable {
    /// De app zag zelf een wisseling van wifinetwerk.
    case wifi
    /// Aangeleverd door een extern hulpprogramma via het adaptercommando.
    case controlplane
    case manual
}

/// Eén werkblok. Pauzeren sluit een blok af, hervatten maakt een nieuw blok.
public struct TimeEntry: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var profileId: Int64
    public var projectId: Int64?
    public var startedAt: Date
    public var endedAt: Date?
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
        self.status = status
        self.source = source
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Duur van het blok; voor een lopend blok gemeten tot `now`.
    public func duration(now: Date = Date()) -> TimeInterval {
        let end = endedAt ?? (status == .running ? now : startedAt)
        return max(0, end.timeIntervalSince(startedAt))
    }
}

/// Losse status per profiel: gekozen project, pauze en uitgestelde stop.
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

/// Een binnenkomend contextsignaal van de adapter.
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

/// Wat de tracker met een event heeft gedaan. Alles wordt gelogd, ook het negeren.
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
        case .started(let id): return "gestart (blok \(id))"
        case .alreadyRunning(let id): return "timer liep al (blok \(id))"
        case .ignoredDuplicate: return "genegeerd: dubbel event"
        case .ignoredUnknownContext: return "genegeerd: onbekende context"
        case .ignoredInactiveProfile: return "genegeerd: profiel niet actief"
        case .needsProject: return "geen actief project gekozen"
        case .needsProjectChoice: return "kies een project om te starten"
        case .conflict: return "conflict: andere werkcontext is al actief"
        case .stopScheduled(let at): return "stop gepland op \(Formatting.timestamp(at))"
        case .stopped(let id): return "gestopt (blok \(id))"
        case .stopCancelled(let id): return "korte onderbreking, timer loopt door (blok \(id))"
        case .noRunningTimer: return "geen lopende timer"
        case .pausedManually: return "handmatige pauze actief, timer blijft staan"
        }
    }
}
