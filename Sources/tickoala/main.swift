import Foundation
import TickoalaCore

let usage = """
tickoala — local time tracking, fed by ControlPlane

ControlPlane adapter (dumb, idempotent):
  tickoala start --context <name> [--at <time>]
  tickoala stop  --context <name> [--at <time>]

Status and maintenance:
  tickoala status [--json]
  tickoala tick                       finalize stops, flag stuck blocks
  tickoala events [--limit 20]
  tickoala db                         path to the database

Profiles (a profile can be linked to multiple Wi-Fi networks):
  tickoala profile list
  tickoala profile add --name <name> --context <ssid>[,ssid2,...] [--rate 87.50] [--currency eur|usd]
  tickoala profile edit --profile <name|context> [--name x] [--active true|false] [--rate 87.50] [--currency eur|usd]
  tickoala profile context list   --profile <name|context>
  tickoala profile context add    --profile <name|context> --context <ssid>[,ssid2,...]
  tickoala profile context remove --profile <name|context> --context <ssid>[,ssid2,...]

Hourly rate (per customer):
  tickoala rate list
  tickoala rate set --profile <name> --rate 87.50 [--currency eur|usd]

Projects:
  tickoala project list [--profile <name>]
  tickoala project add --profile <name> --number <number> --name <project name>
  tickoala project select --profile <name> --number <number>
  tickoala project edit --profile <name> --number <number> [--new-number y] [--name x] [--active true|false]

Automatic break deduction (per customer):
  tickoala break list
  tickoala break set --profile <name> [--enabled true|false] [--minutes 30] [--threshold 6:00]
                                       --threshold accepts 6:00, 6h or 360 (minutes)

Timer:
  tickoala timer start|stop --profile <name>
  tickoala pause  --profile <name>
  tickoala resume --profile <name>

Correcting blocks:
  tickoala entry list [--period day|week|month] [--date <day>] [--from <time> --to <time>] [--profile <name>]
  tickoala entry add --profile <name> --number <project number> --start <time> --end <time> [--note "..."]
  tickoala entry edit --id <n> [--start <time>] [--end <time>] [--number <project number>] [--status completed|open] [--note "..."]
  tickoala entry delete --id <n>

Overview and export:
  tickoala report [day|week|month] [--date <day>] [--profile <name>]
  tickoala export [--period month] [--date <day>] [--from <time> --to <time>] [--profile <name>] [--out <file>]

Settings:
  tickoala config list
  tickoala config set <key> <value>
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
        throw CLIError.failure("no profile created yet — use: tickoala profile add --name ... --context ...")
    }
    throw CLIError.usage("multiple profiles; specify --profile <name> (\(profiles.map(\.name).joined(separator: ", ")))")
}

func resolvePeriod(_ arguments: Arguments, positionalIndex: Int) -> ReportPeriod? {
    if let raw = arguments.string("period") ?? arguments.word(positionalIndex) {
        return ReportPeriod(rawValue: raw.lowercased())
    }
    return nil
}

func boolOption(_ arguments: Arguments, _ name: String) -> Bool? {
    guard let raw = arguments.string(name)?.lowercased() else { return nil }
    if ["true", "yes", "1", "on"].contains(raw) { return true }
    if ["false", "no", "0", "off"].contains(raw) { return false }
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
        if events.isEmpty { print("no events yet"); return }
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
            print(closed.map { "paused — block \($0.id) closed (\(Formatting.duration($0.duration())))" } ?? "paused — no timer was running")
        } else {
            let entry = try tracker.resume(profileId: profile.id)
            print("resumed — new block \(entry.id) at \(Formatting.clock(entry.startedAt))")
        }

    case "break":
        try runBreak(arguments)

    case "rate":
        try runRate(arguments)

    case "entry":
        try runEntry(arguments)

    case "report":
        try runReport(arguments)

    case "export":
        try runExport(arguments)

    case "config":
        try runConfig(arguments)

    default:
        throw CLIError.usage("unknown command: \(command)\n\n\(usage)")
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
                "\"profile\":\"\(jsonEscape(item.profile.name))\"",
                "\"contexts\":\(jsonArray(item.profile.contexts))",
                "\"mode\":\"\(item.mode.rawValue)\"",
                "\"project\":\(item.project.map { "\"\(jsonEscape($0.label))\"" } ?? "null")",
                "\"block_seconds\":\(Int(item.elapsedCurrent))",
                "\"today_seconds\":\(Int(item.todayTotal))",
                "\"week_seconds\":\(Int(item.weekTotal))",
                "\"attention\":\(item.attention.map { "\"\(jsonEscape($0))\"" } ?? "null")",
            ]
            profiles.append("{\(fields.joined(separator: ","))}")
        }
        print("{\"mode\":\"\(status.mode.rawValue)\",\"title\":\"\(jsonEscape(status.menuBarTitle))\",\"open_blocks\":\(status.openEntryCount),\"profiles\":[\(profiles.joined(separator: ","))]}")
        return
    }

    if status.profiles.isEmpty {
        print("no profile created yet — use: tickoala profile add --name ... --context ...")
        return
    }
    print("\(status.mode.label)  \(status.menuBarTitle)")
    for item in status.profiles {
        var line = "  \(item.profile.name) [\(item.profile.contextsLabel)] — \(item.mode.label)"
        line += "  project: \(item.project?.label ?? "none")"
        if let running = item.runningEntry {
            line += "  running since \(Formatting.clock(running.startedAt)) (\(Formatting.duration(item.elapsedCurrent)))"
        }
        if let pending = item.pendingStopAt {
            line += "  stop scheduled from \(Formatting.clock(pending))"
        }
        line += "  today \(Formatting.duration(item.todayTotal))  week \(Formatting.duration(item.weekTotal))"
        if item.todayBreak > 0 || item.weekBreak > 0 {
            line += "  (net; break today -\(Formatting.duration(item.todayBreak)), week -\(Formatting.duration(item.weekBreak)))"
        }
        print(line)
        if let attention = item.attention { print("    ! \(attention)") }
    }
    if status.openEntryCount > 0 {
        print("  \(status.openEntryCount) block(s) with status 'open' awaiting correction (tickoala entry list --period week)")
    }
}

func jsonEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

func jsonArray(_ values: [String]) -> String {
    "[" + values.map { "\"\(jsonEscape($0))\"" }.joined(separator: ",") + "]"
}

/// Splits a --context option on commas into separate, cleaned Wi-Fi names and
/// filters out empty or duplicate values.
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

// MARK: - Profiles

func runProfile(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    switch arguments.word(1) ?? "list" {
    case "list":
        let profiles = try tracker.store.profiles()
        if profiles.isEmpty { print("no profiles yet"); return }
        for profile in profiles {
            let state = try tracker.store.state(profileId: profile.id)
            let project = try state.activeProjectId.flatMap { try tracker.store.project(id: $0) }
            let rate = profile.hasHourlyRate ? "  hourly rate: \(Formatting.money(cents: profile.hourlyRateCents, currency: profile.currency))" : ""
            print("\(profile.id)  \(profile.name)  contexts: \(profile.contextsLabel)  active project: \(project?.label ?? "none")\(rate)\(profile.active ? "" : "  [inactive]")")
        }
    case "add":
        let contexts = contextsList(try arguments.require("context"))
        let rate = try optionalRateCents(arguments)
        let currency = try optionalCurrency(arguments) ?? .eur
        let profile = try tracker.store.createProfile(name: try arguments.require("name"), contexts: contexts, hourlyRateCents: rate ?? 0, currency: currency)
        print("profile \(profile.id) created: \(profile.name) → \(profile.contextsLabel)")
    case "edit":
        let profile = try resolveProfile(arguments, tracker.store)
        try tracker.store.updateProfile(
            id: profile.id,
            name: arguments.string("name"),
            active: boolOption(arguments, "active"),
            hourlyRateCents: try optionalRateCents(arguments),
            currency: try optionalCurrency(arguments)
        )
        print("profile \(profile.id) updated")
    case "context":
        try runProfileContext(arguments, tracker)
    default:
        throw CLIError.usage("usage: tickoala profile list|add|edit|context")
    }
}

func runProfileContext(_ arguments: Arguments, _ tracker: Tracker) throws {
    let profile = try resolveProfile(arguments, tracker.store)
    switch arguments.word(2) ?? "list" {
    case "list":
        let contexts = try tracker.store.contexts(profileId: profile.id)
        if contexts.isEmpty { print("(no Wi-Fi contexts linked)"); return }
        for context in contexts { print(context) }
    case "add":
        var updated = profile
        for context in contextsList(try arguments.require("context")) {
            updated = try tracker.store.addContext(profileId: profile.id, context: context)
        }
        print("Wi-Fi contexts of \(profile.name): \(updated.contextsLabel)")
    case "remove":
        var updated = profile
        for context in contextsList(try arguments.require("context")) {
            updated = try tracker.store.removeContext(profileId: profile.id, context: context)
        }
        print("Wi-Fi contexts of \(profile.name): \(updated.contextsLabel)")
    default:
        throw CLIError.usage("usage: tickoala profile context list|add|remove --profile <name> --context <ssid>[,ssid2,...]")
    }
}

// MARK: - Projects

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
            if projects.isEmpty { print("  (no projects)") }
            for project in projects {
                let marker = state.activeProjectId == project.id ? "→" : " "
                print("  \(marker) \(project.label)\(project.active ? "" : "  [inactive]")")
            }
        }
    case "add":
        let profile = try resolveProfile(arguments, tracker.store)
        let project = try tracker.createProject(
            profileId: profile.id,
            number: try arguments.require("number"),
            name: try arguments.require("name")
        )
        var message = "project added to \(profile.name): \(project.label)"
        if try tracker.store.state(profileId: profile.id).activeProjectId == project.id {
            message += " (set as the active project immediately)"
        }
        print(message)
    case "select":
        let profile = try resolveProfile(arguments, tracker.store)
        let number = try arguments.require("number")
        guard let project = try tracker.store.project(profileId: profile.id, number: number) else {
            throw TrackerError.unknownProject(number)
        }
        let entry = try tracker.selectProject(profileId: profile.id, projectId: project.id)
        var message = "active project for \(profile.name): \(project.label)"
        if let entry, entry.projectId == project.id, entry.status == .running {
            message += " (block \(entry.id) keeps running on this project)"
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
            print("project updated: \(updated.label)\(updated.active ? "" : "  [inactive]")")
        }
    default:
        throw CLIError.usage("usage: tickoala project list|add|select|edit")
    }
}

// MARK: - Break deduction

/// Reads a threshold as `6:00`, `6h`, `6` (hours) or `360m` (minutes).
func parseMinutes(_ raw: String) throws -> Int {
    let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
    if text.contains(":") {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]), minutes < 60 else {
            throw CLIError.usage("cannot read time: '\(raw)' (for example 6:00)")
        }
        return hours * 60 + minutes
    }
    if text.hasSuffix("m"), let minutes = Int(text.dropLast()) { return minutes }
    if text.hasSuffix("h"), let hours = Int(text.dropLast()) { return hours * 60 }
    guard let value = Int(text) else {
        throw CLIError.usage("cannot read time: '\(raw)' (use 6:00, 6h or 360)")
    }
    // Bare number: small values are almost certainly hours, large ones are minutes.
    return value <= 24 ? value * 60 : value
}

func runBreak(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    switch arguments.word(1) ?? "list" {
    case "list":
        let profiles = try tracker.store.profiles()
        if profiles.isEmpty { print("no profiles yet"); return }
        for profile in profiles {
            print("\(profile.name): \(profile.breakRule.summary)")
        }
    case "set":
        let profile = try resolveProfile(arguments, tracker.store)
        var rule = profile.breakRule
        if let enabled = boolOption(arguments, "enabled") { rule.enabled = enabled }
        if let minutes = arguments.string("minutes") {
            rule.minutes = try parseMinutes(minutes.allSatisfy(\.isNumber) ? "\(minutes)m" : minutes)
            // Setting a break duration almost always means: turn it on too.
            if boolOption(arguments, "enabled") == nil { rule.enabled = rule.minutes > 0 }
        }
        if let threshold = arguments.string("threshold") {
            rule.thresholdMinutes = try parseMinutes(threshold)
        }
        try tracker.store.updateBreakRule(profileId: profile.id, rule: rule)
        print("\(profile.name): \(rule.summary)")
    default:
        throw CLIError.usage("usage: tickoala break list|set")
    }
}

// MARK: - Hourly rate

/// Reads the optional `--rate` as cents; `nil` if the option is absent.
func optionalRateCents(_ arguments: Arguments) throws -> Int? {
    guard let raw = arguments.string("rate") else { return nil }
    guard let cents = Formatting.parseMoneyCents(raw) else {
        throw CLIError.usage("cannot read the hourly rate: '\(raw)' (for example 87.50)")
    }
    return cents
}

/// Reads the optional `--currency` as a currency; `nil` if the option is absent.
func optionalCurrency(_ arguments: Arguments) throws -> Currency? {
    guard let raw = arguments.string("currency")?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
    switch raw {
    case "eur", "euro", "€": return .eur
    case "usd", "dollar", "$": return .usd
    default: throw CLIError.usage("unknown currency: '\(raw)' (use eur or usd)")
    }
}

func runRate(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    switch arguments.word(1) ?? "list" {
    case "list":
        let profiles = try tracker.store.profiles()
        if profiles.isEmpty { print("no profiles yet"); return }
        for profile in profiles {
            let text = profile.hasHourlyRate
                ? "\(Formatting.money(cents: profile.hourlyRateCents, currency: profile.currency)) per hour"
                : "no hourly rate"
            print("\(profile.name): \(text)")
        }
    case "set":
        let profile = try resolveProfile(arguments, tracker.store)
        guard let raw = arguments.string("rate") else {
            throw CLIError.usage("usage: tickoala rate set --profile <name> --rate 87.50 [--currency eur|usd]")
        }
        guard let cents = Formatting.parseMoneyCents(raw) else {
            throw CLIError.usage("cannot read the hourly rate: '\(raw)'")
        }
        let currency = try optionalCurrency(arguments)
        try tracker.store.updateProfile(id: profile.id, hourlyRateCents: cents, currency: currency)
        let shown = currency ?? profile.currency
        print("\(profile.name): \(Formatting.money(cents: cents, currency: shown)) per hour")
    default:
        throw CLIError.usage("usage: tickoala rate list|set")
    }
}

// MARK: - Timer

func runTimer(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    let profile = try resolveProfile(arguments, tracker.store)
    switch arguments.word(1) ?? "" {
    case "start":
        let entry = try tracker.start(profileId: profile.id)
        print("block \(entry.id) running since \(Formatting.clock(entry.startedAt))")
    case "stop":
        let entry = try tracker.stop(profileId: profile.id)
        print(entry.map { "block \($0.id) stopped — \(Formatting.duration($0.duration()))" } ?? "no timer was running")
    default:
        throw CLIError.usage("usage: tickoala timer start|stop --profile <name>")
    }
}

// MARK: - Blocks

func runEntry(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    switch arguments.word(1) ?? "list" {
    case "list":
        let profileId = arguments.string("profile") != nil ? try resolveProfile(arguments, tracker.store).id : nil
        let window = try resolveWindow(arguments, defaultPeriod: .day)
        let entries = try tracker.store.entries(from: window.start, to: window.end, profileId: profileId)
        if entries.isEmpty { print("no blocks between \(Formatting.timestamp(window.start)) and \(Formatting.timestamp(window.end))"); return }
        for entry in entries {
            let project = try entry.projectId.flatMap { try tracker.store.project(id: $0) }
            let profile = try tracker.store.profile(id: entry.profileId)
            let end = entry.endedAt.map(Formatting.clock) ?? "…"
            print("\(entry.id)  \(Formatting.day(entry.startedAt))  \(Formatting.clock(entry.startedAt))–\(end)  \(Formatting.duration(entry.duration()))  \(profile?.name ?? "?")  \(project?.label ?? "(no project)")  \(entry.status.rawValue)  \(entry.source.rawValue)\(entry.note.map { "  \"\($0)\"" } ?? "")")
        }
    case "add":
        let profile = try resolveProfile(arguments, tracker.store)
        let start = try arguments.requireDate("start")
        let end = try arguments.requireDate("end")
        guard end > start else { throw CLIError.usage("--end must be after --start") }
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
        print("block \(entry.id) added: \(Formatting.timestamp(start)) – \(Formatting.clock(end)) (\(Formatting.duration(entry.duration())))")
    case "edit":
        guard let id = arguments.int("id").map(Int64.init) else { throw CLIError.usage("missing option --id") }
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
            guard let parsed = EntryStatus(rawValue: raw) else { throw CLIError.usage("status must be running, completed or open") }
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
            throw CLIError.usage("the end is before the start")
        }
        // A block with an end is no longer 'running'.
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
            print("block \(id) updated: \(Formatting.timestamp(updated.startedAt)) – \(updated.endedAt.map(Formatting.clock) ?? "…") (\(Formatting.duration(updated.duration())), \(updated.status.rawValue))")
        }
    case "delete":
        guard let id = arguments.int("id").map(Int64.init) else { throw CLIError.usage("missing option --id") }
        try tracker.store.deleteEntry(id: id)
        print("block \(id) deleted")
    default:
        throw CLIError.usage("usage: tickoala entry list|add|edit|delete")
    }
}

/// Determines the window from --from/--to or from --period/--date.
func resolveWindow(_ arguments: Arguments, defaultPeriod: ReportPeriod) throws -> DateRange {
    if let from = try arguments.date("from", default: nil) {
        let to = try arguments.date("to", default: nil) ?? Date()
        guard to > from else { throw CLIError.usage("--to must be after --from") }
        return DateRange(start: from, end: to)
    }
    let period = resolvePeriod(arguments, positionalIndex: 1) ?? defaultPeriod
    let anchor = try arguments.date("date", default: Date()) ?? Date()
    return Reporting.range(period, containing: anchor)
}

// MARK: - Report

func runReport(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    let period = resolvePeriod(arguments, positionalIndex: 1) ?? .day
    let anchor = try arguments.date("date", default: Date()) ?? Date()
    let profile = arguments.string("profile") != nil ? try resolveProfile(arguments, tracker.store) : nil
    let report = try Reporting.report(store: tracker.store, period: period, containing: anchor, profileId: profile?.id)

    let end = Formatting.calendar.date(byAdding: .second, value: -1, to: report.range.end) ?? report.range.end
    print("\(period.label): \(Formatting.day(report.range.start)) to \(Formatting.day(end))\(profile.map { " — \($0.name)" } ?? "")")
    if report.breakDeduction > 0 {
        print("worked: \(Formatting.duration(report.total))  (\(Formatting.decimalHours(report.total)) hours)")
        print("break:  -\(Formatting.duration(report.breakDeduction))")
        print("total:  \(Formatting.duration(report.netTotal))  (\(Formatting.decimalHours(report.netTotal)) hours)")
    } else {
        print("total: \(Formatting.duration(report.total))  (\(Formatting.decimalHours(report.total)) hours)")
    }
    if report.amountCents > 0 {
        let currencies = Set(report.byProfile.map(\.currency))
        let currency = currencies.count == 1 ? (currencies.first ?? .eur) : (profile?.currency ?? .eur)
        print("amount: \(Formatting.money(cents: report.amountCents, currency: currency))")
        let withRate = report.byProfile.filter { $0.hasHourlyRate }
        if profile == nil, withRate.count > 1 {
            for item in withRate {
                print("  \(item.label): \(Formatting.money(cents: item.amountCents, currency: item.currency))")
            }
        }
    }
    if !report.byProject.isEmpty {
        print("per project:")
        for item in report.byProject {
            print("  \(Formatting.duration(item.total).padding(toLength: 7, withPad: " ", startingAt: 0)) \(item.label)")
        }
    }
    if report.breakDeduction > 0 {
        print("(break belongs to a day, not to a project; the project rows above are gross)")
    }
    if period != .day, !report.byDay.isEmpty {
        print("per day:")
        for item in report.byDay {
            var line = "  \(Formatting.day(item.day))  \(Formatting.duration(item.net))"
            if item.breakDeduction > 0 {
                line += "  (worked \(Formatting.duration(item.total)), break -\(Formatting.duration(item.breakDeduction)))"
            }
            print(line)
        }
    }
    if report.runningCount > 0 { print("note: \(report.runningCount) running block counted up to now") }
    if report.openCount > 0 { print("note: \(report.openCount) block(s) with status 'open' — correct with tickoala entry edit") }
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
        includeBreaks: !arguments.flag("gross")
    )
    if let path = arguments.string("out") {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try csv.write(to: url, atomically: true, encoding: .utf8)
        print("exported to \(url.path)")
    } else {
        print(csv, terminator: "")
    }
}

// MARK: - Settings

func runConfig(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    switch arguments.word(1) ?? "list" {
    case "list":
        let settings = try tracker.store.settings()
        print("stop-grace-seconds    \(settings.stopGraceSeconds)   grace period before a stop becomes final")
        print("dedupe-window-seconds \(settings.dedupeWindowSeconds)   window in which repeated events are ignored")
        print("max-entry-seconds     \(settings.maxEntrySeconds)   after this a running block becomes 'open'")
    case "set":
        guard let key = arguments.word(2), let raw = arguments.word(3), let value = Int(raw) else {
            throw CLIError.usage("usage: tickoala config set <key> <value>")
        }
        guard value >= 0 else { throw CLIError.usage("value must not be negative") }
        try tracker.store.setSetting(key: key, value: value)
        print("\(key) = \(value)")
    default:
        throw CLIError.usage("usage: tickoala config list|set")
    }
}

// MARK: - Entry point

do {
    try run()
} catch let error as CLIError {
    FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
    exit(error.isUsage ? 2 : 1)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

extension CLIError {
    var isUsage: Bool {
        if case .usage = self { return true }
        return false
    }
}
