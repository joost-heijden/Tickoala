import Foundation

public enum CSVExport {
    public static let header = [
        "id", "profiel", "context", "projectnummer", "projectnaam",
        "datum", "start", "einde", "duur_uren", "duur_minuten",
        "uurtarief", "bedrag",
        "status", "bron", "notitie",
    ]

    /// Exporteert alle blokken die in [from, to) beginnen. Een lopend of open blok
    /// krijgt een leeg einde en de duur tot `now`, met de status erbij.
    ///
    /// Staat er automatische pauzeaftrek aan, dan komt er per klant per dag een
    /// extra regel met een negatieve duur. De duur-kolom telt daardoor op tot de
    /// netto uren; met `includeBreaks: false` krijg je puur de ruwe blokken.
    public static func export(
        store: Store,
        from: Date,
        to: Date,
        profileId: Int64? = nil,
        now: Date = Date(),
        includeBreaks: Bool = true
    ) throws -> String {
        guard from < to else { throw TrackerError.invalidRange("de begindatum moet voor de einddatum liggen") }

        var profileCache: [Int64: Profile] = [:]
        var projectCache: [Int64: Project] = [:]
        let calendar = Formatting.calendar

        func profile(_ id: Int64) throws -> Profile? {
            if let cached = profileCache[id] { return cached }
            let loaded = try store.profile(id: id)
            if let loaded { profileCache[id] = loaded }
            return loaded
        }

        // Regels krijgen een sorteersleutel, zodat de pauzeregel netjes achter de
        // blokken van diezelfde klant op diezelfde dag terechtkomt.
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
                    // De contextkolom toont alle wifi-contexten van het profiel, niet per se
                    // de specifieke SSID die dit blok startte (die staat in het eventlog).
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
                        "pauze",
                        "regel",
                        profile.map { "automatische pauzeaftrek (\($0.breakRule.summary))" } ?? "automatische pauzeaftrek",
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
