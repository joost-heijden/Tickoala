import Foundation

public enum CSVExport {
    public static let header = [
        "id", "profile", "context", "project_number", "project_name",
        "date", "start", "end", "duration_hours", "duration_minutes",
        "hourly_rate", "amount", "currency",
        "status", "source", "note",
    ]

    /// Exports all blocks that start in [from, to). A running or open block gets
    /// an empty end and the duration up to `now`, with its status.
    ///
    /// If automatic break deduction is enabled, an extra row with a negative
    /// duration is added per client per day. The duration column therefore adds
    /// up to the net hours; with `includeBreaks: false` you get the raw blocks only.
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

        // Rows get a sort key, so the break row ends up neatly after the blocks of
        // that same client on that same day.
        var rows: [(day: Date, profileName: String, order: Int, fields: [String])] = []

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
            rows.append((
                day: calendar.startOfDay(for: entry.startedAt),
                profileName: profile?.name ?? "",
                order: Int(entry.startedAt.timeIntervalSince1970),
                fields: [
                    String(entry.id),
                    profile?.name ?? "",
                    // The context column shows all Wi-Fi contexts of the profile, not
                    // necessarily the specific SSID that started this block (that is
                    // in the event log).
                    profile?.contexts.joined(separator: "; ") ?? "",
                    project?.number ?? "",
                    project?.name ?? "",
                    Formatting.day(entry.startedAt),
                    Formatting.clock(entry.startedAt),
                    entry.endedAt.map(Formatting.clock) ?? "",
                    Formatting.decimalHours(duration),
                    String(Int(duration.rounded() / 60)),
                    Formatting.decimalAmount(cents: profile?.hourlyRateCents ?? 0),
                    Formatting.decimalAmount(cents: profile?.amountCents(for: duration) ?? 0),
                    (profile?.currency ?? .eur).rawValue,
                    entry.status.rawValue,
                    entry.source.rawValue,
                    entry.note ?? "",
                ]
            ))
        }

        if includeBreaks {
            let deductions = try Reporting.breakDeductions(
                store: store, from: from, to: to, profileId: profileId, now: now, calendar: calendar
            )
            for (key, seconds) in deductions {
                let profile = try profile(key.profileId)
                rows.append((
                    day: key.day,
                    profileName: profile?.name ?? "",
                    order: Int.max,
                    fields: [
                        "",
                        profile?.name ?? "",
                        profile?.contexts.joined(separator: "; ") ?? "",
                        "",
                        "",
                        Formatting.day(key.day),
                        "",
                        "",
                        "-" + Formatting.decimalHours(seconds),
                        "-" + String(Int(seconds.rounded() / 60)),
                        Formatting.decimalAmount(cents: profile?.hourlyRateCents ?? 0),
                        Formatting.decimalAmount(cents: -(profile?.amountCents(for: seconds) ?? 0)),
                        (profile?.currency ?? .eur).rawValue,
                        "break",
                        "rule",
                        profile.map { "automatic break deduction (\($0.breakRule.summary))" } ?? "automatic break deduction",
                    ]
                ))
            }
        }

        rows.sort {
            if $0.day != $1.day { return $0.day < $1.day }
            if $0.profileName != $1.profileName { return $0.profileName < $1.profileName }
            return $0.order < $1.order
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
