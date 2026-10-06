import AppIntents
import Foundation
import TickoalaCore

/// Shortcuts (and Siri) control for Tickoala, so the timer can be driven without
/// opening the menu bar. Each intent opens the same SQLite file the app uses; it
/// writes through the normal tracker rules, so a manual start/stop behaves
/// exactly like one from the menu.
@available(macOS 13.0, *)
enum IntentSupport {
    static func tracker() throws -> Tracker {
        Tracker(store: try Store(path: try Store.defaultDatabasePath()))
    }

    /// Today's total for a customer, or the running one if none is named.
    static func resolve(_ tracker: Tracker, customer: String?) throws -> Profile {
        if let customer, !customer.trimmingCharacters(in: .whitespaces).isEmpty {
            return try tracker.store.profile(matching: customer)
        }
        if let running = try tracker.store.runningEntries().first,
           let profile = try tracker.store.profile(id: running.profileId) {
            return profile
        }
        let profiles = try tracker.store.profiles(includeInactive: false)
        guard let first = profiles.first else {
            throw IntentError.noCustomers
        }
        if profiles.count > 1 {
            throw IntentError.ambiguousCustomer(profiles.map(\.name))
        }
        return first
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case noCustomers
    case ambiguousCustomer([String])
    case nothingRunning

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noCustomers:
            return "No customers configured in Tickoala yet."
        case .ambiguousCustomer(let names):
            return "Several customers exist; name one of: \(names.joined(separator: ", "))."
        case .nothingRunning:
            return "No timer is running."
        }
    }
}

@available(macOS 13.0, *)
struct StartTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Start timer"
    static var description = IntentDescription("Start tracking time for a customer.")

    @Parameter(title: "Customer")
    var customer: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let tracker = try IntentSupport.tracker()
        let profile = try tracker.store.profile(matching: customer)
        let entry = try tracker.start(profileId: profile.id)
        return .result(dialog: "Timer started for \(profile.name) at \(Formatting.clock(entry.startedAt)).")
    }
}

@available(macOS 13.0, *)
struct StopTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop timer"
    static var description = IntentDescription("Stop tracking time.")

    @Parameter(title: "Customer")
    var customer: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let tracker = try IntentSupport.tracker()
        let targets: [Profile]
        if let customer, !customer.trimmingCharacters(in: .whitespaces).isEmpty {
            targets = [try tracker.store.profile(matching: customer)]
        } else {
            targets = try tracker.store.runningEntries().compactMap { try tracker.store.profile(id: $0.profileId) }
        }
        guard !targets.isEmpty else { throw IntentError.nothingRunning }
        var parts: [String] = []
        for profile in targets {
            if let entry = try tracker.stop(profileId: profile.id) {
                parts.append("\(profile.name): \(Formatting.duration(entry.duration()))")
            }
        }
        // Two separate returns, so each dialog is a plain literal: a ternary of
        // two strings is inferred as `String` and that no longer converts to
        // `IntentDialog` on newer SDKs.
        guard !parts.isEmpty else { return .result(dialog: "Nothing to stop.") }
        return .result(dialog: "Stopped — \(parts.joined(separator: ", ")).")
    }
}

@available(macOS 13.0, *)
struct TodayTotalIntent: AppIntent {
    static var title: LocalizedStringResource = "Today's hours"
    static var description = IntentDescription("How much you worked today, per customer.")

    @Parameter(title: "Customer")
    var customer: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let tracker = try IntentSupport.tracker()
        let profile = try IntentSupport.resolve(tracker, customer: customer)
        let report = try Reporting.report(
            store: tracker.store, period: .day, containing: Date(), profileId: profile.id
        )
        return .result(dialog: "Today \(Formatting.duration(report.netTotal)) for \(profile.name).")
    }
}

@available(macOS 13.0, *)
struct TickoalaAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartTimerIntent(),
            phrases: ["Start \(.applicationName) for \(\.$customer)"],
            shortTitle: "Start timer",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: StopTimerIntent(),
            phrases: ["Stop \(.applicationName)"],
            shortTitle: "Stop timer",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: TodayTotalIntent(),
            phrases: ["How long did I work on \(.applicationName)"],
            shortTitle: "Today's hours",
            systemImageName: "clock"
        )
    }
}
