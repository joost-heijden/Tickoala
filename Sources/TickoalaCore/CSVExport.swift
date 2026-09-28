import Foundation

public enum CSVExport {
    public static let header = [
        "profile", "project_name", "date", "start", "end", "break",
        "duration_hours", "hourly_rate", "currency", "note",
    ]

    /// Exports all blocks that start in [from, to). A running or open block gets
    /// an empty end and the duration up to `now`, with its status.
    ///
    /// If automatic break deduction is enabled, the deduction for that client on
    /// that day (a negative value) sits in the `break` column of the last block
    /// row of that day. With `includeBreaks: false` that column stays empty and
    /// you get the raw blocks only.
    public static func export(
        store: Store,
        from: Date,
        to: Date,
        profileId: Int64? = nil,
        now: Date = Date(),
        includeBreaks: Bool = true
    ) throws -> String {
        guard from < to else { throw TrackerError.invalidRange("the start date must be before the end date") }

        var profileCache: [Int64: Profile] = [:]
        var projectCache: [Int64: Project] = [:]
        let calendar = Formatting.calendar

        func profile(_ id: Int64) throws -> Profile? {
            if let cached = profileCache[id] { return cached }
            let loaded = try store.profile(id: id)
            if let loaded { profileCache[id] = loaded }
            return loaded
        }

        // Rows carry the day and client so the break deduction can be attached to
        // the last block of that same client on that same day after sorting.
        var rows: [(day: Date, profileName: String, order: Int, key: ProfileDay, fields: [String])] = []

        for entry in try store.entries(from: from, to: to, profileId: profileId) {
            let profile = try profile(entry.profileId)

            var project: Project?
            if let projectId = entry.projectId {
                if let cached = projectCache[projectId] {
                    project = cached
                } else {
                    project = try store.project(id: projectId)
                    if let project { projectCache[projectId] = project }
                }
            }

            let duration = entry.duration(now: now)
            let day = calendar.startOfDay(for: entry.startedAt)
            rows.append((
                day: day,
                profileName: profile?.name ?? "",
                order: Int(entry.startedAt.timeIntervalSince1970),
                key: ProfileDay(profileId: entry.profileId, day: day),
                fields: [
                    profile?.name ?? "",
                    project?.name ?? "",
                    Formatting.day(entry.startedAt),
                    Formatting.clock(entry.startedAt),
                    entry.endedAt.map(Formatting.clock) ?? "",
                    "",
                    Formatting.decimalHours(duration),
                    Formatting.decimalAmount(cents: profile?.hourlyRateCents ?? 0),
                    (profile?.currency ?? .eur).rawValue,
                    entry.note ?? "",
                ]
            ))
        }

        rows.sort {
            if $0.day != $1.day { return $0.day < $1.day }
            if $0.profileName != $1.profileName { return $0.profileName < $1.profileName }
            return $0.order < $1.order
        }

        if includeBreaks {
            let deductions = try Reporting.breakDeductions(
                store: store, from: from, to: to, profileId: profileId, now: now, calendar: calendar
            )
            var lastRow: [ProfileDay: Int] = [:]
            for (index, row) in rows.enumerated() { lastRow[row.key] = index }
            for (key, seconds) in deductions {
                guard let index = lastRow[key] else { continue }
                rows[index].fields[5] = "-" + Formatting.decimalHours(seconds)
            }
        }

        return ([row(header)] + rows.map { row($0.fields) }).joined(separator: "\n") + "\n"
    }

    static func row(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",")
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
