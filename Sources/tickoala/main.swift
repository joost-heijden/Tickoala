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
  tickoala profile edit --profile <name|context> [--name x] [--active true|false] [--rate 87.50] [--currency eur|usd] [--km-rate 0.23] [--travel-rate 0.00] [--commute-rate 0.00]
  tickoala profile context list   --profile <name|context>
  tickoala profile context add    --profile <name|context> --context <ssid>[,ssid2,...]
  tickoala profile context remove --profile <name|context> --context <ssid>[,ssid2,...]

Hourly rate (per customer):
  tickoala rate list
  tickoala rate set --profile <name> --rate 87.50 [--currency eur|usd]

Projects (an optional hour budget adds a burn-down and warns at 80% and 100%):
  tickoala project list [--profile <name>]
  tickoala project add --profile <name> --number <number> --name <project name> [--budget 80]
  tickoala project select --profile <name> --number <number>
  tickoala project edit --profile <name> --number <number> [--new-number y] [--name x] [--active true|false] [--budget 80]
                                  --budget accepts 80, 80.5 or 1:30 in hours; 0 clears it

Location (per customer, for detection by place instead of network):
  tickoala location set   --profile <name> --lat <n> --lon <n> [--radius <meters>]
  tickoala location clear --profile <name>
  tickoala location list

Expenses and mileage (per customer, added to the invoice):
  tickoala expense list [--profile <name>] [--period day|week|month] [--date <day>] [--from <t> --to <t>]
  tickoala expense add  --profile <name> --description "Parking" --amount 12.50 [--date <day>] [--non-billable]
  tickoala expense add  --profile <name> --description "Travel"  --km 120 --rate 0.23 [--date <day>] [--non-billable]
  tickoala expense edit --id <n> [--description x] [--date <day>] [--amount 12.50 | --km 120 --rate 0.23] [--billable true|false]
  tickoala expense delete --id <n>

Holidays and vacation (non-working days, global):
  tickoala holiday list [--from <day> --to <day>]
  tickoala holiday add <day> [--label "Christmas"] [--kind holiday|vacation]
  tickoala holiday remove <day>

Billing rules (per customer, applied when the invoice is built):
  tickoala billing list
  tickoala billing set --profile <name> [--round 15] [--round-up true|false] [--minimum 1:00] [--evening 25] [--weekend 50] [--evening-start 18:00]
  tickoala billing clear --profile <name>

Retainer (fixed monthly amount per customer, added to the invoice, optionally
for a fixed term and billed on its own for a support contract):
  tickoala retainer render-invoices [--month YYYY-MM] [--profile <name>] [--out <dir>]

Retainer (fixed monthly amount per customer, added to the invoice):
  tickoala retainer list
  tickoala retainer set --profile <name> --amount 1500 [--description "Support contract"] [--active true|false]
  tickoala retainer clear --profile <name>

Automatic break deduction (per customer):
  tickoala break list
  tickoala break set --profile <name> [--enabled true|false] [--minutes 30] [--threshold 6:00]
                                       --threshold accepts 6:00, 6h or 360 (minutes)

Timer:
  tickoala timer start|stop --profile <name> [--kind work|travel|commute]
  tickoala pause  --profile <name>
  tickoala resume --profile <name>

Correcting blocks:
  tickoala entry list [--period day|week|month] [--date <day>] [--from <time> --to <time>] [--profile <name>]
  tickoala entry add --profile <name> --number <project number> --start <time> --end <time> [--kind work|travel|commute] [--note "..."] [--tag "a,b"]
  tickoala entry edit --id <n> [--start <time>] [--end <time>] [--number <project number>] [--status completed|open] [--kind work|travel|commute] [--note "..."] [--tag "a,b"]
  tickoala entry delete --id <n>

VAT return (quarterly, per rate):
  tickoala vat [--year 2026] [--quarter 1|2|3|4]

Overview and export:
  tickoala report [day|week|month] [--date <day>] [--profile <name>]
  tickoala export [--period month] [--date <day>] [--from <time> --to <time>] [--profile <name>] [--out <file>]
  tickoala invoice [--profile <name>] [--month YYYY-MM] [--po <number>] [--out <file.pdf>] [--ubl <file.xml>]

Credit note (reverses an issued invoice, with its own number):
  tickoala credit --number <invoice number> [--out <file.pdf>] [--ubl <file.xml>]

Payments:
  tickoala invoices [--unpaid] [--overdue] [--json]
  tickoala paid --number <invoice number>
  tickoala unpaid --number <invoice number>

Import from another tracker (Toggl Track, Harvest or Clockify CSV export):
  tickoala import --from toggl|harvest|clockify --file <export.csv> [--profile <name>] [--user <name>] [--dry-run]

Settings:
  tickoala config list
  tickoala config set <key> <value>

Backup and restore (the whole database, one file):
  tickoala backup [--out <file>]
  tickoala restore --from <file> [--yes]
  tickoala restore --peek <file>
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

func kindOption(_ arguments: Arguments) throws -> EntryKind? {
    guard let raw = arguments.string("kind")?.lowercased() else { return nil }
    guard let kind = EntryKind(rawValue: raw) else {
        throw CLIError.usage("--kind must be work, travel or commute")
    }
    return kind
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

    case "location":
        try runLocation(arguments)

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

    case "expense":
        try runExpense(arguments)

    case "rate":
        try runRate(arguments)

    case "billing":
        try runBilling(arguments)

    case "retainer":
        try runRetainer(arguments)

    case "holiday", "vacation":
        try runHoliday(arguments)

    case "entry":
        try runEntry(arguments)

    case "vat":
        try runVAT(arguments)

    case "report":
        try runReport(arguments)

    case "export":
        try runExport(arguments)

    case "invoice":
        try runInvoice(arguments)

    case "credit":
        try runCredit(arguments)

    case "invoices":
        try runInvoices(arguments)

    case "paid", "unpaid":
        try runSetPaid(arguments, paid: command == "paid")

    case "import":
        try runImport(arguments)

    case "backup":
        try runBackup(arguments)

    case "restore":
        try runRestore(arguments)

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
                "\"contexts\":\(jsonArray(item.profile.wifiContexts))",
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
            line += "  no signal since \(Formatting.clock(pending)), block keeps running"
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
            currency: try optionalCurrency(arguments),
            kmRateCents: try optionalMoney(arguments, "km-rate"),
            travelRateCents: try optionalMoney(arguments, "travel-rate"),
            commuteRateCents: try optionalMoney(arguments, "commute-rate")
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
        let usage = try tracker.store.projectUsageSeconds()
        for profile in profiles {
            let state = try tracker.store.state(profileId: profile.id)
            print("\(profile.name):")
            let projects = try tracker.store.projects(profileId: profile.id)
            if projects.isEmpty { print("  (no projects)") }
            for project in projects {
                let marker = state.activeProjectId == project.id ? "→" : " "
                var line = "  \(marker) \(project.label)\(project.active ? "" : "  [inactive]")"
                if project.hasBudget {
                    let budget = ProjectBudget(
                        budgetSeconds: project.budgetSeconds,
                        usedSeconds: usage[project.id] ?? 0
                    )
                    line += "  —  \(budget.summary)"
                }
                print(line)
            }
        }
    case "add":
        let profile = try resolveProfile(arguments, tracker.store)
        let project = try tracker.createProject(
            profileId: profile.id,
            number: try arguments.require("number"),
            name: try arguments.require("name"),
            budgetMinutes: try optionalBudgetMinutes(arguments) ?? 0
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
            active: boolOption(arguments, "active"),
            budgetMinutes: try optionalBudgetMinutes(arguments)
        )
        if let updated = try tracker.store.project(id: project.id) {
            var line = "project updated: \(updated.label)\(updated.active ? "" : "  [inactive]")"
            if arguments.string("budget") != nil {
                line += updated.hasBudget
                    ? "  budget \(Formatting.decimalHours(updated.budgetSeconds)) h"
                    : "  budget cleared"
            }
            print(line)
        }
    default:
        throw CLIError.usage("usage: tickoala project list|add|select|edit")
    }
}

// MARK: - Location

/// Stores or clears a customer's coordinates for detection by place. The same
/// hidden context the app uses is linked, so both share one database.
func runLocation(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    switch arguments.word(1) ?? "list" {
    case "list":
        let profiles = try tracker.store.profiles()
        for profile in profiles where profile.hasLocation {
            let latitude = profile.latitude ?? 0
            let longitude = profile.longitude ?? 0
            print("\(profile.name): \(String(format: "%.5f, %.5f", latitude, longitude))  radius \(profile.presenceRadiusMeters) m")
        }
        if !profiles.contains(where: { $0.hasLocation }) { print("no customer has a location yet") }
    case "set":
        let profile = try resolveProfile(arguments, tracker.store)
        guard let rawLatitude = arguments.string("lat"), let latitude = Double(rawLatitude) else {
            throw CLIError.usage("missing or unreadable option --lat")
        }
        guard let rawLongitude = arguments.string("lon"), let longitude = Double(rawLongitude) else {
            throw CLIError.usage("missing or unreadable option --lon")
        }
        let radius = arguments.int("radius") ?? 150
        try tracker.store.updateProfileLocation(
            id: profile.id, latitude: latitude, longitude: longitude, radiusMeters: radius
        )
        print("location set for \(profile.name): \(String(format: "%.5f, %.5f", latitude, longitude))  radius \(max(20, radius)) m")
    case "clear":
        let profile = try resolveProfile(arguments, tracker.store)
        try tracker.store.updateProfileLocation(id: profile.id, latitude: nil, longitude: nil, radiusMeters: 150)
        print("location cleared for \(profile.name)")
    default:
        throw CLIError.usage("usage: tickoala location list|set|clear")
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

// MARK: - Expenses and mileage

/// Reads an optional option as an amount in cents; `nil` when absent.
func optionalMoney(_ arguments: Arguments, _ name: String) throws -> Int? {
    guard let raw = arguments.string(name) else { return nil }
    guard let cents = Formatting.parseMoneyCents(raw) else {
        throw CLIError.usage("cannot read --\(name): '\(raw)' (for example 12.50)")
    }
    return cents
}

func runExpense(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    switch arguments.word(1) ?? "list" {
    case "list":
        let window = try resolveWindow(arguments, defaultPeriod: .month)
        let profiles: [Profile]
        if arguments.string("profile") != nil {
            profiles = [try resolveProfile(arguments, tracker.store)]
        } else {
            profiles = try tracker.store.profiles()
        }
        var shown = false
        for profile in profiles {
            let expenses = try tracker.store.expenses(profileId: profile.id, from: window.start, to: window.end)
            guard !expenses.isEmpty else { continue }
            shown = true
            print("\(profile.name):")
            for expense in expenses {
                let quantity = expense.kind == .mileage
                    ? "\(Formatting.quantity(expense.quantity)) km × \(Formatting.money(cents: expense.unitRateCents, currency: profile.currency))"
                    : "—"
                let flag = expense.billable ? "" : "  [not invoiced]"
                print("  \(expense.id)  \(Formatting.day(expense.date))  \(expense.description)  \(quantity)  \(Formatting.money(cents: expense.amountCents, currency: profile.currency))\(flag)")
            }
        }
        if !shown {
            print("no expenses between \(Formatting.timestamp(window.start)) and \(Formatting.timestamp(window.end))")
        }
    case "add":
        let profile = try resolveProfile(arguments, tracker.store)
        let description = try arguments.require("description")
        let date = try arguments.date("date", default: Date()) ?? Date()
        let billable = boolOption(arguments, "billable") ?? !arguments.flag("non-billable")
        if let kmRaw = arguments.string("km") {
            guard let kilometres = Double(kmRaw.replacingOccurrences(of: ",", with: ".")) else {
                throw CLIError.usage("cannot read --km: '\(kmRaw)'")
            }
            let rate = try optionalMoney(arguments, "rate") ?? profile.kmRateCents
            let amount = Expense.mileageAmountCents(kilometres: kilometres, rateCentsPerKm: rate)
            let expense = try tracker.store.createExpense(
                profileId: profile.id, date: date, description: description, kind: .mileage,
                quantity: kilometres, unitRateCents: rate, amountCents: amount,
                billable: billable, note: arguments.string("note")
            )
            print("mileage \(expense.id) added for \(profile.name): \(Formatting.quantity(kilometres)) km × \(Formatting.money(cents: rate, currency: profile.currency)) = \(Formatting.money(cents: amount, currency: profile.currency))")
        } else {
            let amount = try optionalMoney(arguments, "amount") ?? 0
            let expense = try tracker.store.createExpense(
                profileId: profile.id, date: date, description: description, kind: .expense,
                quantity: 1, unitRateCents: amount, amountCents: amount,
                billable: billable, note: arguments.string("note")
            )
            print("expense \(expense.id) added for \(profile.name): \(description)  \(Formatting.money(cents: amount, currency: profile.currency))")
        }
    case "edit":
        guard let id = arguments.int("id").map(Int64.init) else { throw CLIError.usage("missing option --id") }
        guard let existing = try tracker.store.expense(id: id) else { throw TrackerError.unknownEntry(id) }
        var kind = existing.kind
        var quantity = existing.quantity
        var unitRate = existing.unitRateCents
        var amount = existing.amountCents
        if let kmRaw = arguments.string("km") {
            guard let kilometres = Double(kmRaw.replacingOccurrences(of: ",", with: ".")) else {
                throw CLIError.usage("cannot read --km: '\(kmRaw)'")
            }
            kind = .mileage
            quantity = kilometres
        }
        if let rate = try optionalMoney(arguments, "rate") { unitRate = rate }
        if let newAmount = try optionalMoney(arguments, "amount") {
            kind = .expense
            quantity = 1
            unitRate = newAmount
            amount = newAmount
        }
        if kind == .mileage { amount = Expense.mileageAmountCents(kilometres: quantity, rateCentsPerKm: unitRate) }
        try tracker.store.updateExpense(
            id: id,
            date: try arguments.date("date", default: nil),
            description: arguments.string("description"),
            kind: kind,
            quantity: quantity,
            unitRateCents: unitRate,
            amountCents: amount,
            billable: boolOption(arguments, "billable") ?? (arguments.flag("non-billable") ? false : nil),
            note: arguments.string("note").map { Optional($0) }
        )
        if let updated = try tracker.store.expense(id: id) {
            let currency = (try tracker.store.profile(id: updated.profileId))?.currency ?? .eur
            print("expense \(updated.id) updated: \(updated.description)  \(Formatting.money(cents: updated.amountCents, currency: currency))")
        }
    case "delete":
        guard let id = arguments.int("id").map(Int64.init) else { throw CLIError.usage("missing option --id") }
        try tracker.store.deleteExpense(id: id)
        print("expense \(id) deleted")
    default:
        throw CLIError.usage("usage: tickoala expense list|add|edit|delete")
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

/// Reads the optional `--budget` as minutes; `nil` if the option is absent. Hours
/// are accepted as `80`, `80.5` or `1:30`.
func optionalBudgetMinutes(_ arguments: Arguments) throws -> Int? {
    guard let raw = arguments.string("budget") else { return nil }
    guard let minutes = Formatting.parseHoursMinutes(raw) else {
        throw CLIError.usage("cannot read the budget: '\(raw)' (for example 80, 80.5 or 1:30)")
    }
    return minutes
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
            var extras: [String] = []
            if profile.travelRateCents > 0 {
                extras.append("travel \(Formatting.money(cents: profile.travelRateCents, currency: profile.currency))/h")
            }
            if profile.commuteRateCents > 0 {
                extras.append("commute \(Formatting.money(cents: profile.commuteRateCents, currency: profile.currency))/h")
            }
            print("\(profile.name): \(text)\(extras.isEmpty ? "" : "  (" + extras.joined(separator: ", ") + ")")")
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

// MARK: - Holidays

func runHoliday(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    switch arguments.word(1) ?? "list" {
    case "list":
        let from = try arguments.date("from", default: nil)
        let to = try arguments.date("to", default: nil)
        let days = try tracker.store.nonWorkingDays(from: from, to: to)
        if days.isEmpty { print("no non-working days marked"); return }
        for day in days {
            print("\(Formatting.day(day.date))  \(day.kind.rawValue)  \(day.label)")
        }
    case "add", "set":
        guard let raw = arguments.word(2), let date = Formatting.parseDate(raw) else {
            throw CLIError.usage("usage: tickoala holiday add <day> [--label \"...\"] [--kind holiday|vacation]")
        }
        let kind = arguments.string("kind").flatMap(NonWorkingKind.init(rawValue:)) ?? .holiday
        try tracker.store.addNonWorkingDay(date, label: arguments.string("label") ?? "", kind: kind)
        print("\(Formatting.day(date)) marked as \(kind.rawValue)")
    case "remove", "delete":
        guard let raw = arguments.word(2), let date = Formatting.parseDate(raw) else {
            throw CLIError.usage("usage: tickoala holiday remove <day>")
        }
        try tracker.store.deleteNonWorkingDay(date)
        print("\(Formatting.day(date)) is a working day again")
    default:
        throw CLIError.usage("usage: tickoala holiday list|add|remove")
    }
}

// MARK: - Billing rules

func runBilling(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    switch arguments.word(1) ?? "list" {
    case "list":
        let profiles = try tracker.store.profiles()
        if profiles.isEmpty { print("no customers yet"); return }
        for profile in profiles {
            print("\(profile.name): \(profile.billingRules.summary)")
        }
    case "set":
        let profile = try resolveProfile(arguments, tracker.store)
        var rules = profile.billingRules
        if let round = arguments.int("round") { rules.roundingMinutes = max(0, round) }
        if let roundUp = boolOption(arguments, "round-up") { rules.roundUp = roundUp }
        if let raw = arguments.string("minimum") {
            guard let minutes = Formatting.parseHoursMinutes(raw) else {
                throw CLIError.usage("cannot read --minimum: '\(raw)' (use 1:00 or 60)")
            }
            rules.minimumMinutes = minutes
        }
        if let evening = arguments.int("evening") { rules.eveningSurchargePercent = max(0, evening) }
        if let weekend = arguments.int("weekend") { rules.weekendSurchargePercent = max(0, weekend) }
        if let raw = arguments.string("evening-start") {
            guard let minutes = Formatting.parseHoursMinutes(raw) else {
                throw CLIError.usage("cannot read --evening-start: '\(raw)' (use 18:00)")
            }
            rules.eveningStartMinutes = minutes
        }
        try tracker.store.updateBillingRules(profileId: profile.id, rules: rules)
        print("\(profile.name): \(rules.summary)")
    case "clear":
        let profile = try resolveProfile(arguments, tracker.store)
        try tracker.store.updateBillingRules(profileId: profile.id, rules: .default)
        print("\(profile.name): billing rules cleared")
    default:
        throw CLIError.usage("usage: tickoala billing list|set|clear")
    }
}

// MARK: - Retainer

func runRetainer(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    switch arguments.word(1) ?? "list" {
    case "list":
        let profiles = try tracker.store.profiles()
        let set = profiles.compactMap { profile -> (Profile, Retainer)? in
            guard let retainer = try? tracker.store.retainer(profileId: profile.id), retainer.isSet else { return nil }
            return (profile, retainer)
        }
        if set.isEmpty { print("no retainers set"); return }
        for (profile, retainer) in set {
            print("\(profile.name): \(Formatting.money(cents: retainer.amountCents, currency: profile.currency)) per month — \(retainer.label)")
        }
    case "set":
        let profile = try resolveProfile(arguments, tracker.store)
        guard let raw = arguments.string("amount"), let cents = Formatting.parseMoneyCents(raw) else {
            throw CLIError.usage("usage: tickoala retainer set --profile <name> --amount 1500 [--description \"...\"] [--ends YYYY-MM-DD] [--recurrence monthly|quarterly|yearly]")
        }
        let active = boolOption(arguments, "active") ?? true
        let endsAt = try arguments.date("ends", default: nil)
        var recurrence = RetainerRecurrence.monthly
        if let raw = arguments.string("recurrence") {
            guard let parsed = RetainerRecurrence(rawValue: raw.lowercased()) else {
                throw CLIError.usage("recurrence must be monthly, quarterly or yearly")
            }
            recurrence = parsed
        }
        try tracker.store.setRetainer(
            profileId: profile.id,
            description: arguments.string("description") ?? "Retainer",
            amountCents: cents,
            active: active,
            endsAt: endsAt,
            recurrence: recurrence
        )
        let endText = endsAt.map { " until \(Formatting.day($0))" } ?? ""
        print("\(profile.name): retainer \(Formatting.money(cents: cents, currency: profile.currency)) \(recurrence.label.lowercased())\(endText)\(active ? "" : " (inactive)")")
    case "clear":
        let profile = try resolveProfile(arguments, tracker.store)
        try tracker.store.clearRetainer(profileId: profile.id)
        print("\(profile.name): retainer cleared")
    case "render-invoices":
        try runRenderRetainers(arguments, tracker: tracker)
    default:
        throw CLIError.usage("usage: tickoala retainer list|set|clear|render-invoices")
    }
}

/// Writes a fixed-fee invoice (retainer only, no hours) for a period. Without
/// `--out` nothing is written and it reports what it would do, so a monthly cron
/// can pre-flight first. With `--profile` it does one client; without, every
/// client whose retainer covers the month.
func runRenderRetainers(_ arguments: Arguments, tracker: Tracker) throws {
    let period: DateRange
    if let month = arguments.string("month") {
        guard let anchor = Formatting.parseDate("\(month)-01") else {
            throw CLIError.usage("cannot read month: '\(month)' (use YYYY-MM)")
        }
        period = Reporting.range(.month, containing: anchor)
    } else {
        period = Invoicing.previousMonthRange(containing: Date())
    }

    let profiles: [Profile]
    if arguments.string("profile") != nil {
        profiles = [try resolveProfile(arguments, tracker.store)]
    } else {
        profiles = try Invoicing.fixedInvoiceCandidates(store: tracker.store, period: period)
    }
    guard !profiles.isEmpty else {
        print("no retainers to bill for \(Formatting.monthName(period.start))")
        return
    }
    let outDir = arguments.string("out").map { ($0 as NSString).expandingTildeInPath }
    for profile in profiles {
        guard let invoice = try Invoicing.fixedInvoice(
            store: tracker.store, profileId: profile.id, period: period
        ) else { continue }
        if let outDir {
            let safe = profile.name.replacingOccurrences(of: "/", with: "-")
            let url = URL(fileURLWithPath: outDir).appendingPathComponent("invoice-\(invoice.number)-\(safe).pdf")
            try InvoicePDF.data(for: invoice).write(to: url)
            print("\(profile.name): invoice \(invoice.number) — \(Formatting.money(cents: invoice.totalCents, currency: invoice.currency)) → \(url.path)")
        } else {
            print("\(profile.name): invoice \(invoice.number) — \(Formatting.money(cents: invoice.totalCents, currency: invoice.currency)) (not written; pass --out <dir> to save the PDF)")
        }
    }
}

// MARK: - Timer

func runTimer(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    let profile = try resolveProfile(arguments, tracker.store)
    switch arguments.word(1) ?? "" {
    case "start":
        let entry = try tracker.start(profileId: profile.id, kind: try kindOption(arguments) ?? .work)
        print("block \(entry.id) running since \(Formatting.clock(entry.startedAt)) (\(entry.kind.rawValue))")
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
            let kind = entry.kind == .work ? "" : "  [\(entry.kind.rawValue)]"
            let tags = entry.tags.isEmpty ? "" : "  [\(Tags.text(entry.tags))]"
            print("\(entry.id)  \(Formatting.day(entry.startedAt))  \(Formatting.clock(entry.startedAt))–\(end)  \(Formatting.duration(entry.duration()))  \(profile?.name ?? "?")  \(project?.label ?? "(no project)")  \(entry.status.rawValue)  \(entry.source.rawValue)\(kind)\(tags)\(entry.note.map { "  \"\($0)\"" } ?? "")")
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
            tags: Tags.parse(arguments.string("tag")),
            status: .completed, source: .manual, kind: try kindOption(arguments) ?? .work,
            note: arguments.string("note")
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
            tags: arguments.string("tag").map { Tags.parse($0) },
            status: status,
            kind: try kindOption(arguments),
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

// MARK: - VAT return

func runVAT(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    let now = try arguments.date("date", default: Date()) ?? Date()
    let base = VATPeriod.containing(now)
    let year = arguments.int("year") ?? base.year
    let quarter = arguments.int("quarter") ?? base.quarter
    guard (1...4).contains(quarter) else { throw CLIError.usage("--quarter must be 1, 2, 3 or 4") }

    let period = VATPeriod(year: year, quarter: quarter)
    let report = try VAT.report(store: tracker.store, period: period)
    let lastDay = period.end.addingTimeInterval(-86400)
    print("VAT return \(period.label)  (\(Formatting.day(period.start)) to \(Formatting.day(lastDay)))")
    if report.lines.isEmpty { print("  nothing to declare"); return }
    for line in report.lines {
        print("  \(String(format: "%3d%%", line.ratePercent))  turnover \(Formatting.money(cents: line.netCents).padding(toLength: 14, withPad: " ", startingAt: 0))  VAT \(Formatting.money(cents: line.vatCents))")
    }
    print("  total       turnover \(Formatting.money(cents: report.totalNetCents).padding(toLength: 14, withPad: " ", startingAt: 0))  VAT \(Formatting.money(cents: report.totalVatCents))")
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

// MARK: - Invoice

func runInvoice(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    let profile = try resolveProfile(arguments, tracker.store)

    let period: DateRange
    if let month = arguments.string("month") {
        guard let anchor = Formatting.parseDate("\(month)-01") else {
            throw CLIError.usage("cannot read month: '\(month)' (use YYYY-MM)")
        }
        period = Reporting.range(.month, containing: anchor)
    } else {
        // Same default as the monthly reminder: the month that just ended.
        period = Invoicing.previousMonthRange(containing: Date())
    }

    let invoice = try Invoicing.invoice(
        store: tracker.store,
        profileId: profile.id,
        period: period,
        poNumber: arguments.string("po")
    )
    if let ubl = arguments.string("ubl") {
        let url = URL(fileURLWithPath: (ubl as NSString).expandingTildeInPath)
        try UBLExport.data(for: invoice).write(to: url)
        print("UBL \(invoice.number) written to \(url.path)")
    }
    if let out = arguments.string("out") {
        let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        try InvoicePDF.data(for: invoice).write(to: url)
        print("invoice \(invoice.number) for \(profile.name) written to \(url.path)")
    } else if arguments.string("ubl") == nil {
        let url = URL(fileURLWithPath: ("invoice-\(invoice.number).pdf" as NSString).expandingTildeInPath)
        try InvoicePDF.data(for: invoice).write(to: url)
        print("invoice \(invoice.number) for \(profile.name) written to \(url.path)")
    }
    print("period \(Formatting.day(invoice.periodStart)) to \(Formatting.day(invoice.periodEnd.addingTimeInterval(-86400)))")
    print("net \(Formatting.decimalHours(invoice.netSeconds)) hours, total \(Formatting.money(cents: invoice.totalCents, currency: invoice.currency))")
}

/// Makes the credit note that reverses an existing invoice and writes its PDF
/// and/or UBL. The original keeps its number; the credit gets its own and points
/// at it, which is what the Belastingdienst asks of a document that changes an
/// earlier invoice.
func runCredit(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    let original = try arguments.require("number")
    let credit = try Invoicing.credit(store: tracker.store, originalNumber: original)
    if let ubl = arguments.string("ubl") {
        let url = URL(fileURLWithPath: (ubl as NSString).expandingTildeInPath)
        try UBLExport.data(for: credit).write(to: url)
        print("UBL \(credit.number) written to \(url.path)")
    }
    if let out = arguments.string("out") {
        let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        try InvoicePDF.data(for: credit).write(to: url)
        print("credit \(credit.number) for invoice \(original) written to \(url.path)")
    } else if arguments.string("ubl") == nil {
        let url = URL(fileURLWithPath: ("credit-\(credit.number).pdf" as NSString).expandingTildeInPath)
        try InvoicePDF.data(for: credit).write(to: url)
        print("credit \(credit.number) for invoice \(original) written to \(url.path)")
    }
    print("period \(Formatting.day(credit.periodStart)) to \(Formatting.day(credit.periodEnd.addingTimeInterval(-86400)))")
    print("total \(Formatting.money(cents: credit.totalCents, currency: credit.currency)) (reverses invoice \(original))")
}

// MARK: - Payments

/// Lists issued invoices with their payment state. `--unpaid` and `--overdue`
/// narrow it down; `--json` is for scripting.
func runInvoices(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    var invoices = try tracker.store.issuedInvoices()
    if arguments.flag("unpaid") {
        invoices = invoices.filter { !$0.isCredit && !$0.isPaid && $0.totalCents > 0 }
    }
    if arguments.flag("overdue") {
        invoices = invoices.filter { $0.isOverdue() }
    }
    if arguments.flag("json") {
        let items: [[String: Any]] = invoices.map { invoice in
            var item: [String: Any] = [
                "number": invoice.number,
                "customer": invoice.profileName,
                "totalCents": invoice.totalCents,
                "currency": invoice.currency.rawValue,
                "isCredit": invoice.isCredit,
                "issuedAt": Formatting.day(invoice.issuedAt),
                "paid": invoice.isPaid,
                "overdue": invoice.isOverdue(),
            ]
            if let due = invoice.dueAt { item["dueAt"] = Formatting.day(due) }
            if invoice.isOverdue() { item["daysLate"] = invoice.daysLate() }
            return item
        }
        let data = try JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8) ?? "[]")
        return
    }
    guard !invoices.isEmpty else {
        print("no invoices")
        return
    }
    for invoice in invoices {
        let state: String
        if invoice.isCredit {
            state = "credit"
        } else if invoice.isPaid {
            state = "paid \(invoice.paidAt.map(Formatting.day) ?? "")"
        } else if invoice.isOverdue() {
            state = "OVERDUE \(invoice.daysLate())d"
        } else {
            state = "open"
        }
        let due = invoice.dueAt.map { "  due \(Formatting.day($0))" } ?? ""
        print("\(invoice.number)  \(Formatting.day(invoice.issuedAt))  \(invoice.profileName)  "
              + "\(Formatting.money(cents: invoice.totalCents, currency: invoice.currency))  \(state)\(due)")
    }
}

/// Marks an invoice paid, or reopens it again.
func runSetPaid(_ arguments: Arguments, paid: Bool) throws {
    let tracker = try makeTracker()
    let number = try arguments.require("number")
    try tracker.store.setInvoicePaid(number: number, paidAt: paid ? Date() : nil)
    print("\(number) \(paid ? "marked paid" : "reopened")")
}

// MARK: - Import

/// Reads a CSV export from another time tracker and writes the blocks into the
/// database. Clients and projects are created as needed; running it twice does
/// not duplicate anything.
func runImport(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    let formatName = try arguments.require("from")
    guard let format = ImportFormat(rawValue: formatName.lowercased()) else {
        throw CLIError.usage("unknown format: '\(formatName)' (use toggl, harvest or clockify)")
    }
    let file = try arguments.require("file")
    let text: String
    if file == "-" {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        text = String(data: data, encoding: .utf8) ?? ""
    } else {
        let path = (file as NSString).expandingTildeInPath
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw CLIError.usage("cannot read file: \(file)")
        }
        text = contents
    }

    var entries = try Importer.parse(text, format: format, user: arguments.string("user"))
    // A chosen client overrides the file's own client column, for an export of
    // one client or one without a client column at all.
    if let profile = arguments.string("profile") {
        entries = entries.map { var entry = $0; entry.client = profile; return entry }
    }

    if arguments.flag("dry-run") {
        let clients = Set(entries.map { $0.client.isEmpty ? "?" : $0.client })
        let days = entries.map { Formatting.day($0.startedAt) }
        let range = days.isEmpty ? "" : " · \(days.min()!) – \(days.max()!)"
        print("dry run: \(entries.count) block(s) for \(clients.count) client(s)\(range)")
        return
    }
    let summary = try Importer.apply(
        entries, to: tracker.store, tagsEnabled: try tracker.store.settings().tagsEnabled
    )
    print("imported \(summary.description)")
}

// MARK: - Backup and restore

/// Writes a clean copy of the whole database. Without `--out` the file lands next
/// to the database with a dated name.
func runBackup(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    let url = try backupDestination(arguments)
    try Backup.write(store: tracker.store, to: url)
    var line = "backup written to \(url.path)"
    if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
       let size = attributes[.size] as? Int {
        line += " (\(size / 1024) KB)"
    }
    print(line)
    if let peeked = try? Backup.peek(at: url) { print("contains \(peeked.summary)") }
}

/// With `--peek` it only reads a backup's contents; otherwise it replaces the
/// live database with it. A restore asks for confirmation unless `--yes` is given.
func runRestore(_ arguments: Arguments) throws {
    if let peekFile = arguments.string("peek") {
        let url = URL(fileURLWithPath: (peekFile as NSString).expandingTildeInPath)
        let peeked = try Backup.peek(at: url)
        print("\(url.lastPathComponent): schema \(peeked.schemaVersion), \(peeked.summary)")
        return
    }
    let source = URL(fileURLWithPath: (try arguments.require("from") as NSString).expandingTildeInPath)
    let peeked = try Backup.peek(at: source)
    print("this will replace the current database with:")
    print("  \(source.path)")
    print("  schema \(peeked.schemaVersion), \(peeked.summary)")

    let destination = URL(fileURLWithPath: try Store.defaultDatabasePath())
    if !arguments.flag("yes") {
        print("type 'restore' to confirm: ", terminator: "")
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
        guard answer == "restore" else {
            print("cancelled")
            return
        }
    }
    try Backup.restore(from: source, to: destination)
    print("restored. The previous database was kept beside it as \(destination.lastPathComponent).pre-restore-*")
}

/// The backup file to write: `--out`, or a dated name beside the database.
private func backupDestination(_ arguments: Arguments) throws -> URL {
    if let out = arguments.string("out") {
        return URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
    }
    let directory = URL(fileURLWithPath: try Store.defaultDatabasePath()).deletingLastPathComponent()
    return directory.appendingPathComponent(Backup.suggestedFileName())
}

// MARK: - Settings

func runConfig(_ arguments: Arguments) throws {
    let tracker = try makeTracker()
    switch arguments.word(1) ?? "list" {
    case "list":
        let settings = try tracker.store.settings()
        print("dedupe-window-seconds \(settings.dedupeWindowSeconds)   window in which repeated events are ignored")
        print("max-entry-seconds     \(settings.maxEntrySeconds)   after this a running block becomes 'open'")
        print("workday-end-minutes   \(settings.workdayEndMinutes)   a block with no signal ends at this time (minutes since midnight)")
        print("workday-start-minutes \(settings.workdayStartMinutes)   automatic check-ins near this time snap to it (minutes since midnight)")
        print("project-prompt        \(settings.projectPrompt.rawValue)   ask for a project on arrival (0 never, 1 first of the day, 2 every arrival)")
        print("budget-warnings       \(settings.budgetWarningsEnabled ? 1 : 0)   warn when a project budget reaches 80% and 100%")
        print("idle-threshold-minutes \(settings.idleThresholdMinutes)   ask about discarded idle time after this many minutes away (0 = off)")
        print("tags-enabled          \(settings.tagsEnabled ? 1 : 0)   show and edit tags on blocks (0 off, 1 on)")
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
