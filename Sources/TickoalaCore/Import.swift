import Foundation

/// Another time tracker whose CSV export the importer understands.
public enum ImportFormat: String, CaseIterable, Sendable {
    case toggl
    case harvest
    case clockify

    public var label: String {
        switch self {
        case .toggl: return "Toggl Track"
        case .harvest: return "Harvest"
        case .clockify: return "Clockify"
        }
    }
}

/// One block read from a foreign export, before it lands in the database.
public struct ImportedEntry: Equatable, Sendable {
    public var client: String
    public var project: String
    public var note: String
    public var tags: [String]
    public var startedAt: Date
    public var endedAt: Date

    public init(
        client: String,
        project: String,
        note: String,
        tags: [String] = [],
        startedAt: Date,
        endedAt: Date
    ) {
        self.client = client
        self.project = project
        self.note = note
        self.tags = tags
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// What an import did, for the command line and the summary dialog.
public struct ImportSummary: Equatable, Sendable {
    public var entries = 0
    public var profilesCreated = 0
    public var projectsCreated = 0
    public var skipped = 0
    public var firstDay: Date?
    public var lastDay: Date?

    public init() {}

    /// A one-line result, e.g. `120 blocks, 2 clients, 3 projects (1 already there)`.
    public var description: String {
        var parts = ["\(entries) block\(entries == 1 ? "" : "s")"]
        if profilesCreated > 0 { parts.append("\(profilesCreated) new client\(profilesCreated == 1 ? "" : "s")") }
        if projectsCreated > 0 { parts.append("\(projectsCreated) new project\(projectsCreated == 1 ? "" : "s")") }
        if skipped > 0 { parts.append("\(skipped) skipped as already present") }
        var line = parts.joined(separator: ", ")
        if let first = firstDay, let last = lastDay {
            let range = first == last ? Formatting.day(first) : "\(Formatting.day(first)) – \(Formatting.day(last))"
            line += " · \(range)"
        }
        return line
    }
}

/// Reads the CSV that Toggl Track, Harvest and Clockify export and turns each row
/// into a block. The column names of these exports drift between versions, so the
/// columns are matched by name rather than by position, and anything that cannot
/// be read as a block is skipped instead of guessed.
public enum Importer {
    /// Parses the export into blocks, without touching the database. With `user`
    /// set, only rows belonging to that person are kept — handy for a team export
    /// where you only want your own time.
    public static func parse(_ text: String, format: ImportFormat, user: String? = nil) throws -> [ImportedEntry] {
        let table = Table(text)
        guard table.hasAnyRow else { throw TrackerError.invalidRange("the file has no rows") }
        let filter = user?.trimmingCharacters(in: .whitespaces).lowercased()
        let wanted = (filter?.isEmpty == false) ? filter : nil
        switch format {
        case .toggl, .clockify:
            return timedEntries(table, user: wanted)
        case .harvest:
            return hoursEntries(table, user: wanted)
        }
    }

    /// The person a row belongs to: the `User` column, or Harvest's employee or
    /// first and last name.
    private static func rowUser(_ table: Table, _ row: [String]) -> String {
        if let user = table.value(row, ["user", "employee"]) { return user.lowercased() }
        let first = table.value(row, ["firstname"]) ?? ""
        let last = table.value(row, ["lastname"]) ?? ""
        return "\(first) \(last)".trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Writes the blocks into the database. Clients and projects are reused by
    /// name and created when missing; a block that is already there (same client,
    /// start and end) is skipped, so importing the same file twice is harmless.
    @discardableResult
    public static func apply(
        _ entries: [ImportedEntry],
        to store: Store,
        fallbackClient: String = "",
        tagsEnabled: Bool = false
    ) throws -> ImportSummary {
        var summary = ImportSummary()
        var profilesByKey: [String: Profile] = [:]
        for profile in try store.profiles() { profilesByKey[profile.name.lowercased()] = profile }
        var projectsByProfile: [Int64: [String: Project]] = [:]

        for entry in entries {
            let clientName = entry.client.isEmpty ? fallbackClient : entry.client
            guard !clientName.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            let profile = try ensureClient(clientName, in: store, cache: &profilesByKey, summary: &summary)
            let project = try ensureProject(entry.project, for: profile.id, in: store, cache: &projectsByProfile, summary: &summary)

            if try store.entryExists(profileId: profile.id, startedAt: entry.startedAt, endedAt: entry.endedAt) {
                summary.skipped += 1
                continue
            }
            _ = try store.createEntry(
                profileId: profile.id,
                projectId: project?.id,
                startedAt: entry.startedAt,
                endedAt: entry.endedAt,
                idleSeconds: 0,
                // With tags off the imported labels are held aside, so switching
                // tags on later still surfaces them.
                tags: tagsEnabled ? entry.tags : [],
                importedTags: tagsEnabled ? [] : entry.tags,
                status: .completed,
                source: .imported,
                kind: .work,
                note: entry.note.isEmpty ? nil : entry.note
            )
            summary.entries += 1
            let day = Formatting.calendar.startOfDay(for: entry.startedAt)
            if summary.firstDay == nil || day < summary.firstDay! { summary.firstDay = day }
            if summary.lastDay == nil || day > summary.lastDay! { summary.lastDay = day }
        }
        return summary
    }

    private static func ensureClient(
        _ name: String,
        in store: Store,
        cache: inout [String: Profile],
        summary: inout ImportSummary
    ) throws -> Profile {
        let key = name.lowercased()
        if let existing = cache[key] { return existing }
        // The cache was seeded with every existing client, so a miss means a new
        // one. `ensureProfile` still checks the database, keeping the count honest
        // even if the cache missed for another reason.
        let profile = try store.ensureProfile(name: name)
        summary.profilesCreated += 1
        cache[key] = profile
        return profile
    }

    private static func ensureProject(
        _ name: String,
        for profileId: Int64,
        in store: Store,
        cache: inout [Int64: [String: Project]],
        summary: inout ImportSummary
    ) throws -> Project? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if cache[profileId] == nil {
            var map: [String: Project] = [:]
            for project in try store.projects(profileId: profileId, includeInactive: true) {
                map[project.name.lowercased()] = project
            }
            cache[profileId] = map
        }
        let key = trimmed.lowercased()
        if let existing = cache[profileId]?[key] { return existing }
        let number = try store.nextProjectNumber(profileId: profileId)
        let project = try store.createProject(profileId: profileId, number: number, name: trimmed)
        cache[profileId]?[key] = project
        summary.projectsCreated += 1
        return project
    }

    // MARK: - Toggl / Clockify

    /// These exports carry a start date and time and either an end or a duration.
    private static func timedEntries(_ table: Table, user: String?) -> [ImportedEntry] {
        var result: [ImportedEntry] = []
        for row in table.rows {
            if let user, rowUser(table, row) != user { continue }
            let client = table.value(row, ["client"]) ?? ""
            let project = table.value(row, ["project"]) ?? ""
            let note = firstNonEmpty(table.value(row, ["description"]), table.value(row, ["task"]))

            guard let startDate = table.value(row, ["startdate", "date"]) else { continue }
            let startTime = table.value(row, ["starttime", "start"]) ?? ""
            guard let start = moment(date: startDate, time: startTime) else { continue }

            var end: Date?
            if let endTime = table.value(row, ["endtime", "end"]) {
                let endDate = table.value(row, ["enddate"]) ?? startDate
                end = moment(date: endDate, time: endTime)
            }
            if end == nil, let durationText = table.value(row, ["duration", "durationh", "durationdecimal"]) {
                end = durationSeconds(durationText).map { start.addingTimeInterval($0) }
            }
            guard let endedAt = end, endedAt > start else { continue }
            result.append(ImportedEntry(
                client: client, project: project, note: note,
                tags: Tags.parse(table.value(row, ["tags"])),
                startedAt: start, endedAt: endedAt
            ))
        }
        return result
    }

    // MARK: - Harvest

    /// Harvest exports a date and a decimal number of hours, with no clock times.
    /// The blocks are laid out back to back from the start of the workday, one per
    /// client per day, in the order the file lists them.
    private static func hoursEntries(_ table: Table, user: String?) -> [ImportedEntry] {
        var rows: [(date: Date, client: String, project: String, note: String, hours: TimeInterval)] = []
        for row in table.rows {
            if let user, rowUser(table, row) != user { continue }
            guard let dateText = table.value(row, ["date"]),
                  let day = moment(date: dateText, time: "") else { continue }
            guard let hoursText = table.value(row, ["hours", "duration", "durationdecimal"]),
                  let hours = decimalHours(hoursText), hours > 0 else { continue }
            let client = table.value(row, ["client"]) ?? ""
            let project = table.value(row, ["project"]) ?? ""
            let note = firstNonEmpty(table.value(row, ["notes", "note", "description"]), table.value(row, ["task"]))
            rows.append((day, client, project, note, hours))
        }
        rows.sort { $0.date < $1.date }

        var cursors: [String: Date] = [:]
        var result: [ImportedEntry] = []
        for item in rows {
            let day = Formatting.calendar.startOfDay(for: item.date)
            let key = "\(item.client.lowercased())|\(Formatting.day(day))"
            let workdayStart = Formatting.calendar.date(byAdding: .hour, value: 9, to: day) ?? day
            let start = max(cursors[key] ?? workdayStart, workdayStart)
            let end = start.addingTimeInterval(item.hours * 3600)
            cursors[key] = end
            result.append(ImportedEntry(
                client: item.client, project: item.project, note: item.note, startedAt: start, endedAt: end
            ))
        }
        return result
    }

    // MARK: - Values

    /// The main note if there is one, otherwise the structured task name, so a
    /// block never loses its only description.
    private static func firstNonEmpty(_ primary: String?, _ fallback: String?) -> String {
        for candidate in [primary, fallback] {
            let value = candidate?.trimmingCharacters(in: .whitespaces) ?? ""
            if !value.isEmpty { return value }
        }
        return ""
    }

    /// A date and an optional time string into a Date. Tries the app's own parser
    /// first (ISO), then the common day-first and month-first layouts.
    private static func moment(date: String, time: String) -> Date? {
        let date = date.trimmingCharacters(in: .whitespaces)
        let time = time.trimmingCharacters(in: .whitespaces)
        let combined = time.isEmpty ? date : "\(date) \(time)"
        if let parsed = Formatting.parseDate(combined) { return parsed }
        let layouts = ["dd-MM-yyyy HH:mm:ss", "dd/MM/yyyy HH:mm:ss", "MM/dd/yyyy HH:mm:ss",
                       "yyyy/MM/dd HH:mm:ss", "dd-MM-yyyy", "dd/MM/yyyy", "MM/dd/yyyy", "yyyy/MM/dd"]
        for layout in layouts {
            if let parsed = formatter(layout).date(from: combined) { return parsed }
        }
        return nil
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Formatting.calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Formatting.calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }

    /// `HH:MM:SS`, `H:MM` or a decimal number of hours into seconds.
    private static func durationSeconds(_ text: String) -> TimeInterval? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.contains(":") {
            let parts = text.split(separator: ":").map { Double($0) }
            guard !parts.contains(where: { $0 == nil }) else { return nil }
            let values = parts.compactMap { $0 }
            if values.count == 3 { return values[0] * 3600 + values[1] * 60 + values[2] }
            if values.count == 2 { return values[0] * 3600 + values[1] * 60 }
            return nil
        }
        return decimalHours(text).map { $0 * 3600 }
    }

    private static func decimalHours(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    /// A minimal CSV table. Quotes protect the delimiter inside a field, and a
    /// doubled quote is a literal quote. A leading byte-order mark is dropped.
    private struct Table {
        let headers: [String]
        let rows: [[String]]

        init(_ text: String) {
            var text = text
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            let all = Table.split(text)
            guard let header = all.first else {
                headers = []
                rows = []
                return
            }
            headers = header.map(Table.normalize)
            rows = all.dropFirst().filter { row in row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) }
        }

        var hasAnyRow: Bool { !rows.isEmpty }

        /// Header lookup by normalized name; empty fields fall through to the
        /// next candidate name, so a column that exists but is blank does not
        /// stop a fallback from matching.
        func value(_ row: [String], _ names: [String]) -> String? {
            for name in names {
                guard let index = headers.firstIndex(of: name), index < row.count else { continue }
                let value = row[index].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
            return nil
        }

        static func normalize(_ header: String) -> String {
            let allowed = CharacterSet.alphanumerics
            return String(header.lowercased().unicodeScalars.filter { allowed.contains($0) }.map { Character($0) })
        }

        static func split(_ text: String) -> [[String]] {
            var rows: [[String]] = []
            var field = ""
            var row: [String] = []
            var inQuotes = false
            var index = text.startIndex
            while index < text.endIndex {
                let character = text[index]
                if inQuotes {
                    if character == "\"" {
                        let next = text.index(after: index)
                        if next < text.endIndex, text[next] == "\"" {
                            field.append("\"")
                            index = next
                        } else {
                            inQuotes = false
                        }
                    } else {
                        field.append(character)
                    }
                } else {
                    switch character {
                    case "\"": inQuotes = true
                    case ",": row.append(field); field = ""
                    case "\n": row.append(field); field = ""; rows.append(row); row = []
                    case "\r": break
                    default: field.append(character)
                    }
                }
                index = text.index(after: index)
            }
            if !field.isEmpty || !row.isEmpty {
                row.append(field)
                rows.append(row)
            }
            return rows
        }
    }
}
