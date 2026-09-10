import Foundation

public enum TrackerMode: String, Sendable {
    case working
    case paused
    case stopped
    case attention

    /// Label voor de menubalk.
    public var label: String {
        switch self {
        case .working: return "Werkend"
        case .paused: return "Pauze"
        case .stopped: return "Gestopt"
        case .attention: return "Aandacht nodig"
        }
    }

    public var symbol: String {
        switch self {
        case .working: return "record.circle"
        case .paused: return "pause.circle"
        case .stopped: return "stop.circle"
        case .attention: return "exclamationmark.triangle"
        }
    }
}

public struct ProfileStatus: Sendable {
    public var profile: Profile
    public var project: Project?
    public var mode: TrackerMode
    public var runningEntry: TimeEntry?
    public var pendingStopAt: Date?
    public var elapsedCurrent: TimeInterval
    public var todayTotal: TimeInterval
    public var weekTotal: TimeInterval
    public var attention: String?
}

public struct TrackerStatus: Sendable {
    public var profiles: [ProfileStatus]
    public var primary: ProfileStatus?
    public var mode: TrackerMode
    public var openEntryCount: Int

    /// Wat er in de menubalk staat: klok als er iets loopt, anders een kort statuswoord.
    public var menuBarTitle: String {
        switch mode {
        case .working:
            return Formatting.duration(primary?.elapsedCurrent ?? 0)
        case .paused:
            return "Pauze"
        case .attention:
            return "!"
        case .stopped:
            return "–"
        }
    }
}

/// Alle timerregels. De adapter en de menubalk-app gebruiken exact deze logica.
public final class Tracker {
    public let store: Store

    public init(store: Store) {
        self.store = store
    }

    // MARK: - Contextevents

    /// Verwerkt een start- of stopsignaal van ControlPlane. Idempotent en altijd gelogd.
    @discardableResult
    public func handle(_ event: ContextEvent, now: Date = Date()) throws -> EventOutcome {
        let settings = try store.settings()

        // Een stop die zijn wachttijd heeft uitgezeten telt eerst; daarna pas dit event.
        _ = try finalizePendingStops(now: now)

        let key = dedupeKey(for: event, window: settings.dedupeWindowSeconds)
        if try isRepeat(of: event, window: settings.dedupeWindowSeconds) {
            return .ignoredDuplicate
        }
        guard try store.recordEvent(event, dedupeKey: key, outcome: "pending", detail: nil) else {
            return .ignoredDuplicate
        }

        let outcome = try resolve(event, settings: settings, now: now)
        try store.updateEventOutcome(dedupeKey: key, outcome: label(for: outcome), detail: outcome.summary)
        return outcome
    }

    private func resolve(_ event: ContextEvent, settings: TrackerSettings, now: Date) throws -> EventOutcome {
        guard let profile = try store.profile(context: event.context) else {
            return .ignoredUnknownContext
        }
        guard profile.active else { return .ignoredInactiveProfile }

        switch event.kind {
        case .start:
            return try handleStart(profile: profile, event: event, now: now)
        case .stop:
            return try handleStop(profile: profile, event: event, settings: settings, now: now)
        }
    }

    private func handleStart(profile: Profile, event: ContextEvent, now: Date) throws -> EventOutcome {
        var state = try store.state(profileId: profile.id)

        // Korte wifi-onderbreking: de geplande stop verdwijnt, het blok loopt gewoon door.
        if let pendingEntryId = state.pendingStopEntryId,
           let pending = try store.entry(id: pendingEntryId),
           pending.status == .running {
            state.pendingStopAt = nil
            state.pendingStopEntryId = nil
            try store.save(state)
            return .stopCancelled(entryId: pending.id)
        }

        if state.paused {
            return .pausedManually
        }

        if let running = try store.runningEntry(profileId: profile.id) {
            return .alreadyRunning(entryId: running.id)
        }

        // Twee werkcontexten tegelijk: niets automatisch stoppen, wel waarschuwen.
        if let other = try store.runningEntries().first(where: { $0.profileId != profile.id }) {
            let otherProfile = try store.profile(id: other.profileId)
            let message = "Twee werkcontexten actief: \(otherProfile?.name ?? "onbekend") loopt nog. Kies zelf welke telt."
            try setAttention(message, on: [profile.id, other.profileId])
            return .conflict(runningProfileId: other.profileId)
        }

        guard let projectId = state.activeProjectId,
              let project = try store.project(id: projectId),
              project.active else {
            try setAttention("Kies eerst een project voor \(profile.name).", on: [profile.id])
            return .needsProject(profileId: profile.id)
        }

        let entry = try store.createEntry(
            profileId: profile.id,
            projectId: project.id,
            startedAt: event.at,
            endedAt: nil,
            status: .running,
            source: event.source,
            note: nil
        )
        state.attention = nil
        try store.save(state)
        return .started(entryId: entry.id)
    }

    private func handleStop(profile: Profile, event: ContextEvent, settings: TrackerSettings, now: Date) throws -> EventOutcome {
        var state = try store.state(profileId: profile.id)
        guard let running = try store.runningEntry(profileId: profile.id) else {
            return .noRunningTimer
        }

        state.pendingStopAt = event.at
        state.pendingStopEntryId = running.id
        try store.save(state)

        let effectiveAt = event.at.addingTimeInterval(TimeInterval(settings.stopGraceSeconds))
        if now >= effectiveAt {
            _ = try finalizePendingStops(now: now)
            return .stopped(entryId: running.id)
        }
        return .stopScheduled(effectiveAt: effectiveAt)
    }

    // MARK: - Achtergrondwerk

    /// Sluit stops af waarvan de wachttijd verstreken is. Het einde is het moment
    /// van het stopsignaal, niet het moment van afronden.
    @discardableResult
    public func finalizePendingStops(now: Date = Date()) throws -> [TimeEntry] {
        let settings = try store.settings()
        var closed: [TimeEntry] = []
        for profile in try store.profiles() {
            var state = try store.state(profileId: profile.id)
            guard let pendingAt = state.pendingStopAt else { continue }
            guard now >= pendingAt.addingTimeInterval(TimeInterval(settings.stopGraceSeconds)) else { continue }

            if let entryId = state.pendingStopEntryId,
               let entry = try store.entry(id: entryId),
               entry.status == .running {
                let end = max(pendingAt, entry.startedAt)
                try store.updateEntry(id: entry.id, endedAt: .some(end), status: .completed)
                if let updated = try store.entry(id: entry.id) { closed.append(updated) }
            }
            state.pendingStopAt = nil
            state.pendingStopEntryId = nil
            try store.save(state)
        }
        return closed
    }

    /// Markeert onwaarschijnlijk lange blokken (slaapstand, herstart) als `open`,
    /// zodat de gebruiker ze corrigeert. Er wordt geen einde verzonnen.
    @discardableResult
    public func flagStaleEntries(now: Date = Date()) throws -> [TimeEntry] {
        let settings = try store.settings()
        var flagged: [TimeEntry] = []
        for entry in try store.runningEntries() {
            guard now.timeIntervalSince(entry.startedAt) > TimeInterval(settings.maxEntrySeconds) else { continue }
            try store.updateEntry(id: entry.id, status: .open)
            var state = try store.state(profileId: entry.profileId)
            if state.pendingStopEntryId == entry.id {
                state.pendingStopAt = nil
                state.pendingStopEntryId = nil
            }
            state.attention = "Blok \(entry.id) loopt sinds \(Formatting.timestamp(entry.startedAt)) en vraagt om correctie."
            try store.save(state)
            if let updated = try store.entry(id: entry.id) { flagged.append(updated) }
        }
        return flagged
    }

    /// Eén onderhoudsronde: uitgestelde stops afronden en vastgelopen blokken markeren.
    public func tick(now: Date = Date()) throws {
        _ = try finalizePendingStops(now: now)
        _ = try flagStaleEntries(now: now)
    }

    // MARK: - Handmatige bediening

    @discardableResult
    public func start(profileId: Int64, now: Date = Date(), source: EntrySource = .manual) throws -> TimeEntry {
        var state = try store.state(profileId: profileId)
        if let running = try store.runningEntry(profileId: profileId) { return running }
        guard let projectId = state.activeProjectId, let project = try store.project(id: projectId) else {
            throw TrackerError.unknownProject("geen actief project voor dit profiel")
        }
        state.paused = false
        state.pendingStopAt = nil
        state.pendingStopEntryId = nil
        state.attention = nil
        try store.save(state)
        return try store.createEntry(
            profileId: profileId, projectId: project.id, startedAt: now, endedAt: nil,
            status: .running, source: source, note: nil
        )
    }

    @discardableResult
    public func stop(profileId: Int64, now: Date = Date()) throws -> TimeEntry? {
        var state = try store.state(profileId: profileId)
        state.paused = false
        state.pendingStopAt = nil
        state.pendingStopEntryId = nil
        try store.save(state)
        guard let running = try store.runningEntry(profileId: profileId) else { return nil }
        try store.updateEntry(id: running.id, endedAt: .some(max(now, running.startedAt)), status: .completed)
        return try store.entry(id: running.id)
    }

    /// Pauzeren sluit het lopende blok af; hervatten maakt een nieuw blok.
    @discardableResult
    public func pause(profileId: Int64, now: Date = Date()) throws -> TimeEntry? {
        var state = try store.state(profileId: profileId)
        let running = try store.runningEntry(profileId: profileId)
        if let running {
            try store.updateEntry(id: running.id, endedAt: .some(max(now, running.startedAt)), status: .completed)
        }
        state.paused = true
        state.pendingStopAt = nil
        state.pendingStopEntryId = nil
        try store.save(state)
        return running.flatMap { try? store.entry(id: $0.id) }
    }

    @discardableResult
    public func resume(profileId: Int64, now: Date = Date()) throws -> TimeEntry {
        var state = try store.state(profileId: profileId)
        state.paused = false
        try store.save(state)
        return try start(profileId: profileId, now: now)
    }

    /// Wisselt van project. Loopt er een blok, dan wordt dat afgesloten en begint een
    /// nieuw blok op het nieuwe project, zodat de tijd bij het juiste project blijft.
    @discardableResult
    public func selectProject(profileId: Int64, projectId: Int64, now: Date = Date()) throws -> TimeEntry? {
        guard let project = try store.project(id: projectId), project.profileId == profileId else {
            throw TrackerError.unknownProject(String(projectId))
        }
        var state = try store.state(profileId: profileId)
        let previousProjectId = state.activeProjectId
        state.activeProjectId = projectId
        if state.attention?.hasPrefix("Kies eerst een project") == true { state.attention = nil }
        try store.save(state)

        guard let running = try store.runningEntry(profileId: profileId), previousProjectId != projectId else {
            return try store.runningEntry(profileId: profileId)
        }
        if now <= running.startedAt {
            // Wissel binnen dezelfde seconde: geen leeg blok, alleen omhangen.
            try store.updateEntry(id: running.id, projectId: .some(projectId))
            return try store.entry(id: running.id)
        }
        try store.updateEntry(id: running.id, endedAt: .some(now), status: .completed)
        return try store.createEntry(
            profileId: profileId, projectId: projectId, startedAt: now, endedAt: nil,
            status: .running, source: running.source, note: nil
        )
    }

    public func clearAttention(profileId: Int64) throws {
        var state = try store.state(profileId: profileId)
        state.attention = nil
        try store.save(state)
    }

    // MARK: - Status

    public func status(now: Date = Date()) throws -> TrackerStatus {
        var statuses: [ProfileStatus] = []
        let today = Reporting.range(.day, containing: now)
        let week = Reporting.range(.week, containing: now)

        for profile in try store.profiles(includeInactive: false) {
            let state = try store.state(profileId: profile.id)
            let running = try store.runningEntry(profileId: profile.id)
            let project = try state.activeProjectId.flatMap { try store.project(id: $0) }

            let mode: TrackerMode
            if state.attention != nil {
                mode = .attention
            } else if running != nil {
                mode = .working
            } else if state.paused {
                mode = .paused
            } else {
                mode = .stopped
            }

            let todayTotal = try store.entries(from: today.start, to: today.end, profileId: profile.id)
                .reduce(0) { $0 + $1.duration(now: now) }
            let weekTotal = try store.entries(from: week.start, to: week.end, profileId: profile.id)
                .reduce(0) { $0 + $1.duration(now: now) }

            statuses.append(ProfileStatus(
                profile: profile,
                project: project,
                mode: mode,
                runningEntry: running,
                pendingStopAt: state.pendingStopAt,
                elapsedCurrent: running?.duration(now: now) ?? 0,
                todayTotal: todayTotal,
                weekTotal: weekTotal,
                attention: state.attention
            ))
        }

        let primary = statuses.first(where: { $0.mode == .working })
            ?? statuses.first(where: { $0.mode == .attention })
            ?? statuses.first(where: { $0.mode == .paused })
            ?? statuses.first
        let overall: TrackerMode
        if statuses.contains(where: { $0.mode == .attention }) {
            overall = .attention
        } else {
            overall = primary?.mode ?? .stopped
        }

        return TrackerStatus(
            profiles: statuses,
            primary: primary,
            mode: overall,
            openEntryCount: try store.openEntries().count
        )
    }

    // MARK: - Hulp

    private func setAttention(_ message: String, on profileIds: [Int64]) throws {
        for profileId in profileIds {
            var state = try store.state(profileId: profileId)
            state.attention = message
            try store.save(state)
        }
    }

    private func dedupeKey(for event: ContextEvent, window: Int) -> String {
        let bucketSize = max(1, window)
        let bucket = Int(event.at.timeIntervalSince1970) / bucketSize
        return "\(event.context.lowercased())|\(event.kind.rawValue)|\(bucket)"
    }

    /// Vangt herhalingen die net over een bucketgrens vallen.
    private func isRepeat(of event: ContextEvent, window: Int) throws -> Bool {
        guard window > 0 else { return false }
        let at = Int64(event.at.timeIntervalSince1970)
        let rows = try store.database.query(
            """
            SELECT id FROM events
            WHERE kind = ? AND context_name = ? COLLATE NOCASE
              AND occurred_at > ? AND occurred_at <= ?
            LIMIT 1;
            """,
            [.text(event.kind.rawValue), .text(event.context), .int(at - Int64(window)), .int(at)]
        )
        return !rows.isEmpty
    }

    private func label(for outcome: EventOutcome) -> String {
        switch outcome {
        case .started: return "started"
        case .alreadyRunning: return "already_running"
        case .ignoredDuplicate: return "duplicate"
        case .ignoredUnknownContext: return "unknown_context"
        case .ignoredInactiveProfile: return "inactive_profile"
        case .needsProject: return "needs_project"
        case .conflict: return "conflict"
        case .stopScheduled: return "stop_scheduled"
        case .stopped: return "stopped"
        case .stopCancelled: return "stop_cancelled"
        case .noRunningTimer: return "no_running_timer"
        case .pausedManually: return "paused"
        }
    }
}
