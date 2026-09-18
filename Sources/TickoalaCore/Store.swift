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
        case .unknownProfile(let name): return "unknown profile: \(name)"
        case .unknownProject(let number): return "unknown project: \(number)"
        case .duplicateProjectNumber(let number): return "project number \(number) already exists within this profile"
        case .duplicateContext(let context): return "context \(context) is already linked to a profile"
        case .unknownEntry(let id): return "unknown block: \(id)"
        case .invalidRange(let message): return message
        case .unknownSetting(let key): return "unknown setting: \(key) (valid: \(TrackerSettings.keys.joined(separator: ", ")))"
        }
    }
}

/// All read and write operations on the database. Contains no timer rules.
public final class Store {
    public let database: Database

    public init(database: Database) throws {
        self.database = database
        try Schema.migrate(database)
    }

    public convenience init(path: String) throws {
        try self.init(database: Database(path: path))
    }

    /// Default location: ~/Library/Application Support/Tickoala/tickoala.sqlite3,
    /// overridable with TICKOALA_DB (handy for tests and experiments).
    public static func defaultDatabasePath(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        if let override = environment["TICKOALA_DB"], !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return url.path
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tickoala", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("tickoala.sqlite3").path
    }

    // MARK: - Profiles

    /// Creates a profile with one or more linked Wi-Fi contexts.
    @discardableResult
    public func createProfile(name: String, contexts: [String], hourlyRateCents: Int = 0, currency: Currency = .eur) throws -> Profile {
        guard !contexts.isEmpty else {
            throw TrackerError.invalidRange("a profile needs at least one Wi-Fi context")
        }
        for context in contexts {
            if try profile(context: context) != nil {
                throw TrackerError.duplicateContext(context)
            }
        }
        let rate = max(0, hourlyRateCents)
        let id = try database.run(
            "INSERT INTO profiles (name, active, hourly_rate_cents, currency, created_at) VALUES (?, 1, ?, ?, ?);",
            [.text(name), .int(Int64(rate)), .text(currency.rawValue), .int(Int64(Date().timeIntervalSince1970))]
        )
        try database.run("INSERT INTO profile_state (profile_id) VALUES (?);", [.int(id)])
        for context in contexts {
            try database.run(
                "INSERT INTO profile_contexts (profile_id, context_name, created_at) VALUES (?, ?, ?);",
                [.int(id), .text(context), .int(Int64(Date().timeIntervalSince1970))]
            )
        }
        return Profile(id: id, name: name, contexts: contexts, hourlyRateCents: rate, currency: currency)
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

    /// Looks up by name or by Wi-Fi context, so the CLI accepts both.
    public func profile(matching needle: String) throws -> Profile {
        if let byContext = try profile(context: needle) { return byContext }
        let rows = try database.query("SELECT * FROM profiles WHERE name = ? COLLATE NOCASE;", [.text(needle)])
        guard let row = rows.first else { throw TrackerError.unknownProfile(needle) }
        var profile = Self.profile(from: row)
        profile.contexts = try contexts(profileId: profile.id)
        return profile
    }

    public func updateProfile(id: Int64, name: String? = nil, active: Bool? = nil, hourlyRateCents: Int? = nil, currency: Currency? = nil) throws {
        var assignments: [String] = []
        var parameters: [SQLValue] = []
        if let name { assignments.append("name = ?"); parameters.append(.text(name)) }
        if let active { assignments.append("active = ?"); parameters.append(.int(active ? 1 : 0)) }
        if let hourlyRateCents { assignments.append("hourly_rate_cents = ?"); parameters.append(.int(Int64(max(0, hourlyRateCents)))) }
        if let currency { assignments.append("currency = ?"); parameters.append(.text(currency.rawValue)) }
        guard !assignments.isEmpty else { return }
        parameters.append(.int(id))
        try database.run("UPDATE profiles SET \(assignments.joined(separator: ", ")) WHERE id = ?;", parameters)
    }

    /// Records the break rule of a client.
    public func updateBreakRule(profileId: Int64, rule: BreakRule) throws {
        guard rule.minutes >= 0, rule.thresholdMinutes >= 0 else {
            throw TrackerError.invalidRange("break duration and threshold must not be negative")
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

    /// Billing data for the invoice, stored separately from the rate so an empty
    /// field really clears the value. An empty string is stored as `NULL`.
    public func updateProfileInvoicing(
        id: Int64,
        billingAddress: String,
        vatNumber: String,
        vatRatePercent: Int,
        poNumber: String,
        billingEmail: String = ""
    ) throws {
        func cleaned(_ value: String) -> SQLValue {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .null : .text(trimmed)
        }
        try database.run(
            """
            UPDATE profiles SET billing_address = ?, vat_number = ?, vat_rate_percent = ?, po_number = ?, billing_email = ?
            WHERE id = ?;
            """,
            [
                cleaned(billingAddress),
                cleaned(vatNumber),
                .int(Int64(min(max(0, vatRatePercent), 100))),
                cleaned(poNumber),
                cleaned(billingEmail),
                .int(id),
            ]
        )
    }

    /// Stores the coordinates and radius that mark a client's location. A hidden
    /// `geo:<id>` context is linked so a location signal resolves to this profile
    /// exactly like a network name. `nil` coordinates clear it again.
    public func updateProfileLocation(id: Int64, latitude: Double?, longitude: Double?, radiusMeters: Int) throws {
        guard try profile(id: id) != nil else { throw TrackerError.unknownProfile(String(id)) }
        let radius = max(20, radiusMeters)
        let marker = "geo:\(id)"
        if let latitude, let longitude {
            try database.run(
                "UPDATE profiles SET latitude = ?, longitude = ?, presence_radius_m = ? WHERE id = ?;",
                [.double(latitude), .double(longitude), .int(Int64(radius)), .int(id)]
            )
            try database.run(
                "INSERT OR IGNORE INTO profile_contexts (profile_id, context_name, created_at) VALUES (?, ?, ?);",
                [.int(id), .text(marker), .int(Int64(Date().timeIntervalSince1970))]
            )
        } else {
            try database.run(
                "UPDATE profiles SET latitude = NULL, longitude = NULL, presence_radius_m = ? WHERE id = ?;",
                [.int(Int64(radius)), .int(id)]
            )
            try database.run(
                "DELETE FROM profile_contexts WHERE profile_id = ? AND context_name = ?;",
                [.int(id), .text(marker)]
            )
        }
    }

    /// Everything that belongs to a deleted customer, kept raw so the deletion
    /// can be undone. Rows go back with the same ids, which is safe because the
    /// tables use AUTOINCREMENT and never hand a deleted id to a new row.
    public struct ProfileBackup {
        let tables: [(table: String, rows: [[String: SQLValue]])]
    }

    /// Deletes a customer. The foreign keys cascade, so projects, blocks,
    /// contexts, state and issued invoices go with it. The returned backup lets
    /// the app put all of it back.
    @discardableResult
    public func deleteProfile(id: Int64) throws -> ProfileBackup {
        guard try profile(id: id) != nil else { throw TrackerError.unknownProfile(String(id)) }
        // Order matters when inserting again: parents before children.
        let queries: [(String, String)] = [
            ("profiles", "SELECT * FROM profiles WHERE id = ?;"),
            ("projects", "SELECT * FROM projects WHERE profile_id = ?;"),
            ("time_entries", "SELECT * FROM time_entries WHERE profile_id = ?;"),
            ("profile_state", "SELECT * FROM profile_state WHERE profile_id = ?;"),
            ("profile_contexts", "SELECT * FROM profile_contexts WHERE profile_id = ?;"),
            ("invoices", "SELECT * FROM invoices WHERE profile_id = ?;"),
        ]
        var tables: [(String, [[String: SQLValue]])] = []
        for (table, sql) in queries {
            tables.append((table, try database.query(sql, [.int(id)]).map(\.values)))
        }
        try database.run("DELETE FROM profiles WHERE id = ?;", [.int(id)])
        return ProfileBackup(tables: tables)
    }

    /// Puts a backed-up customer back exactly as it was, links included.
    public func restoreProfile(_ backup: ProfileBackup) throws {
        for (table, rows) in backup.tables {
            for row in rows {
                let columns = row.keys.sorted()
                let values = columns.map { row[$0] ?? .null }
                let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
                try database.run(
                    "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(placeholders));",
                    values
                )
            }
        }
    }

    // MARK: - Wi-Fi contexts

    public func contexts(profileId: Int64) throws -> [String] {
        try database.query(
            "SELECT context_name FROM profile_contexts WHERE profile_id = ? ORDER BY context_name COLLATE NOCASE;",
            [.int(profileId)]
        ).compactMap { $0.string("context_name") }
    }

    /// Links an extra Wi-Fi context to an existing profile.
    @discardableResult
    public func addContext(profileId: Int64, context: String) throws -> Profile {
        let trimmed = context.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw TrackerError.invalidRange("a Wi-Fi context must not be empty") }
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

    /// Unlinks a Wi-Fi context. A profile may end up without contexts; it then
    /// only starts through manual control.
    @discardableResult
    public func removeContext(profileId: Int64, context: String) throws -> Profile {
        try database.run(
            "DELETE FROM profile_contexts WHERE profile_id = ? AND context_name = ? COLLATE NOCASE;",
            [.int(profileId), .text(context)]
        )
        guard let profile = try profile(id: profileId) else { throw TrackerError.unknownProfile(String(profileId)) }
        return profile
    }

    // MARK: - Projects

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
        // The number stays unique within the organization, also when renumbering.
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

    /// Removes a project. Existing time entries stay but lose their project link
    /// (the foreign key sets it to NULL), and the chosen active project is cleared
    /// if it pointed here. Used to undo a just-added project.
    public func deleteProject(id: Int64) throws {
        guard try project(id: id) != nil else { throw TrackerError.unknownProject(String(id)) }
        try database.run("DELETE FROM projects WHERE id = ?;", [.int(id)])
    }

    /// Ids of the blocks that reference a project, so a deleted project can be
    /// restored together with its links.
    public func entryIds(projectId: Int64) throws -> [Int64] {
        try database.query("SELECT id FROM time_entries WHERE project_id = ?;", [.int(projectId)])
            .compactMap { $0.int("id") }
    }

    // MARK: - Profile state

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

    // MARK: - Time entries

    @discardableResult
    public func createEntry(
        profileId: Int64,
        projectId: Int64?,
        startedAt: Date,
        endedAt: Date?,
        breakStartedAt: Date? = nil,
        breakEndedAt: Date? = nil,
        status: EntryStatus,
        source: EntrySource,
        note: String?
    ) throws -> TimeEntry {
        let now = Date()
        let id = try database.run(
            """
            INSERT INTO time_entries (profile_id, project_id, started_at, ended_at, break_started_at, break_ended_at, status, source, note, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .int(profileId),
                projectId.map { SQLValue.int($0) } ?? .null,
                .int(Int64(startedAt.timeIntervalSince1970)),
                endedAt.map { SQLValue.int(Int64($0.timeIntervalSince1970)) } ?? .null,
                breakStartedAt.map { SQLValue.int(Int64($0.timeIntervalSince1970)) } ?? .null,
                breakEndedAt.map { SQLValue.int(Int64($0.timeIntervalSince1970)) } ?? .null,
                .text(status.rawValue),
                .text(source.rawValue),
                note.map { SQLValue.text($0) } ?? .null,
                .int(Int64(now.timeIntervalSince1970)),
                .int(Int64(now.timeIntervalSince1970)),
            ]
        )
        return TimeEntry(
            id: id, profileId: profileId, projectId: projectId, startedAt: startedAt, endedAt: endedAt,
            breakStartedAt: breakStartedAt, breakEndedAt: breakEndedAt,
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

    /// Blocks that start in the window [from, to).
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
        breakStartedAt: Date?? = nil,
        breakEndedAt: Date?? = nil,
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
        if let breakStartedAt {
            assignments.append("break_started_at = ?")
            parameters.append(breakStartedAt.map { SQLValue.int(Int64($0.timeIntervalSince1970)) } ?? .null)
        }
        if let breakEndedAt {
            assignments.append("break_ended_at = ?")
            parameters.append(breakEndedAt.map { SQLValue.int(Int64($0.timeIntervalSince1970)) } ?? .null)
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

    public func duplicateEntry(id: Int64) throws -> TimeEntry {
        guard let entry = try self.entry(id: id) else { throw TrackerError.unknownEntry(id) }
        guard entry.status != .running else {
            throw TrackerError.invalidRange("a running block cannot be duplicated")
        }
        return try createEntry(
            profileId: entry.profileId,
            projectId: entry.projectId,
            startedAt: entry.startedAt,
            endedAt: entry.endedAt,
            breakStartedAt: entry.breakStartedAt,
            breakEndedAt: entry.breakEndedAt,
            status: entry.status,
            source: entry.source,
            note: entry.note
        )
    }

    /// Records a break on the block itself. The block keeps its start and end, so
    /// the day stays one row; the break only lowers the worked duration. The break
    /// must fall within the block and have a positive duration.
    @discardableResult
    public func setBreak(id: Int64, breakStart: Date, breakEnd: Date) throws -> TimeEntry {
        guard let entry = try self.entry(id: id) else { throw TrackerError.unknownEntry(id) }
        guard entry.status != .running else {
            throw TrackerError.invalidRange("a running block cannot get a fixed break")
        }
        guard let endedAt = entry.endedAt else {
            throw TrackerError.invalidRange("a block without an end cannot get a break")
        }
        guard breakStart >= entry.startedAt, breakEnd <= endedAt, breakStart < breakEnd else {
            throw TrackerError.invalidRange("the break must fall within the block and have a positive duration")
        }

        try updateEntry(id: id, breakStartedAt: .some(breakStart), breakEndedAt: .some(breakEnd))
        guard let updated = try self.entry(id: id) else { throw TrackerError.unknownEntry(id) }
        return updated
    }

    /// Removes the recorded break; the block keeps its full duration.
    public func clearBreak(id: Int64) throws {
        guard try entry(id: id) != nil else { throw TrackerError.unknownEntry(id) }
        try updateEntry(id: id, breakStartedAt: .some(nil), breakEndedAt: .some(nil))
    }

    // MARK: - Event log

    /// Records the event. Returns `false` if the key already existed (repeat).
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

    // MARK: - Settings

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

    // MARK: - Converting rows

    /// Contexts are fetched separately; here an empty list is shown until the caller fills it.
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
            ),
            hourlyRateCents: Int(row.int("hourly_rate_cents") ?? 0),
            currency: Currency(rawValue: row.string("currency") ?? "") ?? .eur,
            billingAddress: row.string("billing_address"),
            vatNumber: row.string("vat_number"),
            vatRatePercent: Int(row.int("vat_rate_percent") ?? 21),
            poNumber: row.string("po_number"),
            billingEmail: row.string("billing_email"),
            latitude: row.double("latitude"),
            longitude: row.double("longitude"),
            presenceRadiusMeters: Int(row.int("presence_radius_m") ?? 150)
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
            breakStartedAt: row.date("break_started_at"),
            breakEndedAt: row.date("break_ended_at"),
            status: EntryStatus(rawValue: row.string("status") ?? "") ?? .open,
            source: EntrySource(rawValue: row.string("source") ?? "") ?? .manual,
            note: row.string("note"),
            createdAt: row.date("created_at") ?? Date(timeIntervalSince1970: 0),
            updatedAt: row.date("updated_at") ?? Date(timeIntervalSince1970: 0)
        )
    }
}
