import Combine
import Foundation
import SwiftUI
import TickoalaCore

/// Holds the status that the menu bar and the overview show. Reads from SQLite
/// every time, so changes made through the adapter command show up immediately.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var status: TrackerStatus?
    @Published private(set) var projectsPerProfile: [Int64: [Project]] = [:]
    @Published private(set) var allProjectsPerProfile: [Int64: [Project]] = [:]
    @Published var errorMessage: String?

    /// Is there a project or block change that Cmd+Z can take back?
    @Published private(set) var canUndo = false
    /// Is there a change that Shift+Cmd+Z can put back?
    @Published private(set) var canRedo = false

    /// Which customer the Customers window shows and where the Projects open.
    @Published var selectedCustomerId: Int64?

    /// Detect presence from the network name or from the Mac's location.
    @Published var presenceSource: PresenceSource = .wifi {
        didSet {
            guard presenceSource != oldValue else { return }
            UserDefaults.standard.set(presenceSource.rawValue, forKey: Self.presenceSourceKey)
            wifi.source = presenceSource
            currentLocationProfileId = nil
            refresh()
        }
    }
    private static let presenceSourceKey = "presence-source"

    // Overview window
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
    /// Net hours of the shown period, after the automatic break deduction.
    @Published private(set) var overviewTotal: TimeInterval = 0
    /// The automatic break deduction over the shown period, so the overview can
    /// show why the total is lower than the sum of the blocks.
    @Published private(set) var overviewBreak: TimeInterval = 0
    @Published private(set) var overviewByProject: [ProjectTotal] = []
    @Published private(set) var overviewByProfile: [ProfileTotal] = []
    @Published private(set) var overviewAmountCents: Int = 0

    /// Source of the start/stop signals: the app watches the Wi-Fi network itself.
    let wifi = WifiWatcher()
    /// Checks whether a newer release exists. The existing timer drives the check.
    let updateChecker = UpdateChecker()
    /// Controls the login item, shown in the welcome screen.
    let launchAtLogin = LaunchAtLogin()
    /// What the last network signal produced, for explanation in the menu.
    @Published private(set) var lastWifiOutcome: String?
    /// An arrival where the organization has multiple active projects.
    @Published private(set) var pendingWifiProjectSelection: WifiProjectSelection?
    /// A network change while a block runs elsewhere: continue or start new?
    @Published private(set) var pendingNetworkSwitch: NetworkSwitch?

    /// Set on the first weekday of the month when there are hours to invoice; the
    /// menu bar label watches it and opens the invoices window once.
    @Published private(set) var shouldOpenInvoices = false

    /// Set when the Dock icon is clicked while the app runs; the menu bar label
    /// watches it and brings the Settings window up once.
    @Published private(set) var shouldOpenSettings = false

    private var tracker: Tracker?
    private var timer: Timer?
    private var wifiObserver: AnyCancellable?
    private var updateObserver: AnyCancellable?
    private var loginObserver: AnyCancellable?

    struct EntryRow: Identifiable {
        var entry: TimeEntry
        var profileName: String
        var projectLabel: String
        var hourlyRateCents: Int
        var currency: Currency
        /// The break the row shows: the block's own break, or the customer's
        /// automatic deduction for the day when the block has none.
        var breakDisplay: TimeInterval = 0
        /// Is `breakDisplay` the automatic deduction rather than a recorded break?
        var breakIsAutomatic: Bool = false
        /// Duration to show: the worked time, with the automatic deduction for the
        /// day taken off the row that carries it.
        var durationDisplay: TimeInterval = 0
        var id: Int64 { entry.id }

        /// Amount of this block at the customer's rate, on the shown (net) duration.
        var amountCents: Int {
            guard hourlyRateCents > 0 else { return 0 }
            return Int((durationDisplay / 3600 * Double(hourlyRateCents)).rounded())
        }
    }

    struct WifiProjectSelection: Equatable {
        var profileId: Int64
        var ssid: String
        var eventAt: Date
        var source: EntrySource
        var projects: [Project]
    }

    /// A change to another network while a block is running elsewhere. The user
    /// decides whether the current project simply continues or a new block starts.
    struct NetworkSwitch: Equatable {
        var runningProfileId: Int64
        var runningLabel: String
        var context: String
        var event: ContextEvent
    }

    init() {
        Self.migrateOldPreferences()
        do {
            tracker = Tracker(store: try Store(path: try Store.defaultDatabasePath()))
        } catch {
            errorMessage = "Cannot open the database: \(error)"
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        // Restore the chosen detection source before the watcher starts.
        presenceSource = PresenceSource(rawValue: UserDefaults.standard.string(forKey: Self.presenceSourceKey) ?? "") ?? .wifi
        wifi.source = presenceSource
        // A coordinate only becomes a signal when it is near a stored location.
        wifi.resolveLocationContext = { [weak self] latitude, longitude in
            self?.locationContext(latitude: latitude, longitude: longitude)
        }

        // Every Wi-Fi network change becomes a normal context signal; the tracker
        // decides for itself whether anything should happen.
        wifi.onEvent = { [weak self] event in
            self?.handle(event)
        }
        // The watcher publishes separately from this model, so pass it on to the views.
        wifiObserver = wifi.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        // The same for the update check, so the menu updates immediately.
        updateObserver = updateChecker.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        // And for the login item, so the welcome screen reflects the real status.
        loginObserver = launchAtLogin.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        wifi.start()
    }

    /// The app used `local.tickoala.app` before the bundle id had to change for
    /// macOS 26's menu bar administration. Carry the handful of preferences over
    /// once, so the detection source and the update switch are not silently lost.
    private static func migrateOldPreferences() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migrated-bundle-id") else { return }
        defaults.set(true, forKey: "migrated-bundle-id")
        guard let old = UserDefaults(suiteName: "local.tickoala.app") else { return }
        for key in ["presence-source", "update-check-disabled", "invoice-reminder-shown", "welcome-seen"] {
            if defaults.object(forKey: key) == nil, let value = old.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
    }

    /// Processes a network signal. A start on another network while a block runs
    /// is not applied silently: the user first chooses continue or start new.
    private func handle(_ event: ContextEvent) {
        guard let tracker else { return }
        if event.kind == .start, let pending = networkSwitchChoice(for: event, tracker: tracker) {
            pendingNetworkSwitch = pending
            lastWifiOutcome = "\(Formatting.clock(event.at))  \(displayContext(event.context)) start: waiting for your choice"
            refresh()
            return
        }
        process(event)
    }

    /// Applies a signal the normal way; the tracker decides what happens.
    private func process(_ event: ContextEvent) {
        guard let tracker else { return }
        do {
            let outcome = try tracker.handle(event)
            lastWifiOutcome = "\(Formatting.clock(event.at))  \(displayContext(event.context)) \(event.kind.rawValue): \(outcome.summary)"

            switch outcome {
            case .needsProjectChoice(let profileId, let projectIds):
                let projects = projectIds.compactMap { try? tracker.store.project(id: $0) }
                if projects.count > 1 {
                    pendingWifiProjectSelection = WifiProjectSelection(
                        profileId: profileId,
                        ssid: displayContext(event.context),
                        eventAt: event.at,
                        source: event.source,
                        projects: projects
                    )
                }
            default:
                pendingWifiProjectSelection = nil
            }

            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// A change to another network while a block runs elsewhere needs a choice.
    private func networkSwitchChoice(for event: ContextEvent, tracker: Tracker) -> NetworkSwitch? {
        guard let running = try? tracker.store.runningEntries().first else { return nil }
        // Same customer (roaming) continues silently and automatically.
        if let newProfile = try? tracker.store.profile(context: event.context),
           newProfile.id == running.profileId {
            return nil
        }
        let runningProfile = try? tracker.store.profile(id: running.profileId)
        let project = running.projectId.flatMap { try? tracker.store.project(id: $0) }
        return NetworkSwitch(
            runningProfileId: running.profileId,
            runningLabel: "\(runningProfile?.name ?? "?") · \(project?.label ?? "no project")",
            context: event.context,
            event: event
        )
    }

    /// Keep the current block running after a network change: undo the scheduled
    /// stop and ignore the new network.
    func keepRunningAfterNetworkSwitch() {
        guard let pending = pendingNetworkSwitch, let tracker else { return }
        do {
            try tracker.cancelPendingStop(profileId: pending.runningProfileId)
            pendingNetworkSwitch = nil
            lastWifiOutcome = "\(Formatting.clock(pending.event.at))  \(displayContext(pending.context)) start: kept running"
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Confirm the switch: close the old block and start on the new network.
    func startNewBlockAfterNetworkSwitch() {
        guard let pending = pendingNetworkSwitch else { return }
        pendingNetworkSwitch = nil
        process(pending.event)
    }

    /// A location context (`geo:<id>`) shows the customer's name instead.
    func displayContext(_ context: String) -> String {
        guard context.hasPrefix("geo:"), let id = Int64(context.dropFirst(4)) else { return context }
        return (try? tracker?.store.profile(id: id))?.name ?? context
    }

    var profiles: [ProfileStatus] { status?.profiles ?? [] }

    var menuBarTitle: String { status?.menuBarTitle ?? "–" }

    var menuBarSymbol: String { (status?.mode ?? .stopped).symbol }

    /// Once per second: finalize delayed stops and refresh the status.
    func refresh() {
        // The same tick drives the update check; it does nothing until the day is over.
        updateChecker.checkIfNeeded()
        guard let tracker else { return }
        do {
            try tracker.tick()
            status = try tracker.status()
            // A prompt about a switch is worthless once nothing runs any more.
            if pendingNetworkSwitch != nil, try tracker.store.runningEntries().isEmpty {
                pendingNetworkSwitch = nil
            }
            var active: [Int64: [Project]] = [:]
            var all: [Int64: [Project]] = [:]
            for item in try tracker.store.profiles(includeInactive: false) {
                active[item.id] = try tracker.store.projects(profileId: item.id, includeInactive: false)
                all[item.id] = try tracker.store.projects(profileId: item.id, includeInactive: true)
            }
            projectsPerProfile = active
            allProjectsPerProfile = all
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
        ensureSelectedCustomer()
        reloadOverview()
        checkInvoiceReminder()
    }

    /// Keeps the chosen customer valid: if it disappears (or nothing is chosen
    /// yet), the choice moves to the first customer.
    private func ensureSelectedCustomer() {
        let ids = profiles.map { $0.profile.id }
        if let selectedCustomerId, ids.contains(selectedCustomerId) { return }
        selectedCustomerId = ids.first
    }

    // MARK: - Wi-Fi

    /// Does this network already belong to a customer?
    func isKnownNetwork(_ ssid: String) -> Bool {
        profiles.contains { $0.profile.contexts.contains { $0.caseInsensitiveCompare(ssid) == .orderedSame } }
    }

    /// The client the Mac is currently considered to be at, for hysteresis.
    private var currentLocationProfileId: Int64?

    /// The client context for a coordinate, if it lies within a stored radius.
    /// Keeps the current client until it is clearly out of range.
    private func locationContext(latitude: Double, longitude: Double) -> String? {
        guard let tracker, let all = try? tracker.store.profiles() else { return nil }
        let candidates = all.filter(\.active)
        let current = candidates.first { $0.id == currentLocationProfileId }
        let found = Geo.nearestProfile(to: latitude, longitude, profiles: candidates, stayingAt: current)
        currentLocationProfileId = found?.id
        return found?.geoContext
    }

    /// Name of the client the Mac is at, when detecting by location.
    var currentLocationName: String? {
        guard let context = wifi.currentSSID, context.hasPrefix("geo:") else { return nil }
        return displayContext(context)
    }

    /// Marks a customer at the Mac's current position, for location detection.
    func setCustomerLocation(id: Int64, radiusMeters: Int) {
        guard let latitude = wifi.latitude, let longitude = wifi.longitude else {
            errorMessage = "No location fix yet. Wait a moment and try again."
            return
        }
        applyCustomerLocation(id: id, latitude: latitude, longitude: longitude, radiusMeters: radiusMeters)
    }

    /// Stores or updates a customer's coordinates and radius.
    func applyCustomerLocation(id: Int64, latitude: Double, longitude: Double, radiusMeters: Int) {
        guard let tracker else { return }
        do {
            try tracker.store.updateProfileLocation(
                id: id, latitude: latitude, longitude: longitude, radiusMeters: radiusMeters
            )
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Switches a customer back to network detection only.
    func clearCustomerLocation(id: Int64) {
        guard let tracker else { return }
        do {
            try tracker.store.updateProfileLocation(id: id, latitude: nil, longitude: nil, radiusMeters: 150)
            if currentLocationProfileId == id { currentLocationProfileId = nil }
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Links the network the Mac is currently on to a customer, so the next
    /// arrival starts automatically.
    func linkCurrentNetwork(to profileId: Int64) {
        guard let tracker, let ssid = wifi.currentSSID else { return }
        do {
            _ = try tracker.store.addContext(profileId: profileId, context: ssid)
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func chooseWifiProject(_ selection: WifiProjectSelection, projectId: Int64) {
        guard let tracker else { return }
        guard selection.projects.contains(where: { $0.id == projectId }) else { return }
        do {
            _ = try tracker.selectProject(profileId: selection.profileId, projectId: projectId, now: selection.eventAt)
            _ = try tracker.start(profileId: selection.profileId, now: selection.eventAt, source: selection.source)
            pendingWifiProjectSelection = nil
            lastWifiOutcome = "\(Formatting.clock(selection.eventAt))  \(selection.ssid) start: timer started"
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func cancelWifiProjectSelection() {
        pendingWifiProjectSelection = nil
    }

    // MARK: - Customer management

    /// Adds a customer with at least one Wi-Fi network. Returns `false` for
    /// invalid input or a network that already belongs to another customer.
    @discardableResult
    func addCustomer(name: String, contexts: [String], hourlyRateCents: Int, currency: Currency) -> Bool {
        guard let tracker else { return false }
        let name = name.trimmingCharacters(in: .whitespaces)
        let cleaned = contexts
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !name.isEmpty else {
            errorMessage = "Enter a name for the customer."
            return false
        }
        guard !cleaned.isEmpty else {
            errorMessage = "Link at least one Wi-Fi network to the customer."
            return false
        }
        do {
            let profile = try tracker.store.createProfile(
                name: name, contexts: cleaned, hourlyRateCents: hourlyRateCents, currency: currency
            )
            selectedCustomerId = profile.id
            refresh()
            return true
        } catch {
            errorMessage = "\(error)"
            return false
        }
    }

    func updateCustomer(id: Int64, name: String, hourlyRateCents: Int, currency: Currency) {
        guard let tracker else { return }
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            errorMessage = "The customer name must not be empty."
            return
        }
        do {
            try tracker.store.updateProfile(id: id, name: name, hourlyRateCents: hourlyRateCents, currency: currency)
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func setCustomerActive(id: Int64, active: Bool) {
        guard let tracker else { return }
        do {
            try tracker.store.updateProfile(id: id, active: active)
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Deletes a customer with all their projects and blocks. Undo puts the whole
    /// customer back from a raw copy of the rows.
    func deleteCustomer(id: Int64, undoManager: UndoManager? = nil) {
        guard let tracker else { return }
        do {
            let backup = try tracker.store.deleteProfile(id: id)
            record("Delete customer",
                perform: { [weak self] in
                    try? self?.tracker?.store.restoreProfile(backup)
                },
                revert: { [weak self] in
                    _ = try? self?.tracker?.store.deleteProfile(id: id)
                })
            if selectedCustomerId == id { selectedCustomerId = nil }
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func addCustomerContext(profileId: Int64, context: String) {
        guard let tracker else { return }
        let context = context.trimmingCharacters(in: .whitespaces)
        guard !context.isEmpty else { return }
        do {
            _ = try tracker.store.addContext(profileId: profileId, context: context)
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func removeCustomerContext(profileId: Int64, context: String) {
        guard let tracker else { return }
        do {
            _ = try tracker.store.removeContext(profileId: profileId, context: context)
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// The chosen customer as `Profile`, or the first customer if none is chosen.
    var selectedCustomer: Profile? {
        if let selectedCustomerId,
           let match = profiles.first(where: { $0.profile.id == selectedCustomerId }) {
            return match.profile
        }
        return profiles.first?.profile
    }

    // MARK: - Project management

    /// All projects of a profile, including deactivated ones. For the management screen.
    func allProjects(for profileId: Int64) -> [Project] {
        allProjectsPerProfile[profileId] ?? []
    }

    /// Creates a project. Returns `false` if it failed, for example because the
    /// number already exists within this organization.
    @discardableResult
    func addProject(profileId: Int64, number: String, name: String) -> Bool {
        guard let tracker else { return false }
        let number = number.trimmingCharacters(in: .whitespaces)
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !number.isEmpty, !name.isEmpty else {
            errorMessage = "Enter both a project number and a project name."
            return false
        }
        do {
            let previousActive = (try? tracker.store.state(profileId: profileId))?.activeProjectId
            let project = try tracker.createProject(profileId: profileId, number: number, name: name)
            record("Add project",
                perform: { [weak self] in
                    guard let self, let tracker = self.tracker else { return }
                    try? tracker.store.deleteProject(id: project.id)
                    if var state = try? tracker.store.state(profileId: profileId) {
                        state.activeProjectId = previousActive
                        try? tracker.store.save(state)
                    }
                },
                revert: { [weak self] in
                    _ = try? self?.tracker?.createProject(profileId: profileId, number: number, name: name)
                })
            refresh()
            return true
        } catch {
            errorMessage = "\(error)"
            return false
        }
    }

    /// Saves number and name together. Returns `false` if the number already
    /// exists within this organization, so the form can stay open.
    @discardableResult
    func updateProject(id: Int64, number: String, name: String) -> Bool {
        guard let tracker else { return false }
        let number = number.trimmingCharacters(in: .whitespaces)
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !number.isEmpty, !name.isEmpty else {
            errorMessage = "Project number and project name must not be empty."
            return false
        }
        do {
            let previous = try? tracker.store.project(id: id)
            try tracker.store.updateProject(id: id, number: number, name: name)
            if let previous {
                record("Edit project",
                    perform: { [weak self] in
                        try? self?.tracker?.store.updateProject(id: id, number: previous.number, name: previous.name)
                    },
                    revert: { [weak self] in
                        try? self?.tracker?.store.updateProject(id: id, number: number, name: name)
                    })
            }
            refresh()
            return true
        } catch {
            errorMessage = "\(error)"
            return false
        }
    }

    // MARK: - Break deduction

    func updateBreakRule(profileId: Int64, rule: BreakRule) {
        guard let tracker else { return }
        do {
            try tracker.store.updateBreakRule(profileId: profileId, rule: rule)
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Deactivating leaves existing time entries alone; the project merely
    /// disappears from the selection lists.
    func setProjectActive(id: Int64, active: Bool) {
        guard let tracker else { return }
        do {
            let previous = (try? tracker.store.project(id: id))?.active
            try tracker.store.updateProject(id: id, active: active)
            if let previous {
                record(active ? "Activate project" : "Deactivate project",
                    perform: { [weak self] in
                        try? self?.tracker?.store.updateProject(id: id, active: previous)
                    },
                    revert: { [weak self] in
                        try? self?.tracker?.store.updateProject(id: id, active: active)
                    })
            }
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Deletes a project. Its blocks stay but lose the project link; undoing puts
    /// the project back and relinks the blocks that pointed at it.
    func deleteProject(id: Int64) {
        guard let tracker else { return }
        do {
            guard let project = try tracker.store.project(id: id) else {
                throw TrackerError.unknownProject(String(id))
            }
            let linkedEntries = try tracker.store.entryIds(projectId: id)
            let previousActive = try tracker.store.state(profileId: project.profileId).activeProjectId
            try tracker.store.deleteProject(id: id)

            var restoredId: Int64?
            record("Delete project",
                perform: { [weak self] in
                    guard let self, let tracker = self.tracker,
                          let restored = try? tracker.store.createProject(
                              profileId: project.profileId, number: project.number, name: project.name
                          ) else { return }
                    restoredId = restored.id
                    if !project.active {
                        try? tracker.store.updateProject(id: restored.id, active: false)
                    }
                    for entryId in linkedEntries {
                        try? tracker.store.updateEntry(id: entryId, projectId: .some(restored.id))
                    }
                    if previousActive == id {
                        var state = (try? tracker.store.state(profileId: project.profileId))
                            ?? ProfileState(profileId: project.profileId)
                        state.activeProjectId = restored.id
                        try? tracker.store.save(state)
                    }
                },
                revert: { [weak self] in
                    if let restoredId { try? self?.tracker?.store.deleteProject(id: restoredId) }
                })
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func activeProjectId(for profileId: Int64) -> Int64? {
        profiles.first(where: { $0.profile.id == profileId })?.project?.id
    }

    // MARK: - Control

    /// Switches the active project. A running block is closed and a new one starts
    /// on the new project, so undo has to reopen the old block and drop the new.
    func selectProject(profileId: Int64, projectId: Int64) {
        if pendingWifiProjectSelection?.profileId == profileId {
            pendingWifiProjectSelection = nil
        }
        guard let tracker else { return }
        do {
            let previousState = try tracker.store.state(profileId: profileId)
            let previousRunning = try tracker.store.runningEntry(profileId: profileId)
            _ = try tracker.selectProject(profileId: profileId, projectId: projectId)
            let newRunning = try tracker.store.runningEntry(profileId: profileId)

            // Choosing the project that is already active changes nothing to undo.
            guard previousState.activeProjectId != projectId else {
                refresh()
                return
            }

            record("Switch project",
                perform: { [weak self] in
                    guard let self, let tracker = self.tracker else { return }
                    // Drop the block the switch opened, then reopen the old one.
                    if let newRunning, newRunning.id != previousRunning?.id {
                        try? tracker.store.deleteEntry(id: newRunning.id)
                    }
                    try? tracker.store.save(previousState)
                    if let previousRunning {
                        try? tracker.store.updateEntry(
                            id: previousRunning.id,
                            projectId: .some(previousRunning.projectId),
                            endedAt: .some(previousRunning.endedAt),
                            status: previousRunning.status
                        )
                    }
                },
                revert: { [weak self] in
                    _ = try? self?.tracker?.selectProject(profileId: profileId, projectId: projectId)
                })
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func pause(profileId: Int64) {
        perform { try $0.pause(profileId: profileId) }
    }

    func resume(profileId: Int64) {
        pendingWifiProjectSelection = nil
        perform { try $0.resume(profileId: profileId) }
    }

    func start(profileId: Int64) {
        pendingWifiProjectSelection = nil
        perform { try $0.start(profileId: profileId) }
    }

    func stop(profileId: Int64) {
        pendingWifiProjectSelection = nil
        perform { try $0.stop(profileId: profileId) }
    }

    func clearAttention(profileId: Int64) {
        perform { try $0.clearAttention(profileId: profileId) }
    }

    // MARK: - Overview and corrections

    func reloadOverview() {
        guard let tracker else { return }
        do {
            let report = try Reporting.report(store: tracker.store, period: period, containing: anchor, profileId: profileFilter)
            let entries = try tracker.store.entries(from: report.range.start, to: report.range.end, profileId: profileFilter)
            // The automatic deduction belongs to a client-day, not to one block.
            // Show it on the first block of that day, so a day with several blocks
            // does not show the same break more than once. Entries arrive sorted by
            // start time.
            var firstEntryOfDay: [ProfileDay: Int64] = [:]
            for entry in entries {
                let key = ProfileDay(profileId: entry.profileId, day: Formatting.calendar.startOfDay(for: entry.startedAt))
                if firstEntryOfDay[key] == nil { firstEntryOfDay[key] = entry.id }
            }
            overviewEntries = try entries.map { entry in
                let profile = try tracker.store.profile(id: entry.profileId)
                let key = ProfileDay(profileId: entry.profileId, day: Formatting.calendar.startOfDay(for: entry.startedAt))
                var breakDisplay = entry.breakDuration
                var breakIsAutomatic = false
                if breakDisplay == 0,
                   let automatic = report.breakByProfileDay[key], automatic > 0,
                   firstEntryOfDay[key] == entry.id {
                    breakDisplay = automatic
                    breakIsAutomatic = true
                }
                return EntryRow(
                    entry: entry,
                    profileName: profile?.name ?? "?",
                    projectLabel: try entry.projectId.flatMap { try tracker.store.project(id: $0) }?.label ?? "(no project)",
                    hourlyRateCents: profile?.hourlyRateCents ?? 0,
                    currency: profile?.currency ?? .eur,
                    breakDisplay: breakDisplay,
                    breakIsAutomatic: breakIsAutomatic,
                    durationDisplay: max(0, entry.duration() - (breakIsAutomatic ? breakDisplay : 0))
                )
            }
            overviewTotal = report.netTotal
            overviewBreak = report.breakDeduction
            overviewByProject = report.byProject
            overviewByProfile = report.byProfile
            overviewAmountCents = report.amountCents
        } catch {
            errorMessage = "\(error)"
        }
    }

    var overviewRange: DateRange {
        Reporting.range(period, containing: anchor)
    }

    /// The currency for the overview amount: that of the shown customer(s). If
    /// multiple currencies are in view there is no sensible total, so we fall back
    /// to the chosen customer, or euros otherwise.
    var overviewCurrency: Currency {
        let currencies = Set(overviewByProfile.map(\.currency))
        if currencies.count == 1, let only = currencies.first { return only }
        return selectedCustomer?.currency ?? .eur
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

    /// The break rule of a customer, so the correction forms can default to the
    /// break that is configured for them.
    func breakRule(for profileId: Int64) -> BreakRule {
        profiles.first { $0.profile.id == profileId }?.profile.breakRule ?? .default
    }

    func updateEntry(
        id: Int64,
        projectId: Int64?,
        start: Date,
        end: Date?,
        breakStart: Date?,
        breakEnd: Date?,
        note: String,
        status: EntryStatus
    ) {
        guard let tracker else { return }
        let start = Formatting.minute(start)
        let end = end.map(Formatting.minute)
        let breakStart = breakStart.map(Formatting.minute)
        let breakEnd = breakEnd.map(Formatting.minute)
        guard end == nil || end! >= start else {
            errorMessage = "The end is before the start."
            return
        }
        do {
            let previous = try? tracker.store.entry(id: id)
            try tracker.store.updateEntry(
                id: id,
                projectId: .some(projectId),
                startedAt: start,
                endedAt: .some(end),
                status: status,
                note: .some(note.isEmpty ? nil : note)
            )
            // The store validates that the break falls within the block.
            if let breakStart, let breakEnd, end != nil {
                try tracker.store.setBreak(id: id, breakStart: breakStart, breakEnd: breakEnd)
            } else {
                try tracker.store.clearBreak(id: id)
            }
            if let previous {
                record("Edit block",
                    perform: { [weak self] in
                        try? self?.tracker?.store.updateEntry(
                            id: id,
                            projectId: .some(previous.projectId),
                            startedAt: previous.startedAt,
                            endedAt: .some(previous.endedAt),
                            breakStartedAt: .some(previous.breakStartedAt),
                            breakEndedAt: .some(previous.breakEndedAt),
                            status: previous.status,
                            note: .some(previous.note)
                        )
                    },
                    revert: { [weak self] in
                        try? self?.tracker?.store.updateEntry(
                            id: id,
                            projectId: .some(projectId),
                            startedAt: start,
                            endedAt: .some(end),
                            breakStartedAt: .some(breakStart),
                            breakEndedAt: .some(breakEnd),
                            status: status,
                            note: .some(note.isEmpty ? nil : note)
                        )
                    })
            }
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    @discardableResult
    func addEntry(
        profileId: Int64,
        projectId: Int64?,
        start: Date,
        end: Date,
        breakStart: Date? = nil,
        breakEnd: Date? = nil,
        note: String
    ) -> Int64? {
        guard let tracker else { return nil }
        let start = Formatting.minute(start)
        let end = Formatting.minute(end)
        let breakStart = breakStart.map(Formatting.minute)
        let breakEnd = breakEnd.map(Formatting.minute)
        guard end > start else {
            errorMessage = "The end must be after the start."
            return nil
        }
        guard breakStart == nil || breakEnd == nil
            || (breakStart! >= start && breakEnd! <= end && breakStart! < breakEnd!) else {
            errorMessage = "The break must fall within the block and have a positive duration."
            return nil
        }
        do {
            let entry = try tracker.store.createEntry(
                profileId: profileId, projectId: projectId, startedAt: start, endedAt: end,
                breakStartedAt: breakStart, breakEndedAt: breakEnd,
                status: .completed, source: .manual, note: note.isEmpty ? nil : note
            )
            record("Add block",
                perform: { [weak self] in
                    try? self?.tracker?.store.deleteEntry(id: entry.id)
                },
                revert: { [weak self] in
                    _ = try? self?.tracker?.store.createEntry(
                        profileId: entry.profileId,
                        projectId: entry.projectId,
                        startedAt: entry.startedAt,
                        endedAt: entry.endedAt,
                        breakStartedAt: entry.breakStartedAt,
                        breakEndedAt: entry.breakEndedAt,
                        status: entry.status,
                        source: entry.source,
                        note: entry.note
                    )
                })
            refresh()
            return entry.id
        } catch {
            errorMessage = "\(error)"
            return nil
        }
    }

    @discardableResult
    func duplicateEntry(id: Int64) -> Int64? {
        guard let tracker else { return nil }
        do {
            let duplicate = try tracker.store.duplicateEntry(id: id)
            record("Duplicate block",
                perform: { [weak self] in
                    try? self?.tracker?.store.deleteEntry(id: duplicate.id)
                },
                revert: { [weak self] in
                    _ = try? self?.tracker?.store.duplicateEntry(id: id)
                })
            refresh()
            return duplicate.id
        } catch {
            errorMessage = "\(error)"
            return nil
        }
    }

    @discardableResult
    func deleteEntry(id: Int64) -> Bool {
        guard let tracker else { return false }
        do {
            let previous = try? tracker.store.entry(id: id)
            try tracker.store.deleteEntry(id: id)
            if let previous {
                var restoredId: Int64?
                record("Delete block",
                    perform: { [weak self] in
                        restoredId = try? self?.tracker?.store.createEntry(
                            profileId: previous.profileId,
                            projectId: previous.projectId,
                            startedAt: previous.startedAt,
                            endedAt: previous.endedAt,
                            breakStartedAt: previous.breakStartedAt,
                            breakEndedAt: previous.breakEndedAt,
                            status: previous.status,
                            source: previous.source,
                            note: previous.note
                        ).id
                    },
                    revert: { [weak self] in
                        if let restoredId { try? self?.tracker?.store.deleteEntry(id: restoredId) }
                    })
            }
            refresh()
            return true
        } catch {
            errorMessage = "\(error)"
            return false
        }
    }

    /// CSV of the shown period.
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
        case .day: return "hours-\(Formatting.day(range.start)).csv"
        case .week: return "hours-week-\(Formatting.day(range.start)).csv"
        case .month: return "hours-\(String(Formatting.day(range.start).prefix(7))).csv"
        }
    }

    // MARK: - Invoicing

    /// The month the invoices window acts on. Can be moved to any month to
    /// invoice by hand; the reminder and the menu set the starting month.
    @Published var invoicePeriod: DateRange = Invoicing.previousMonthRange(containing: Date())

    /// Moves the invoices window to another month, any month.
    func shiftInvoicePeriod(_ months: Int) {
        let moved = Formatting.calendar.date(byAdding: .month, value: months, to: invoicePeriod.start)
            ?? invoicePeriod.start
        invoicePeriod = Reporting.range(.month, containing: moved)
    }

    /// The month that just ended: what the automatic reminder opens.
    func showPreviousInvoiceMonth() {
        invoicePeriod = Invoicing.previousMonthRange(containing: Date())
    }

    /// The month we are in now: the starting point when the window is opened by
    /// hand, so the hours booked so far this month can be invoiced right away.
    func showCurrentInvoiceMonth() {
        invoicePeriod = Reporting.range(.month, containing: Date())
    }

    struct InvoiceCandidate: Identifiable {
        var profile: Profile
        var grossSeconds: TimeInterval
        var netSeconds: TimeInterval
        var amountCents: Int
        var number: String?
        var id: Int64 { profile.id }
    }

    /// Every customer with hours in the invoiced month, or with an already issued
    /// invoice for it. The window lists these.
    func invoiceCandidates() -> [InvoiceCandidate] {
        guard let tracker else { return [] }
        let period = invoicePeriod
        var result: [InvoiceCandidate] = []
        for profile in (try? tracker.store.profiles()) ?? [] {
            let report = try? Reporting.report(
                store: tracker.store, period: .month, containing: period.start, profileId: profile.id
            )
            let number = try? tracker.store.issuedInvoiceNumber(profileId: profile.id, periodStart: period.start)
            let gross = report?.total ?? 0
            if gross <= 0 && number == nil { continue }
            let net = report?.netTotal ?? 0
            result.append(InvoiceCandidate(
                profile: profile,
                grossSeconds: gross,
                netSeconds: net,
                amountCents: profile.amountCents(for: net),
                number: number
            ))
        }
        return result.sorted { $0.profile.name.localizedCaseInsensitiveCompare($1.profile.name) == .orderedAscending }
    }

    /// Every invoice issued so far, for the history list.
    func issuedInvoices() -> [Store.IssuedInvoice] {
        (try? tracker?.store.issuedInvoices()) ?? []
    }

    /// Jumps the invoices window to the month the given date falls in.
    func showInvoiceMonth(_ date: Date) {
        invoicePeriod = Reporting.range(.month, containing: date)
    }

    /// Builds the invoice for one customer and the invoiced month. Allocates the
    /// number the first time and reuses it afterwards.
    func makeInvoice(profileId: Int64, poNumber: String?) -> Invoice? {
        makeInvoice(profileId: profileId, period: invoicePeriod, poNumber: poNumber)
    }

    /// The same, for any month: what the history list uses to rebuild an old one.
    func makeInvoice(profileId: Int64, period: DateRange, poNumber: String?) -> Invoice? {
        guard let tracker else { return nil }
        do {
            return try Invoicing.invoice(
                store: tracker.store, profileId: profileId, period: period, poNumber: poNumber
            )
        } catch {
            errorMessage = "\(error)"
            return nil
        }
    }

    func profile(id: Int64) -> Profile? {
        try? tracker?.store.profile(id: id)
    }

    func write(_ invoice: Invoice, to url: URL) -> Bool {
        do {
            try InvoicePDF.data(for: invoice).write(to: url)
            return true
        } catch {
            errorMessage = "Could not write the invoice: \(error)"
            return false
        }
    }

    /// Sends the invoice as a PDF attachment, optionally with the hour sheet CSV.
    /// Blocking SMTP runs off the main thread; the Keychain supplies the password.
    func sendInvoice(_ invoice: Invoice, to recipient: String, attachCSV: Bool) async throws {
        let settings = invoiceSettings()
        guard settings.canSendEmail else {
            throw SMTPError.configuration("Set the SMTP server and sender address under Invoice settings first.")
        }
        let password = Keychain.smtpPassword()
        guard !password.isEmpty else {
            throw SMTPError.configuration("No SMTP password stored. Add it under Invoice settings.")
        }
        let configuration = SMTPConfiguration(
            host: settings.smtpHost,
            port: settings.smtpPort,
            username: settings.smtpUsername,
            password: password,
            from: settings.smtpFromEmail,
            useTLS: settings.smtpUseTLS
        )
        var csv: Data?
        if attachCSV, let tracker {
            let text = try CSVExport.export(
                store: tracker.store, from: invoice.periodStart, to: invoice.periodEnd, profileId: invoice.profile.id
            )
            csv = Data(text.utf8)
        }
        let message = InvoiceEmail.message(
            for: invoice, to: recipient, pdf: InvoicePDF.data(for: invoice), csv: csv
        )
        try await Task.detached(priority: .userInitiated) {
            try SMTPClient.send(message, configuration: configuration)
        }.value
    }

    /// Sends a short message to yourself, to check the settings.
    func sendTestEmail(to recipient: String) async throws {
        let settings = invoiceSettings()
        guard settings.canSendEmail else {
            throw SMTPError.configuration("Set the SMTP server and sender address under Invoice settings first.")
        }
        let password = Keychain.smtpPassword()
        guard !password.isEmpty else {
            throw SMTPError.configuration("No SMTP password stored. Add it under Invoice settings.")
        }
        let configuration = SMTPConfiguration(
            host: settings.smtpHost,
            port: settings.smtpPort,
            username: settings.smtpUsername,
            password: password,
            from: settings.smtpFromEmail,
            useTLS: settings.smtpUseTLS
        )
        let message = EmailMessage(
            from: settings.smtpFromEmail,
            to: [recipient],
            subject: "Tickoala test message",
            body: "Your Tickoala email settings work.\r\n"
        )
        try await Task.detached(priority: .userInitiated) {
            try SMTPClient.send(message, configuration: configuration)
        }.value
    }

    func exportMonthlyCSV(profileId: Int64, to url: URL) -> Bool {
        exportMonthlyCSV(profileId: profileId, period: invoicePeriod, to: url)
    }

    func exportMonthlyCSV(profileId: Int64, period: DateRange, to url: URL) -> Bool {
        guard let tracker else { return false }
        do {
            let csv = try CSVExport.export(
                store: tracker.store, from: period.start, to: period.end, profileId: profileId
            )
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            errorMessage = "Could not export: \(error)"
            return false
        }
    }

    func invoiceSettings() -> InvoiceSettings {
        (try? tracker?.store.invoiceSettings()) ?? .default
    }

    func saveInvoiceSettings(_ settings: InvoiceSettings) {
        guard let tracker else { return }
        do {
            try tracker.store.updateInvoiceSettings(settings)
        } catch {
            errorMessage = "\(error)"
        }
    }

    func updateCustomerInvoicing(
        id: Int64,
        billingAddress: String,
        vatNumber: String,
        vatRatePercent: Int,
        poNumber: String,
        billingEmail: String
    ) {
        guard let tracker else { return }
        do {
            try tracker.store.updateProfileInvoicing(
                id: id, billingAddress: billingAddress, vatNumber: vatNumber,
                vatRatePercent: vatRatePercent, poNumber: poNumber, billingEmail: billingEmail
            )
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Once per month: on the first weekday, ask to invoice the month before.
    private func checkInvoiceReminder() {
        guard !shouldOpenInvoices, let tracker else { return }
        guard Invoicing.isReminderDue() else { return }
        let period = Invoicing.previousMonthRange(containing: Date())
        let key = "invoice-reminder-shown"
        if UserDefaults.standard.string(forKey: key) == Formatting.day(period.start) { return }
        UserDefaults.standard.set(Formatting.day(period.start), forKey: key)

        let profiles = (try? tracker.store.profiles()) ?? []
        let hasHours = profiles.contains { profile in
            guard let report = try? Reporting.report(
                store: tracker.store, period: .month, containing: period.start, profileId: profile.id
            ) else { return false }
            return report.total > 0
        }
        if hasHours {
            showPreviousInvoiceMonth()
            shouldOpenInvoices = true
        }
    }

    /// The label opened the window; no need to ask again.
    func acknowledgeInvoiceReminder() {
        shouldOpenInvoices = false
    }

    /// The Dock icon was clicked while a window was open: show Settings again.
    func requestSettingsWindow() {
        shouldOpenSettings = true
    }

    /// The label opened the window; no need to ask again.
    func acknowledgeSettingsWindow() {
        shouldOpenSettings = false
    }

    // MARK: - Undo

    /// A project or block change made from a window, with how to take it back and
    /// how to put it back. Only these are recorded; timer control and customer
    /// edits are not.
    private struct UndoStep {
        let title: String
        let perform: () -> Void
        let revert: () -> Void
    }

    private var undoStack: [UndoStep] = []
    private var redoStack: [UndoStep] = []

    /// Short name of what Cmd+Z would take back, for the menu.
    var undoTitle: String { undoStack.last?.title ?? "Undo" }
    /// Short name of what Shift+Cmd+Z would put back, for the menu.
    var redoTitle: String { redoStack.last?.title ?? "Redo" }

    private func record(_ title: String, perform: @escaping () -> Void, revert: @escaping () -> Void) {
        undoStack.append(UndoStep(title: title, perform: perform, revert: revert))
        // A new change makes the earlier redo history unreachable.
        redoStack.removeAll()
        // Keep the recent changes only; an unbounded stack is just memory.
        if undoStack.count > 50 { undoStack.removeFirst() }
        updateUndoAvailability()
    }

    /// Takes back the last project or block change.
    func undo() {
        guard let step = undoStack.popLast() else { return }
        step.perform()
        redoStack.append(step)
        updateUndoAvailability()
        refresh()
    }

    /// Puts back the last change that was taken back.
    func redo() {
        guard let step = redoStack.popLast() else { return }
        step.revert()
        undoStack.append(step)
        updateUndoAvailability()
        refresh()
    }

    private func updateUndoAvailability() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
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
