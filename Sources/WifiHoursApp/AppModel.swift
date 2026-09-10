import Combine
import Foundation
import SwiftUI
import WifiHoursCore

/// Houdt de status vast die de menubalk en het overzicht tonen. Leest telkens
/// opnieuw uit SQLite, zodat wijzigingen via het adaptercommando meteen zichtbaar zijn.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var status: TrackerStatus?
    @Published private(set) var projectsPerProfile: [Int64: [Project]] = [:]
    @Published private(set) var allProjectsPerProfile: [Int64: [Project]] = [:]
    @Published var errorMessage: String?

    // Overzichtsvenster
    @Published var period: ReportPeriod = .day {
        didSet { reloadOverview() }
    }
    @Published var anchor: Date = Date() {
        didSet { reloadOverview() }
    }
    @Published var profileFilter: Int64? {
        didSet { reloadOverview() }
    }
    @Published private(set) var overviewEntries: [EntryRow] = []
    @Published private(set) var overviewTotal: TimeInterval = 0
    @Published private(set) var overviewByProject: [ProjectTotal] = []

    /// Bron van de start/stop-signalen: de app kijkt zelf naar het wifinetwerk.
    let wifi = WifiWatcher()
    /// Wat het laatste netwerksignaal opleverde, voor uitleg in het menu.
    @Published private(set) var lastWifiOutcome: String?

    private var tracker: Tracker?
    private var timer: Timer?
    private var wifiObserver: AnyCancellable?

    struct EntryRow: Identifiable {
        var entry: TimeEntry
        var profileName: String
        var projectLabel: String
        var id: Int64 { entry.id }
    }

    init() {
        do {
            tracker = Tracker(store: try Store(path: try Store.defaultDatabasePath()))
        } catch {
            errorMessage = "Kan de database niet openen: \(error)"
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        // Elke wisseling van wifinetwerk wordt een gewoon contextsignaal; de tracker
        // beslist zelf of er iets moet gebeuren.
        wifi.onEvent = { [weak self] event in
            self?.handle(event)
        }
        // De watcher publiceert los van dit model, dus even doorgeven aan de views.
        wifiObserver = wifi.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        wifi.start()
    }

    /// Verwerkt een netwerksignaal en onthoudt de uitkomst voor in het menu.
    private func handle(_ event: ContextEvent) {
        guard let tracker else { return }
        do {
            let outcome = try tracker.handle(event)
            lastWifiOutcome = "\(Formatting.clock(event.at))  \(event.context) \(event.kind.rawValue): \(outcome.summary)"
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    var profiles: [ProfileStatus] { status?.profiles ?? [] }

    var menuBarTitle: String { status?.menuBarTitle ?? "–" }

    var menuBarSymbol: String { (status?.mode ?? .stopped).symbol }

    /// Eén keer per seconde: uitgestelde stops afronden en de status verversen.
    func refresh() {
        guard let tracker else { return }
        do {
            try tracker.tick()
            status = try tracker.status()
            var actief: [Int64: [Project]] = [:]
            var alle: [Int64: [Project]] = [:]
            for item in try tracker.store.profiles(includeInactive: false) {
                actief[item.id] = try tracker.store.projects(profileId: item.id, includeInactive: false)
                alle[item.id] = try tracker.store.projects(profileId: item.id, includeInactive: true)
            }
            projectsPerProfile = actief
            allProjectsPerProfile = alle
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
        reloadOverview()
    }

    // MARK: - Wifi

    /// Hoort dit netwerk al bij een klant?
    func isKnownNetwork(_ ssid: String) -> Bool {
        profiles.contains { $0.profile.contexts.contains { $0.caseInsensitiveCompare(ssid) == .orderedSame } }
    }

    /// Koppelt het netwerk waar de Mac nu op zit aan een klant, zodat de
    /// volgende binnenkomst wél automatisch start.
    func linkCurrentNetwork(to profileId: Int64) {
        guard let tracker, let ssid = wifi.currentSSID else { return }
        do {
            _ = try tracker.store.addContext(profileId: profileId, context: ssid)
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: - Projectbeheer

    /// Alle projecten van een profiel, ook de gedeactiveerde. Voor het beheerscherm.
    func allProjects(for profileId: Int64) -> [Project] {
        allProjectsPerProfile[profileId] ?? []
    }

    /// Maakt een project aan. Geeft `false` terug als het niet lukte, bijvoorbeeld
    /// omdat het nummer al bestaat binnen deze organisatie.
    @discardableResult
    func addProject(profileId: Int64, number: String, name: String) -> Bool {
        guard let tracker else { return false }
        let number = number.trimmingCharacters(in: .whitespaces)
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !number.isEmpty, !name.isEmpty else {
            errorMessage = "Vul zowel een projectnummer als een projectnaam in."
            return false
        }
        do {
            try tracker.createProject(profileId: profileId, number: number, name: name)
            refresh()
            return true
        } catch {
            errorMessage = "\(error)"
            return false
        }
    }

    /// Nummer en naam samen bewaren. Geeft `false` terug als het nummer al bestaat
    /// binnen deze organisatie, zodat het formulier open kan blijven.
    @discardableResult
    func updateProject(id: Int64, number: String, name: String) -> Bool {
        guard let tracker else { return false }
        let number = number.trimmingCharacters(in: .whitespaces)
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !number.isEmpty, !name.isEmpty else {
            errorMessage = "Projectnummer en projectnaam mogen niet leeg zijn."
            return false
        }
        do {
            try tracker.store.updateProject(id: id, number: number, name: name)
            refresh()
            return true
        } catch {
            errorMessage = "\(error)"
            return false
        }
    }

    // MARK: - Pauzeaftrek

    func updateBreakRule(profileId: Int64, rule: BreakRule) {
        guard let tracker else { return }
        do {
            try tracker.store.updateBreakRule(profileId: profileId, rule: rule)
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Deactiveren laat bestaande tijdregistraties staan; het project verdwijnt
    /// alleen uit de keuzelijsten.
    func setProjectActive(id: Int64, active: Bool) {
        guard let tracker else { return }
        do {
            try tracker.store.updateProject(id: id, active: active)
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func activeProjectId(for profileId: Int64) -> Int64? {
        profiles.first(where: { $0.profile.id == profileId })?.project?.id
    }

    // MARK: - Bediening

    func selectProject(profileId: Int64, projectId: Int64) {
        perform { try $0.selectProject(profileId: profileId, projectId: projectId) }
    }

    func pause(profileId: Int64) {
        perform { try $0.pause(profileId: profileId) }
    }

    func resume(profileId: Int64) {
        perform { try $0.resume(profileId: profileId) }
    }

    func start(profileId: Int64) {
        perform { try $0.start(profileId: profileId) }
    }

    func stop(profileId: Int64) {
        perform { try $0.stop(profileId: profileId) }
    }

    func clearAttention(profileId: Int64) {
        perform { try $0.clearAttention(profileId: profileId) }
    }

    // MARK: - Overzicht en correcties

    func reloadOverview() {
        guard let tracker else { return }
        do {
            let report = try Reporting.report(store: tracker.store, period: period, containing: anchor, profileId: profileFilter)
            let entries = try tracker.store.entries(from: report.range.start, to: report.range.end, profileId: profileFilter)
            overviewEntries = try entries.map { entry in
                EntryRow(
                    entry: entry,
                    profileName: try tracker.store.profile(id: entry.profileId)?.name ?? "?",
                    projectLabel: try entry.projectId.flatMap { try tracker.store.project(id: $0) }?.label ?? "(geen project)"
                )
            }
            overviewTotal = report.total
            overviewByProject = report.byProject
        } catch {
            errorMessage = "\(error)"
        }
    }

    var overviewRange: DateRange {
        Reporting.range(period, containing: anchor)
    }

    func shiftPeriod(_ direction: Int) {
        let component: Calendar.Component
        switch period {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        }
        if let moved = Formatting.calendar.date(byAdding: component, value: direction, to: anchor) {
            anchor = moved
        }
    }

    func projects(for profileId: Int64) -> [Project] {
        projectsPerProfile[profileId] ?? []
    }

    func updateEntry(id: Int64, projectId: Int64?, start: Date, end: Date?, note: String, status: EntryStatus) {
        guard let tracker else { return }
        guard end == nil || end! >= start else {
            errorMessage = "Het einde ligt voor het begin."
            return
        }
        do {
            try tracker.store.updateEntry(
                id: id,
                projectId: .some(projectId),
                startedAt: start,
                endedAt: .some(end),
                status: status,
                note: .some(note.isEmpty ? nil : note)
            )
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func addEntry(profileId: Int64, projectId: Int64?, start: Date, end: Date, note: String) {
        guard let tracker else { return }
        guard end > start else {
            errorMessage = "Het einde moet na het begin liggen."
            return
        }
        do {
            _ = try tracker.store.createEntry(
                profileId: profileId, projectId: projectId, startedAt: start, endedAt: end,
                status: .completed, source: .manual, note: note.isEmpty ? nil : note
            )
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func deleteEntry(id: Int64) {
        guard let tracker else { return }
        do {
            try tracker.store.deleteEntry(id: id)
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// CSV van de getoonde periode.
    func exportCSV() -> String? {
        guard let tracker else { return nil }
        do {
            let range = overviewRange
            return try CSVExport.export(store: tracker.store, from: range.start, to: range.end, profileId: profileFilter)
        } catch {
            errorMessage = "\(error)"
            return nil
        }
    }

    func suggestedExportName() -> String {
        let range = overviewRange
        switch period {
        case .day: return "uren-\(Formatting.day(range.start)).csv"
        case .week: return "uren-week-\(Formatting.day(range.start)).csv"
        case .month: return "uren-\(String(Formatting.day(range.start).prefix(7))).csv"
        }
    }

    private func perform(_ action: (Tracker) throws -> Void) {
        guard let tracker else { return }
        do {
            try action(tracker)
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }
}
