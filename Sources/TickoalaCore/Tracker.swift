import Foundation

public enum TrackerMode: String, Sendable {
    case working
    case paused
    case stopped
    case attention

    /// Label for the menu bar.
    public var label: String {
        switch self {
        case .working: return "Working"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        case .attention: return "Needs attention"
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
    /// Net, so after deducting the automatic break.
    public var todayTotal: TimeInterval
    public var weekTotal: TimeInterval
    /// What was automatically deducted today/this week; 0 if the rule is off.
    public var todayBreak: TimeInterval
    public var weekBreak: TimeInterval
    public var attention: String?

    public var todayRaw: TimeInterval { todayTotal + todayBreak }
    public var weekRaw: TimeInterval { weekTotal + weekBreak }
}

public struct TrackerStatus: Sendable {
    public var profiles: [ProfileStatus]
    public var primary: ProfileStatus?
    public var mode: TrackerMode
    public var openEntryCount: Int

    /// What is shown in the menu bar: the clock if something is running, otherwise a short status word.
    public var menuBarTitle: String {
        switch mode {
        case .working:
            return Formatting.duration(primary?.elapsedCurrent ?? 0)
        case .paused:
            return "Paused"
        case .attention:
            return "!"
        case .stopped:
            return "–"
        }
    }
}

/// All timer rules. The adapter and the menu bar app use exactly this logic.
public final class Tracker {
    public let store: Store

    public init(store: Store) {
        self.store = store
    }

    // MARK: - Context events

    /// Processes a start or stop signal from ControlPlane. Idempotent and always logged.
    @discardableResult
    public func handle(_ event: ContextEvent, now: Date = Date()) throws -> EventOutcome {
        let settings = try store.settings()

        // A stop that has served its grace period counts first; only then this event.
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

        // Brief Wi-Fi interruption: the scheduled stop disappears, the block keeps running.
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

        // Two work contexts at once: don't stop anything automatically, but warn.
        if let other = try store.runningEntries().first(where: { $0.profileId != profile.id }) {
            let otherProfile = try store.profile(id: other.profileId)
            let message = "Two work contexts active: \(otherProfile?.name ?? "unknown") is still running. Decide which one counts."
            try setAttention(message, on: [profile.id, other.profileId])
            return .conflict(runningProfileId: other.profileId)
        }

        if let projectId = state.activeProjectId,
           let project = try store.project(id: projectId),
           project.active {
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

        let activeProjects = try store.projects(profileId: profile.id, includeInactive: false)
        if activeProjects.count > 1 {
            return .needsProjectChoice(profileId: profile.id, projectIds: activeProjects.map(\.id))
        }

        try setAttention("Choose a project for \(profile.name) first.", on: [profile.id])
        return .needsProject(profileId: profile.id)
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

    // MARK: - Background work

    /// Closes stops whose grace period has passed. The end is the moment of the
    /// stop signal, not the moment of finalizing.
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

    /// Flags implausibly long blocks (sleep, restart) as `open`, so the user can
    /// correct them. No end is invented.
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
            state.attention = "Block \(entry.id) has been running since \(Formatting.timestamp(entry.startedAt)) and needs correction."
            try store.save(state)
            if let updated = try store.entry(id: entry.id) { flagged.append(updated) }
        }
        return flagged
    }

    /// One maintenance round: finalize delayed stops and flag stuck blocks.
    public func tick(now: Date = Date()) throws {
        _ = try finalizePendingStops(now: now)
        _ = try flagStaleEntries(now: now)
    }

    // MARK: - Projects

    /// Creates a project. If the profile has no active project yet, this becomes
    /// the active project — otherwise the tracker still wouldn't start on arrival.
    @discardableResult
    public func createProject(profileId: Int64, number: String, name: String) throws -> Project {
        let project = try store.createProject(profileId: profileId, number: number, name: name)
        if try store.state(profileId: profileId).activeProjectId == nil {
            _ = try selectProject(profileId: profileId, projectId: project.id)
        }
        return project
    }

    // MARK: - Manual control

    @discardableResult
    public func start(profileId: Int64, now: Date = Date(), source: EntrySource = .manual) throws -> TimeEntry {
        var state = try store.state(profileId: profileId)
        if let running = try store.runningEntry(profileId: profileId) { return running }
        guard let projectId = state.activeProjectId, let project = try store.project(id: projectId) else {
            throw TrackerError.unknownProject("no active project for this profile")
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

    /// Pausing closes the running block; resuming starts a new block.
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

    /// Switches project. If a block is running, it is closed and a new block starts
    /// on the new project, so the time stays with the right project.
    @discardableResult
    public func selectProject(profileId: Int64, projectId: Int64, now: Date = Date()) throws -> TimeEntry? {
        guard let project = try store.project(id: projectId), project.profileId == profileId else {
            throw TrackerError.unknownProject(String(projectId))
        }
        var state = try store.state(profileId: profileId)
        let previousProjectId = state.activeProjectId
        state.activeProjectId = projectId
        if state.attention?.hasPrefix("Choose a project") == true { state.attention = nil }
        try store.save(state)

        guard let running = try store.runningEntry(profileId: profileId), previousProjectId != projectId else {
            return try store.runningEntry(profileId: profileId)
        }
        if now <= running.startedAt {
            // Switch within the same second: no empty block, just reattach.
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

            let todayReport = try Reporting.report(
                store: store, period: .day, containing: now, profileId: profile.id, now: now
            )
            let weekReport = try Reporting.report(
                store: store, period: .week, containing: now, profileId: profile.id, now: now
            )
            statuses.append(ProfileStatus(
                profile: profile,
                project: project,
                mode: mode,
                runningEntry: running,
                pendingStopAt: state.pendingStopAt,
                elapsedCurrent: running?.duration(now: now) ?? 0,
                todayTotal: todayReport.netTotal,
                weekTotal: weekReport.netTotal,
                todayBreak: todayReport.breakDeduction,
                weekBreak: weekReport.breakDeduction,
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

    // MARK: - Helpers

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

    /// Catches repeats that fall just across a bucket boundary.
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
        case .needsProjectChoice: return "needs_project_choice"
        case .conflict: return "conflict"
        case .stopScheduled: return "stop_scheduled"
        case .stopped: return "stopped"
        case .stopCancelled: return "stop_cancelled"
        case .noRunningTimer: return "no_running_timer"
        case .pausedManually: return "paused"
        }
    }
}
