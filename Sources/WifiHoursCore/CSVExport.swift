import Foundation

public enum CSVExport {
    public static let header = [
        "id", "profiel", "context", "projectnummer", "projectnaam",
        "datum", "start", "einde", "duur_uren", "duur_minuten",
        "status", "bron", "notitie",
    ]

    /// Exporteert alle blokken die in [from, to) beginnen. Een lopend of open blok
    /// krijgt een leeg einde en de duur tot `now`, met de status erbij.
    public static func export(
        store: Store,
        from: Date,
        to: Date,
        profileId: Int64? = nil,
        now: Date = Date()
    ) throws -> String {
        guard from < to else { throw TrackerError.invalidRange("de begindatum moet voor de einddatum liggen") }

        var profileCache: [Int64: Profile] = [:]
        var projectCache: [Int64: Project] = [:]
        var lines = [row(header)]

        for entry in try store.entries(from: from, to: to, profileId: profileId) {
            let profile: Profile?
            if let cached = profileCache[entry.profileId] {
                profile = cached
            } else {
                profile = try store.profile(id: entry.profileId)
                if let profile { profileCache[entry.profileId] = profile }
            }

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
            lines.append(row([
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
                entry.status.rawValue,
                entry.source.rawValue,
                entry.note ?? "",
            ]))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func row(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",")
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
