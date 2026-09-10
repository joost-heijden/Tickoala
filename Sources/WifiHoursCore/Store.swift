import Foundation

public enum TrackerError: Error, CustomStringConvertible {
    case unknownProfile(String)
    case unknownProject(String)
    case duplicateProjectNumber(String)
    case duplicateContext(String)
    case unknownEntry(Int64)
    case invalidRange(String)
    case unknownSetting(String)

    public var description: String {
        switch self {
        case .unknownProfile(let name): return "onbekend profiel: \(name)"
        case .unknownProject(let number): return "onbekend project: \(number)"
        case .duplicateProjectNumber(let number): return "projectnummer \(number) bestaat al binnen dit profiel"
        case .duplicateContext(let context): return "context \(context) is al aan een profiel gekoppeld"
        case .unknownEntry(let id): return "onbekend blok: \(id)"
        case .invalidRange(let message): return message
        case .unknownSetting(let key): return "onbekende instelling: \(key) (geldig: \(TrackerSettings.keys.joined(separator: ", ")))"
        }
    }
}

/// Alle lees- en schrijfbewerkingen op de database. Bevat geen timerregels.
public final class Store {
    public let database: Database

    public init(database: Database) throws {
        self.database = database
        try Schema.migrate(database)
    }

    public convenience init(path: String) throws {
        try self.init(database: Database(path: path))
    }

    /// Standaardlocatie: ~/Library/Application Support/WifiHours/wifihours.sqlite3,
    /// te overschrijven met WIFIHOURS_DB (handig voor tests en probeersels).
    public static func defaultDatabasePath(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        if let override = environment["WIFIHOURS_DB"], !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return url.path
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WifiHours", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("wifihours.sqlite3").path
    }

    // MARK: - Profielen

    /// Maakt een profiel met één of meer gekoppelde wifi-contexten.
    @discardableResult
    public func createProfile(name: String, contexts: [String]) throws -> Profile {
        guard !contexts.isEmpty else {
            throw TrackerError.invalidRange("een profiel heeft minstens één wifi-context nodig")
        }
        for context in contexts {
            if try profile(context: context) != nil {
                throw TrackerError.duplicateContext(context)
            }
        }
        let id = try database.run(
            "INSERT INTO profiles (name, active, created_at) VALUES (?, 1, ?);",
            [.text(name), .int(Int64(Date().timeIntervalSince1970))]
        )
        try database.run("INSERT INTO profile_state (profile_id) VALUES (?);", [.int(id)])
        for context in contexts {
            try database.run(
                "INSERT INTO profile_contexts (profile_id, context_name, created_at) VALUES (?, ?, ?);",
                [.int(id), .text(context), .int(Int64(Date().timeIntervalSince1970))]
            )
        }
        return Profile(id: id, name: name, contexts: contexts)
    }

    public func profiles(includeInactive: Bool = true) throws -> [Profile] {
        let sql = includeInactive
            ? "SELECT * FROM profiles ORDER BY name;"
            : "SELECT * FROM profiles WHERE active = 1 ORDER BY name;"
        var result: [Profile] = []
        for row in try database.query(sql) {
            var profile = Self.profile(from: row)
            profile.contexts = try contexts(profileId: profile.id)
            result.append(profile)
        }
        return result
    }

    public func profile(id: Int64) throws -> Profile? {
        guard let row = try database.query("SELECT * FROM profiles WHERE id = ?;", [.int(id)]).first else { return nil }
        var profile = Self.profile(from: row)
        profile.contexts = try contexts(profileId: profile.id)
        return profile
    }

    public func profile(context: String) throws -> Profile? {
        let rows = try database.query(
            """
            SELECT profiles.* FROM profiles
            JOIN profile_contexts ON profile_contexts.profile_id = profiles.id
            WHERE profile_contexts.context_name = ? COLLATE NOCASE
            LIMIT 1;
            """,
            [.text(context)]
        )
        guard let row = rows.first else { return nil }
        var profile = Self.profile(from: row)
        profile.contexts = try contexts(profileId: profile.id)
        return profile
    }

    /// Zoekt op naam of op wifi-context, zodat de CLI beide accepteert.
    public func profile(matching needle: String) throws -> Profile {
        if let byContext = try profile(context: needle) { return byContext }
        let rows = try database.query("SELECT * FROM profiles WHERE name = ? COLLATE NOCASE;", [.text(needle)])
        guard let row = rows.first else { throw TrackerError.unknownProfile(needle) }
        var profile = Self.profile(from: row)
        profile.contexts = try contexts(profileId: profile.id)
        return profile
    }

    public func updateProfile(id: Int64, name: String? = nil, active: Bool? = nil) throws {
        var assignments: [String] = []
        var parameters: [SQLValue] = []
        if let name { assignments.append("name = ?"); parameters.append(.text(name)) }
        if let active { assignments.append("active = ?"); parameters.append(.int(active ? 1 : 0)) }
        guard !assignments.isEmpty else { return }
        parameters.append(.int(id))
        try database.run("UPDATE profiles SET \(assignments.joined(separator: ", ")) WHERE id = ?;", parameters)
    }

    /// Legt de pauzeregel van een klant vast.
    public func updateBreakRule(profileId: Int64, rule: BreakRule) throws {
        guard rule.minutes >= 0, rule.thresholdMinutes >= 0 else {
            throw TrackerError.invalidRange("pauzeduur en drempel mogen niet negatief zijn")
        }
        try database.run(
            "UPDATE profiles SET break_enabled = ?, break_minutes = ?, break_threshold_minutes = ? WHERE id = ?;",
            [
                .int(rule.enabled ? 1 : 0),
                .int(Int64(rule.minutes)),
                .int(Int64(rule.thresholdMinutes)),
                .int(profileId),
            ]
        )
    }

    // MARK: - Wifi-contexten

    public func contexts(profileId: Int64) throws -> [String] {
        try database.query(
            "SELECT context_name FROM profile_contexts WHERE profile_id = ? ORDER BY context_name COLLATE NOCASE;",
            [.int(profileId)]
        ).compactMap { $0.string("context_name") }
    }

    /// Koppelt een extra wifi-context aan een bestaand profiel.
    @discardableResult
    public func addContext(profileId: Int64, context: String) throws -> Profile {
        let trimmed = context.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw TrackerError.invalidRange("een wifi-context mag niet leeg zijn") }
        if let existing = try profile(context: trimmed), existing.id != profileId {
            throw TrackerError.duplicateContext(trimmed)
        }
        try database.run(
            "INSERT OR IGNORE INTO profile_contexts (profile_id, context_name, created_at) VALUES (?, ?, ?);",
            [.int(profileId), .text(trimmed), .int(Int64(Date().timeIntervalSince1970))]
        )
        guard let profile = try profile(id: profileId) else { throw TrackerError.unknownProfile(String(profileId)) }
        return profile
    }

    /// Ontkoppelt een wifi-context. Een profiel mag zonder contexten komen te zitten;
    /// het start dan alleen nog via handmatige bediening.
    @discardableResult
    public func removeContext(profileId: Int64, context: String) throws -> Profile {
        try database.run(
            "DELETE FROM profile_contexts WHERE profile_id = ? AND context_name = ? COLLATE NOCASE;",
            [.int(profileId), .text(context)]
        )
        guard let profile = try profile(id: profileId) else { throw TrackerError.unknownProfile(String(profileId)) }
        return profile
    }

    // MARK: - Projecten

    @discardableResult
    public func createProject(profileId: Int64, number: String, name: String) throws -> Project {
        if try project(profileId: profileId, number: number) != nil {
            throw TrackerError.duplicateProjectNumber(number)
        }
        let id = try database.run(
            "INSERT INTO projects (profile_id, number, name, active, created_at) VALUES (?, ?, ?, 1, ?);",
            [.int(profileId), .text(number), .text(name), .int(Int64(Date().timeIntervalSince1970))]
        )
        return Project(id: id, profileId: profileId, number: number, name: name)
    }

    public func projects(profileId: Int64, includeInactive: Bool = true) throws -> [Project] {
        let sql = includeInactive
            ? "SELECT * FROM projects WHERE profile_id = ? ORDER BY number;"
            : "SELECT * FROM projects WHERE profile_id = ? AND active = 1 ORDER BY number;"
        return try database.query(sql, [.int(profileId)]).map(Self.project(from:))
    }

    public func project(id: Int64) throws -> Project? {
        try database.query("SELECT * FROM projects WHERE id = ?;", [.int(id)]).first.map(Self.project(from:))
    }

    public func project(profileId: Int64, number: String) throws -> Project? {
        try database.query(
            "SELECT * FROM projects WHERE profile_id = ? AND number = ? COLLATE NOCASE;",
            [.int(profileId), .text(number)]
        ).first.map(Self.project(from:))
    }

    public func updateProject(id: Int64, number: String? = nil, name: String? = nil, active: Bool? = nil) throws {
        guard let existing = try project(id: id) else { throw TrackerError.unknownProject(String(id)) }
        // Het nummer blijft uniek binnen de organisatie, ook bij hernummeren.
        if let number, number.caseInsensitiveCompare(existing.number) != .orderedSame {
            if try project(profileId: existing.profileId, number: number) != nil {
                throw TrackerError.duplicateProjectNumber(number)
            }
        }
        var assignments: [String] = []
        var parameters: [SQLValue] = []
        if let number { assignments.append("number = ?"); parameters.append(.text(number)) }
        if let name { assignments.append("name = ?"); parameters.append(.text(name)) }
        if let active { assignments.append("active = ?"); parameters.append(.int(active ? 1 : 0)) }
        guard !assignments.isEmpty else { return }
        parameters.append(.int(id))
        try database.run("UPDATE projects SET \(assignments.joined(separator: ", ")) WHERE id = ?;", parameters)
    }

    // MARK: - Profielstatus

    public func state(profileId: Int64) throws -> ProfileState {
        let rows = try database.query("SELECT * FROM profile_state WHERE profile_id = ?;", [.int(profileId)])
        guard let row = rows.first else {
            try database.run("INSERT OR IGNORE INTO profile_state (profile_id) VALUES (?);", [.int(profileId)])
            return ProfileState(profileId: profileId)
        }
        return ProfileState(
            profileId: profileId,
            activeProjectId: row.int("active_project_id"),
            paused: row.bool("paused"),
            pendingStopAt: row.date("pending_stop_at"),
            pendingStopEntryId: row.int("pending_stop_entry_id"),
            attention: row.string("attention")
        )
    }

    public func save(_ state: ProfileState) throws {
        try database.run(
            """
            INSERT INTO profile_state (profile_id, active_project_id, paused, pending_stop_at, pending_stop_entry_id, attention)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(profile_id) DO UPDATE SET
                active_project_id = excluded.active_project_id,
                paused = excluded.paused,
                pending_stop_at = excluded.pending_stop_at,
                pending_stop_entry_id = excluded.pending_stop_entry_id,
                attention = excluded.attention;
            """,
            [
                .int(state.profileId),
                state.activeProjectId.map { SQLValue.int($0) } ?? .null,
                .int(state.paused ? 1 : 0),
                state.pendingStopAt.map { SQLValue.int(Int64($0.timeIntervalSince1970)) } ?? .null,
                state.pendingStopEntryId.map { SQLValue.int($0) } ?? .null,
                state.attention.map { SQLValue.text($0) } ?? .null,
            ]
        )
    }

    // MARK: - Tijdregistraties

    @discardableResult
    public func createEntry(
        profileId: Int64,
        projectId: Int64?,
        startedAt: Date,
        endedAt: Date?,
        status: EntryStatus,
        source: EntrySource,
        note: String?
    ) throws -> TimeEntry {
        let now = Date()
        let id = try database.run(
            """
            INSERT INTO time_entries (profile_id, project_id, started_at, ended_at, status, source, note, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .int(profileId),
                projectId.map { SQLValue.int($0) } ?? .null,
                .int(Int64(startedAt.timeIntervalSince1970)),
                endedAt.map { SQLValue.int(Int64($0.timeIntervalSince1970)) } ?? .null,
                .text(status.rawValue),
                .text(source.rawValue),
                note.map { SQLValue.text($0) } ?? .null,
                .int(Int64(now.timeIntervalSince1970)),
                .int(Int64(now.timeIntervalSince1970)),
            ]
        )
        return TimeEntry(
            id: id, profileId: profileId, projectId: projectId, startedAt: startedAt, endedAt: endedAt,
            status: status, source: source, note: note, createdAt: now, updatedAt: now
        )
    }

    public func entry(id: Int64) throws -> TimeEntry? {
        try database.query("SELECT * FROM time_entries WHERE id = ?;", [.int(id)]).first.map(Self.entry(from:))
    }

    public func runningEntry(profileId: Int64) throws -> TimeEntry? {
        try database.query(
            "SELECT * FROM time_entries WHERE profile_id = ? AND status = 'running' ORDER BY started_at DESC LIMIT 1;",
            [.int(profileId)]
        ).first.map(Self.entry(from:))
    }

    public func runningEntries() throws -> [TimeEntry] {
        try database.query("SELECT * FROM time_entries WHERE status = 'running' ORDER BY started_at;").map(Self.entry(from:))
    }

    public func openEntries() throws -> [TimeEntry] {
        try database.query("SELECT * FROM time_entries WHERE status = 'open' ORDER BY started_at;").map(Self.entry(from:))
    }

    /// Blokken die in het venster [from, to) beginnen.
    public func entries(from: Date, to: Date, profileId: Int64? = nil) throws -> [TimeEntry] {
        var sql = "SELECT * FROM time_entries WHERE started_at >= ? AND started_at < ?"
        var parameters: [SQLValue] = [
            .int(Int64(from.timeIntervalSince1970)),
            .int(Int64(to.timeIntervalSince1970)),
        ]
        if let profileId {
            sql += " AND profile_id = ?"
            parameters.append(.int(profileId))
        }
        sql += " ORDER BY started_at;"
        return try database.query(sql, parameters).map(Self.entry(from:))
    }

    public func updateEntry(
        id: Int64,
        projectId: Int64?? = nil,
        startedAt: Date? = nil,
        endedAt: Date?? = nil,
        status: EntryStatus? = nil,
        note: String?? = nil
    ) throws {
        guard try entry(id: id) != nil else { throw TrackerError.unknownEntry(id) }
        var assignments: [String] = []
        var parameters: [SQLValue] = []
        if let projectId {
            assignments.append("project_id = ?")
            parameters.append(projectId.map { SQLValue.int($0) } ?? .null)
        }
        if let startedAt {
            assignments.append("started_at = ?")
            parameters.append(.int(Int64(startedAt.timeIntervalSince1970)))
        }
        if let endedAt {
            assignments.append("ended_at = ?")
            parameters.append(endedAt.map { SQLValue.int(Int64($0.timeIntervalSince1970)) } ?? .null)
        }
        if let status {
            assignments.append("status = ?")
            parameters.append(.text(status.rawValue))
        }
        if let note {
            assignments.append("note = ?")
            parameters.append(note.map { SQLValue.text($0) } ?? .null)
        }
        guard !assignments.isEmpty else { return }
        assignments.append("updated_at = ?")
        parameters.append(.int(Int64(Date().timeIntervalSince1970)))
        parameters.append(.int(id))
        try database.run("UPDATE time_entries SET \(assignments.joined(separator: ", ")) WHERE id = ?;", parameters)
    }

    public func deleteEntry(id: Int64) throws {
        guard try entry(id: id) != nil else { throw TrackerError.unknownEntry(id) }
        try database.run("DELETE FROM time_entries WHERE id = ?;", [.int(id)])
    }

    // MARK: - Eventlog

    /// Legt het event vast. Geeft `false` terug als de sleutel al bestond (herhaling).
    func recordEvent(_ event: ContextEvent, dedupeKey: String, outcome: String, detail: String?) throws -> Bool {
        do {
            try database.run(
                """
                INSERT INTO events (context_name, kind, occurred_at, dedupe_key, outcome, detail, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """,
                [
                    .text(event.context),
                    .text(event.kind.rawValue),
                    .int(Int64(event.at.timeIntervalSince1970)),
                    .text(dedupeKey),
                    .text(outcome),
                    detail.map { SQLValue.text($0) } ?? .null,
                    .int(Int64(Date().timeIntervalSince1970)),
                ]
            )
            return true
        } catch DatabaseError.constraint {
            return false
        }
    }

    func updateEventOutcome(dedupeKey: String, outcome: String, detail: String?) throws {
        try database.run(
            "UPDATE events SET outcome = ?, detail = ? WHERE dedupe_key = ?;",
            [.text(outcome), detail.map { SQLValue.text($0) } ?? .null, .text(dedupeKey)]
        )
    }

    public func recentEvents(limit: Int = 20) throws -> [(context: String, kind: String, at: Date, outcome: String, detail: String?)] {
        try database.query("SELECT * FROM events ORDER BY occurred_at DESC, id DESC LIMIT ?;", [.int(Int64(limit))])
            .map {
                (
                    context: $0.string("context_name") ?? "",
                    kind: $0.string("kind") ?? "",
                    at: $0.date("occurred_at") ?? Date(timeIntervalSince1970: 0),
                    outcome: $0.string("outcome") ?? "",
                    detail: $0.string("detail")
                )
            }
    }

    // MARK: - Instellingen

    public func settings() throws -> TrackerSettings {
        var settings = TrackerSettings.default
        for row in try database.query("SELECT key, value FROM settings;") {
            guard let key = row.string("key"), let raw = row.string("value"), let value = Int(raw) else { continue }
            _ = settings.set(key, value)
        }
        return settings
    }

    public func setSetting(key: String, value: Int) throws {
        var probe = TrackerSettings.default
        guard probe.set(key, value) else { throw TrackerError.unknownSetting(key) }
        try database.run(
            "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
            [.text(key), .text(String(value))]
        )
    }

    // MARK: - Rijen omzetten

    /// Contexten worden apart opgehaald; hier staat een lege lijst tot de aanroeper die vult.
    static func profile(from row: Row) -> Profile {
        Profile(
            id: row.int("id") ?? 0,
            name: row.string("name") ?? "",
            contexts: [],
            active: row.bool("active"),
            breakRule: BreakRule(
                enabled: row.bool("break_enabled"),
                minutes: Int(row.int("break_minutes") ?? Int64(BreakRule.default.minutes)),
                thresholdMinutes: Int(row.int("break_threshold_minutes") ?? Int64(BreakRule.default.thresholdMinutes))
            )
        )
    }

    static func project(from row: Row) -> Project {
        Project(
            id: row.int("id") ?? 0,
            profileId: row.int("profile_id") ?? 0,
            number: row.string("number") ?? "",
            name: row.string("name") ?? "",
            active: row.bool("active")
        )
    }

    static func entry(from row: Row) -> TimeEntry {
        TimeEntry(
            id: row.int("id") ?? 0,
            profileId: row.int("profile_id") ?? 0,
            projectId: row.int("project_id"),
            startedAt: row.date("started_at") ?? Date(timeIntervalSince1970: 0),
            endedAt: row.date("ended_at"),
            status: EntryStatus(rawValue: row.string("status") ?? "") ?? .open,
            source: EntrySource(rawValue: row.string("source") ?? "") ?? .manual,
            note: row.string("note"),
            createdAt: row.date("created_at") ?? Date(timeIntervalSince1970: 0),
            updatedAt: row.date("updated_at") ?? Date(timeIntervalSince1970: 0)
        )
    }
}
