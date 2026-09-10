import Foundation
import WifiHoursCore

let usage = """
wifihours — lokale urenregistratie, gevoed door ControlPlane

ControlPlane-adapter (dom, idempotent):
  wifihours start --context <naam> [--at <tijd>]
  wifihours stop  --context <naam> [--at <tijd>]

Status en onderhoud:
  wifihours status [--json]
  wifihours tick                       stops afronden, vastgelopen blokken markeren
  wifihours events [--limit 20]
  wifihours db                         pad naar de database

Profielen (een profiel mag aan meerdere wifinetwerken hangen):
  wifihours profile list
  wifihours profile add --name <naam> --context <ssid>[,ssid2,...]
  wifihours profile edit --profile <naam|context> [--name x] [--active true|false]
  wifihours profile context list   --profile <naam|context>
  wifihours profile context add    --profile <naam|context> --context <ssid>[,ssid2,...]
  wifihours profile context remove --profile <naam|context> --context <ssid>[,ssid2,...]

Projecten:
  wifihours project list [--profile <naam>]
  wifihours project add --profile <naam> --number <nummer> --name <projectnaam>
  wifihours project select --profile <naam> --number <nummer>
  wifihours project edit --profile <naam> --number <nummer> [--new-number y] [--name x] [--active true|false]

Automatische pauzeaftrek (per klant):
  wifihours break list
  wifihours break set --profile <naam> [--enabled true|false] [--minutes 30] [--threshold 6:00]
                                       --threshold accepteert 6:00, 6u of 360 (minuten)

Timer:
  wifihours timer start|stop --profile <naam>
  wifihours pause  --profile <naam>
  wifihours resume --profile <naam>

Blokken corrigeren:
  wifihours entry list [--period day|week|month] [--date <dag>] [--from <tijd> --to <tijd>] [--profile <naam>]
  wifihours entry add --profile <naam> --number <projectnummer> --start <tijd> --end <tijd> [--note "..."]
  wifihours entry edit --id <n> [--start <tijd>] [--end <tijd>] [--number <projectnummer>] [--status completed|open] [--note "..."]
  wifihours entry delete --id <n>

Overzicht en export:
  wifihours report [day|week|month] [--date <dag>] [--profile <naam>]
  wifihours export [--period month] [--date <dag>] [--from <tijd> --to <tijd>] [--profile <naam>] [--out <bestand>]

Instellingen:
  wifihours config list
  wifihours config set <sleutel> <waarde>
"""

func makeTracker() throws -> Tracker {
    let path = try Store.defaultDatabasePath()
    return Tracker(store: try Store(path: path))
}

func resolveProfile(_ arguments: Arguments, _ store: Store) throws -> Profile {
    if let needle = arguments.string("profile") {
        return try store.profile(matching: needle)
    }
    let profiles = try store.profiles(includeInactive: false)
    if profiles.count == 1 { return profiles[0] }
    if profiles.isEmpty {
        throw CLIError.failure("nog geen profiel aangemaakt — gebruik: wifihours profile add --name ... --context ...")
    }
    throw CLIError.usage("meerdere profielen; geef --profile <naam> op (\(profiles.map(\.name).joined(separator: ", ")))")
}

func resolvePeriod(_ arguments: Arguments, positionalIndex: Int) -> ReportPeriod? {
    if let raw = arguments.string("period") ?? arguments.word(positionalIndex) {
        return ReportPeriod(rawValue: raw.lowercased())
    }
    return nil
}

func boolOption(_ arguments: Arguments, _ name: String) -> Bool? {
    guard let raw = arguments.string(name)?.lowercased() else { return nil }
    if ["true", "ja", "yes", "1", "aan"].contains(raw) { return true }
    if ["false", "nee", "no", "0", "uit"].contains(raw) { return false }
    return nil
}

func run() throws {
    let raw = Array(CommandLine.arguments.dropFirst())
    let arguments = Arguments(raw)
    guard let command = arguments.word(0), !arguments.flag("help") else {
        print(usage)
        return
    }

    switch command {
    case "help", "--help", "-h":
        print(usage)

    case "start", "stop":
        let tracker = try makeTracker()
        let context = try arguments.require("context")
        let at = try arguments.date("at", default: Date()) ?? Date()
        let source = EntrySource(rawValue: arguments.string("source") ?? "controlplane") ?? .controlplane
        let event = ContextEvent(context: context, kind: command == "start" ? .start : .stop, at: at, source: source)
        let outcome = try tracker.handle(event)
        print("\(context) \(command): \(outcome.summary)")

    case "status":
        try printStatus(arguments)

    case "tick":
        let tracker = try makeTracker()
        try tracker.tick()
        try printStatus(arguments)

    case "events":
        let tracker = try makeTracker()
        let events = try tracker.store.recentEvents(limit: arguments.int("limit") ?? 20)
        if events.isEmpty { print("nog geen events"); return }
        for event in events {
            print("\(Formatting.timestamp(event.at))  \(event.context)  \(event.kind)  \(event.outcome)  \(event.detail ?? "")")
        }

    case "db":
        print(try Store.defaultDatabasePath())

    case "profile":
        try runProfile(arguments)

    case "project":
        try runProject(arguments)

    case "timer":
        try runTimer(arguments)

    case "pause", "resume":
        let tracker = try makeTracker()
        let profile = try resolveProfile(arguments, tracker.store)
        if command == "pause" {
            let closed = try tracker.pause(profileId: profile.id)
            print(closed.map { "pauze — blok \($0.id) afgesloten (\(Formatting.duration($0.duration())))" } ?? "pauze — er liep geen timer")
        } else {
            let entry = try tracker.resume(profileId: profile.id)
            print("hervat — nieuw blok \(entry.id) om \(Formatting.clock(entry.startedAt))")
        }

    case "break":
        try runBreak(arguments)

    case "entry":
        try runEntry(arguments)

    case "report":
        try runReport(arguments)

    case "export":
        try runExport(arguments)

    case "config":
        try runConfig(arguments)

    default:
        throw CLIError.usage("onbekend commando: \(command)\n\n\(usage)")
    }
}

// MARK: - Status

func printStatus(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    let status = try tracker.status()

    if arguments.flag("json") {
        var profiles: [String] = []
        for item in status.profiles {
            let fields: [String] = [
                "\"profiel\":\"\(jsonEscape(item.profile.name))\"",
                "\"contexten\":\(jsonArray(item.profile.contexts))",
                "\"modus\":\"\(item.mode.rawValue)\"",
                "\"project\":\(item.project.map { "\"\(jsonEscape($0.label))\"" } ?? "null")",
                "\"blok_seconden\":\(Int(item.elapsedCurrent))",
                "\"vandaag_seconden\":\(Int(item.todayTotal))",
                "\"week_seconden\":\(Int(item.weekTotal))",
                "\"aandacht\":\(item.attention.map { "\"\(jsonEscape($0))\"" } ?? "null")",
            ]
            profiles.append("{\(fields.joined(separator: ","))}")
        }
        print("{\"modus\":\"\(status.mode.rawValue)\",\"titel\":\"\(jsonEscape(status.menuBarTitle))\",\"open_blokken\":\(status.openEntryCount),\"profielen\":[\(profiles.joined(separator: ","))]}")
        return
    }

    if status.profiles.isEmpty {
        print("nog geen profiel aangemaakt — gebruik: wifihours profile add --name ... --context ...")
        return
    }
    print("\(status.mode.label)  \(status.menuBarTitle)")
    for item in status.profiles {
        var line = "  \(item.profile.name) [\(item.profile.contextsLabel)] — \(item.mode.label)"
        line += "  project: \(item.project?.label ?? "geen")"
        if let running = item.runningEntry {
            line += "  loopt sinds \(Formatting.clock(running.startedAt)) (\(Formatting.duration(item.elapsedCurrent)))"
        }
        if let pending = item.pendingStopAt {
            line += "  stop gepland vanaf \(Formatting.clock(pending))"
        }
        line += "  vandaag \(Formatting.duration(item.todayTotal))  week \(Formatting.duration(item.weekTotal))"
        if item.todayBreak > 0 || item.weekBreak > 0 {
            line += "  (netto; pauze vandaag -\(Formatting.duration(item.todayBreak)), week -\(Formatting.duration(item.weekBreak)))"
        }
        print(line)
        if let attention = item.attention { print("    ! \(attention)") }
    }
    if status.openEntryCount > 0 {
        print("  \(status.openEntryCount) blok(ken) met status 'open' wachten op correctie (wifihours entry list --period week)")
    }
}

func jsonEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

func jsonArray(_ values: [String]) -> String {
    "[" + values.map { "\"\(jsonEscape($0))\"" }.joined(separator: ",") + "]"
}

/// Splitst een --context-optie met komma's in losse, opgeschoonde wifi-namen
/// en filtert lege of herhaalde waarden eruit.
func contextsList(_ raw: String) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for piece in raw.split(separator: ",") {
        let trimmed = piece.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !seen.contains(trimmed.lowercased()) else { continue }
        seen.insert(trimmed.lowercased())
        result.append(trimmed)
    }
    return result
}

// MARK: - Profielen

func runProfile(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    switch arguments.word(1) ?? "list" {
    case "list":
        let profiles = try tracker.store.profiles()
        if profiles.isEmpty { print("nog geen profielen"); return }
        for profile in profiles {
            let state = try tracker.store.state(profileId: profile.id)
            let project = try state.activeProjectId.flatMap { try tracker.store.project(id: $0) }
            print("\(profile.id)  \(profile.name)  contexten: \(profile.contextsLabel)  actief project: \(project?.label ?? "geen")\(profile.active ? "" : "  [inactief]")")
        }
    case "add":
        let contexts = contextsList(try arguments.require("context"))
        let profile = try tracker.store.createProfile(name: try arguments.require("name"), contexts: contexts)
        print("profiel \(profile.id) aangemaakt: \(profile.name) → \(profile.contextsLabel)")
    case "edit":
        let profile = try resolveProfile(arguments, tracker.store)
        try tracker.store.updateProfile(
            id: profile.id,
            name: arguments.string("name"),
            active: boolOption(arguments, "active")
        )
        print("profiel \(profile.id) bijgewerkt")
    case "context":
        try runProfileContext(arguments, tracker)
    default:
        throw CLIError.usage("gebruik: wifihours profile list|add|edit|context")
    }
}

func runProfileContext(_ arguments: Arguments, _ tracker: Tracker) throws {
    let profile = try resolveProfile(arguments, tracker.store)
    switch arguments.word(2) ?? "list" {
    case "list":
        let contexts = try tracker.store.contexts(profileId: profile.id)
        if contexts.isEmpty { print("(geen wifi-contexten gekoppeld)"); return }
        for context in contexts { print(context) }
    case "add":
        var updated = profile
        for context in contextsList(try arguments.require("context")) {
            updated = try tracker.store.addContext(profileId: profile.id, context: context)
        }
        print("wifi-contexten van \(profile.name): \(updated.contextsLabel)")
    case "remove":
        var updated = profile
        for context in contextsList(try arguments.require("context")) {
            updated = try tracker.store.removeContext(profileId: profile.id, context: context)
        }
        print("wifi-contexten van \(profile.name): \(updated.contextsLabel)")
    default:
        throw CLIError.usage("gebruik: wifihours profile context list|add|remove --profile <naam> --context <ssid>[,ssid2,...]")
    }
}

// MARK: - Projecten

func runProject(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    switch arguments.word(1) ?? "list" {
    case "list":
        let profiles = arguments.string("profile") != nil
            ? [try resolveProfile(arguments, tracker.store)]
            : try tracker.store.profiles()
        for profile in profiles {
            let state = try tracker.store.state(profileId: profile.id)
            print("\(profile.name):")
            let projects = try tracker.store.projects(profileId: profile.id)
            if projects.isEmpty { print("  (geen projecten)") }
            for project in projects {
                let marker = state.activeProjectId == project.id ? "→" : " "
                print("  \(marker) \(project.label)\(project.active ? "" : "  [inactief]")")
            }
        }
    case "add":
        let profile = try resolveProfile(arguments, tracker.store)
        let project = try tracker.createProject(
            profileId: profile.id,
            number: try arguments.require("number"),
            name: try arguments.require("name")
        )
        var message = "project toegevoegd aan \(profile.name): \(project.label)"
        if try tracker.store.state(profileId: profile.id).activeProjectId == project.id {
            message += " (meteen als actief project gezet)"
        }
        print(message)
    case "select":
        let profile = try resolveProfile(arguments, tracker.store)
        let number = try arguments.require("number")
        guard let project = try tracker.store.project(profileId: profile.id, number: number) else {
            throw TrackerError.unknownProject(number)
        }
        let entry = try tracker.selectProject(profileId: profile.id, projectId: project.id)
        var message = "actief project voor \(profile.name): \(project.label)"
        if let entry, entry.projectId == project.id, entry.status == .running {
            message += " (blok \(entry.id) loopt door op dit project)"
        }
        print(message)
    case "edit":
        let profile = try resolveProfile(arguments, tracker.store)
        let number = try arguments.require("number")
        guard let project = try tracker.store.project(profileId: profile.id, number: number) else {
            throw TrackerError.unknownProject(number)
        }
        try tracker.store.updateProject(
            id: project.id,
            number: arguments.string("new-number"),
            name: arguments.string("name"),
            active: boolOption(arguments, "active")
        )
        if let updated = try tracker.store.project(id: project.id) {
            print("project bijgewerkt: \(updated.label)\(updated.active ? "" : "  [inactief]")")
        }
    default:
        throw CLIError.usage("gebruik: wifihours project list|add|select|edit")
    }
}

// MARK: - Pauzeaftrek

/// Leest een drempel als `6:00`, `6u`, `6` (uren) of `360m` (minuten).
func parseMinutes(_ raw: String) throws -> Int {
    let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
    if text.contains(":") {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]), minutes < 60 else {
            throw CLIError.usage("kan tijd niet lezen: '\(raw)' (gebruik bijvoorbeeld 6:00)")
        }
        return hours * 60 + minutes
    }
    if text.hasSuffix("m"), let minutes = Int(text.dropLast()) { return minutes }
    if text.hasSuffix("u"), let hours = Int(text.dropLast()) { return hours * 60 }
    guard let value = Int(text) else {
        throw CLIError.usage("kan tijd niet lezen: '\(raw)' (gebruik 6:00, 6u of 360)")
    }
    // Kaal getal: kleine waarden zijn vrijwel zeker uren, grote zijn minuten.
    return value <= 24 ? value * 60 : value
}

func runBreak(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    switch arguments.word(1) ?? "list" {
    case "list":
        let profiles = try tracker.store.profiles()
        if profiles.isEmpty { print("nog geen profielen"); return }
        for profile in profiles {
            print("\(profile.name): \(profile.breakRule.summary)")
        }
    case "set":
        let profile = try resolveProfile(arguments, tracker.store)
        var rule = profile.breakRule
        if let enabled = boolOption(arguments, "enabled") { rule.enabled = enabled }
        if let minutes = arguments.string("minutes") {
            rule.minutes = try parseMinutes(minutes.allSatisfy(\.isNumber) ? "\(minutes)m" : minutes)
            // Een pauzeduur instellen betekent vrijwel altijd: zet hem ook aan.
            if boolOption(arguments, "enabled") == nil { rule.enabled = rule.minutes > 0 }
        }
        if let threshold = arguments.string("threshold") {
            rule.thresholdMinutes = try parseMinutes(threshold)
        }
        try tracker.store.updateBreakRule(profileId: profile.id, rule: rule)
        print("\(profile.name): \(rule.summary)")
    default:
        throw CLIError.usage("gebruik: wifihours break list|set")
    }
}

// MARK: - Timer

func runTimer(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    let profile = try resolveProfile(arguments, tracker.store)
    switch arguments.word(1) ?? "" {
    case "start":
        let entry = try tracker.start(profileId: profile.id)
        print("blok \(entry.id) loopt sinds \(Formatting.clock(entry.startedAt))")
    case "stop":
        let entry = try tracker.stop(profileId: profile.id)
        print(entry.map { "blok \($0.id) gestopt — \(Formatting.duration($0.duration()))" } ?? "er liep geen timer")
    default:
        throw CLIError.usage("gebruik: wifihours timer start|stop --profile <naam>")
    }
}

// MARK: - Blokken

func runEntry(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    switch arguments.word(1) ?? "list" {
    case "list":
        let profileId = arguments.string("profile") != nil ? try resolveProfile(arguments, tracker.store).id : nil
        let window = try resolveWindow(arguments, defaultPeriod: .day)
        let entries = try tracker.store.entries(from: window.start, to: window.end, profileId: profileId)
        if entries.isEmpty { print("geen blokken tussen \(Formatting.timestamp(window.start)) en \(Formatting.timestamp(window.end))"); return }
        for entry in entries {
            let project = try entry.projectId.flatMap { try tracker.store.project(id: $0) }
            let profile = try tracker.store.profile(id: entry.profileId)
            let end = entry.endedAt.map(Formatting.clock) ?? "…"
            print("\(entry.id)  \(Formatting.day(entry.startedAt))  \(Formatting.clock(entry.startedAt))–\(end)  \(Formatting.duration(entry.duration()))  \(profile?.name ?? "?")  \(project?.label ?? "(geen project)")  \(entry.status.rawValue)  \(entry.source.rawValue)\(entry.note.map { "  \"\($0)\"" } ?? "")")
        }
    case "add":
        let profile = try resolveProfile(arguments, tracker.store)
        let start = try arguments.requireDate("start")
        let end = try arguments.requireDate("end")
        guard end > start else { throw CLIError.usage("--end moet na --start liggen") }
        var projectId: Int64?
        if let number = arguments.string("number") {
            guard let project = try tracker.store.project(profileId: profile.id, number: number) else {
                throw TrackerError.unknownProject(number)
            }
            projectId = project.id
        } else {
            projectId = try tracker.store.state(profileId: profile.id).activeProjectId
        }
        let entry = try tracker.store.createEntry(
            profileId: profile.id, projectId: projectId, startedAt: start, endedAt: end,
            status: .completed, source: .manual, note: arguments.string("note")
        )
        print("blok \(entry.id) toegevoegd: \(Formatting.timestamp(start)) – \(Formatting.clock(end)) (\(Formatting.duration(entry.duration())))")
    case "edit":
        guard let id = arguments.int("id").map(Int64.init) else { throw CLIError.usage("ontbrekende optie --id") }
        guard let existing = try tracker.store.entry(id: id) else { throw TrackerError.unknownEntry(id) }
        var projectId: Int64??
        if let number = arguments.string("number") {
            guard let project = try tracker.store.project(profileId: existing.profileId, number: number) else {
                throw TrackerError.unknownProject(number)
            }
            projectId = .some(project.id)
        }
        var status: EntryStatus?
        if let raw = arguments.string("status") {
            guard let parsed = EntryStatus(rawValue: raw) else { throw CLIError.usage("status moet running, completed of open zijn") }
            status = parsed
        }
        let start = try arguments.date("start", default: nil)
        var end: Date??
        if let raw = arguments.string("end") {
            if raw.isEmpty || raw == "-" {
                end = .some(nil)
            } else {
                end = .some(try arguments.requireDate("end"))
            }
        }
        if let start, let newEnd = end ?? .some(existing.endedAt), let newEnd, newEnd < start {
            throw CLIError.usage("het einde ligt voor het begin")
        }
        // Een blok met een einde is niet meer 'running'.
        if status == nil, case .some(.some) = end, existing.status == .running || existing.status == .open {
            status = .completed
        }
        try tracker.store.updateEntry(
            id: id,
            projectId: projectId,
            startedAt: start,
            endedAt: end,
            status: status,
            note: arguments.string("note").map { Optional($0) }
        )
        if let updated = try tracker.store.entry(id: id) {
            print("blok \(id) bijgewerkt: \(Formatting.timestamp(updated.startedAt)) – \(updated.endedAt.map(Formatting.clock) ?? "…") (\(Formatting.duration(updated.duration())), \(updated.status.rawValue))")
        }
    case "delete":
        guard let id = arguments.int("id").map(Int64.init) else { throw CLIError.usage("ontbrekende optie --id") }
        try tracker.store.deleteEntry(id: id)
        print("blok \(id) verwijderd")
    default:
        throw CLIError.usage("gebruik: wifihours entry list|add|edit|delete")
    }
}

/// Bepaalt het venster uit --from/--to of uit --period/--date.
func resolveWindow(_ arguments: Arguments, defaultPeriod: ReportPeriod) throws -> DateRange {
    if let from = try arguments.date("from", default: nil) {
        let to = try arguments.date("to", default: nil) ?? Date()
        guard to > from else { throw CLIError.usage("--to moet na --from liggen") }
        return DateRange(start: from, end: to)
    }
    let period = resolvePeriod(arguments, positionalIndex: 1) ?? defaultPeriod
    let anchor = try arguments.date("date", default: Date()) ?? Date()
    return Reporting.range(period, containing: anchor)
}

// MARK: - Rapport

func runReport(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    let period = resolvePeriod(arguments, positionalIndex: 1) ?? .day
    let anchor = try arguments.date("date", default: Date()) ?? Date()
    let profile = arguments.string("profile") != nil ? try resolveProfile(arguments, tracker.store) : nil
    let report = try Reporting.report(store: tracker.store, period: period, containing: anchor, profileId: profile?.id)

    let end = Formatting.calendar.date(byAdding: .second, value: -1, to: report.range.end) ?? report.range.end
    print("\(period.label): \(Formatting.day(report.range.start)) t/m \(Formatting.day(end))\(profile.map { " — \($0.name)" } ?? "")")
    if report.breakDeduction > 0 {
        print("gewerkt: \(Formatting.duration(report.total))  (\(Formatting.decimalHours(report.total)) uur)")
        print("pauze:  -\(Formatting.duration(report.breakDeduction))")
        print("totaal: \(Formatting.duration(report.netTotal))  (\(Formatting.decimalHours(report.netTotal)) uur)")
    } else {
        print("totaal: \(Formatting.duration(report.total))  (\(Formatting.decimalHours(report.total)) uur)")
    }
    if !report.byProject.isEmpty {
        print("per project:")
        for item in report.byProject {
            print("  \(Formatting.duration(item.total).padding(toLength: 7, withPad: " ", startingAt: 0)) \(item.label)")
        }
    }
    if report.breakDeduction > 0 {
        print("(pauze hangt aan een dag, niet aan een project; de projectregels hierboven zijn bruto)")
    }
    if period != .day, !report.byDay.isEmpty {
        print("per dag:")
        for item in report.byDay {
            var line = "  \(Formatting.day(item.day))  \(Formatting.duration(item.net))"
            if item.breakDeduction > 0 {
                line += "  (gewerkt \(Formatting.duration(item.total)), pauze -\(Formatting.duration(item.breakDeduction)))"
            }
            print(line)
        }
    }
    if report.runningCount > 0 { print("let op: \(report.runningCount) lopend blok meegeteld tot nu") }
    if report.openCount > 0 { print("let op: \(report.openCount) blok(ken) met status 'open' — corrigeer met wifihours entry edit") }
}

// MARK: - Export

func runExport(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    let window = try resolveWindow(arguments, defaultPeriod: .month)
    let profile = arguments.string("profile") != nil ? try resolveProfile(arguments, tracker.store) : nil
    let csv = try CSVExport.export(
        store: tracker.store,
        from: window.start,
        to: window.end,
        profileId: profile?.id,
        includeBreaks: !arguments.flag("bruto")
    )
    if let path = arguments.string("out") {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try csv.write(to: url, atomically: true, encoding: .utf8)
        print("geëxporteerd naar \(url.path)")
    } else {
        print(csv, terminator: "")
    }
}

// MARK: - Instellingen

func runConfig(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    switch arguments.word(1) ?? "list" {
    case "list":
        let settings = try tracker.store.settings()
        print("stop-grace-seconds    \(settings.stopGraceSeconds)   wachttijd voor een stop definitief wordt")
        print("dedupe-window-seconds \(settings.dedupeWindowSeconds)   venster waarin herhaalde events genegeerd worden")
        print("max-entry-seconds     \(settings.maxEntrySeconds)   daarna wordt een lopend blok 'open'")
    case "set":
        guard let key = arguments.word(2), let raw = arguments.word(3), let value = Int(raw) else {
            throw CLIError.usage("gebruik: wifihours config set <sleutel> <waarde>")
        }
        guard value >= 0 else { throw CLIError.usage("waarde mag niet negatief zijn") }
        try tracker.store.setSetting(key: key, value: value)
        print("\(key) = \(value)")
    default:
        throw CLIError.usage("gebruik: wifihours config list|set")
    }
}

// MARK: - Entree

do {
    try run()
} catch let error as CLIError {
    FileHandle.standardError.write(Data("fout: \(error.description)\n".utf8))
    exit(error.isUsage ? 2 : 1)
} catch {
    FileHandle.standardError.write(Data("fout: \(error)\n".utf8))
    exit(1)
}

extension CLIError {
    var isUsage: Bool {
        if case .usage = self { return true }
        return false
    }
}
