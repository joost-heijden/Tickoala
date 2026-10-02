import AppKit
import Combine
import CoreGraphics
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

    /// Gimmick: show the current month's revenue next to the menu bar icon. Off
    /// by default; the option lives in Settings.
    @Published var showEarningsInIcon = false {
        didSet {
            guard showEarningsInIcon != oldValue else { return }
            UserDefaults.standard.set(showEarningsInIcon, forKey: Self.showEarningsInIconKey)
        }
    }
    private static let showEarningsInIconKey = "menu-bar-earnings"

    /// Gimmick: show the current month's revenue per customer in the menu.
    @Published var showEarningsInMenu = false {
        didSet {
            guard showEarningsInMenu != oldValue else { return }
            UserDefaults.standard.set(showEarningsInMenu, forKey: Self.showEarningsInMenuKey)
        }
    }
    private static let showEarningsInMenuKey = "menu-earnings"

    /// End of the workday in minutes since midnight. A block that gets no signal
    /// (the Mac slept, the app was closed) is closed here rather than running on.
    @Published var workdayEndMinutes = TrackerSettings.default.workdayEndMinutes {
        didSet {
            guard workdayEndMinutes != oldValue else { return }
            persistSetting(key: "workday-end-minutes", value: workdayEndMinutes)
        }
    }

    /// Start of the workday in minutes since midnight. Automatic check-ins within
    /// half an hour of it are recorded as this time.
    @Published var workdayStartMinutes = TrackerSettings.default.workdayStartMinutes {
        didSet {
            guard workdayStartMinutes != oldValue else { return }
            persistSetting(key: "workday-start-minutes", value: workdayStartMinutes)
        }
    }

    /// When an automatic start at a client asks which project to work on.
    @Published var projectPrompt = TrackerSettings.default.projectPrompt {
        didSet {
            guard projectPrompt != oldValue else { return }
            persistSetting(key: "project-prompt", value: projectPrompt.rawValue)
        }
    }

    /// Warn once when a project's hour budget reaches 80% and once at 100%. Off
    /// by default: a budget on its own only shows the burn-down, this adds a
    /// notification, so setting a budget never forces a warning on you.
    @Published var showBudgetWarnings = TrackerSettings.default.budgetWarningsEnabled {
        didSet {
            guard showBudgetWarnings != oldValue else { return }
            persistSetting(key: "budget-warnings", value: showBudgetWarnings ? 1 : 0)
        }
    }

    /// Minutes without keyboard or mouse input before Tickoala treats the return
    /// as a question: discard that time or keep it? Zero turns the check off.
    @Published var idleThresholdMinutes = TrackerSettings.default.idleThresholdMinutes {
        didSet {
            guard idleThresholdMinutes != oldValue else { return }
            persistSetting(key: "idle-threshold-minutes", value: idleThresholdMinutes)
            idleStartedAt = nil
        }
    }

    /// Whether tags are shown and editable. Off by default; the tag field,
    /// overview column, tag breakdown and filter stay hidden until it is on.
    @Published var tagsEnabled = TrackerSettings.default.tagsEnabled {
        didSet {
            guard tagsEnabled != oldValue else { return }
            persistSetting(key: "tags-enabled", value: tagsEnabled ? 1 : 0)
            if !tagsEnabled { tagFilter = nil }
        }
    }

    /// The tag the overview is filtered on, or `nil` for all blocks. Only used
    /// when tags are enabled.
    @Published var tagFilter: String?

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
    /// The calendar day the anchor was last on while it followed "today". The
    /// overview has to move along when the clock passes midnight, otherwise it
    /// keeps showing yesterday while the week totals already include today.
    private var anchorDay = Formatting.calendar.startOfDay(for: Date())
    @Published private(set) var overviewEntries: [EntryRow] = []
    /// Net hours of the shown period, after the automatic break deduction.
    @Published private(set) var overviewTotal: TimeInterval = 0
    /// The automatic break deduction over the shown period, so the overview can
    /// show why the total is lower than the sum of the blocks.
    @Published private(set) var overviewBreak: TimeInterval = 0
    @Published private(set) var overviewByProject: [ProjectTotal] = []
    @Published private(set) var overviewByProfile: [ProfileTotal] = []
    @Published private(set) var overviewByTag: [ProjectTotal] = []
    /// Net hours per day, for the chart. Each day carries its per-project split,
    /// so the chart can show one total bar per day or a stacked one.
    @Published private(set) var overviewByDayProject: [DayProjectTotal] = []
    @Published private(set) var overviewAmountCents: Int = 0

    /// Burn-down per project that has a budget, keyed by project id. Empty when
    /// no budget is set anywhere, so the feature is invisible by default.
    @Published private(set) var projectBudgets: [Int64: ProjectBudget] = [:]
    /// Set when a project crosses the 80% or 100% threshold; the app delegate
    /// turns it into a notification. Only assigned on a fresh crossing.
    @Published private(set) var budgetAlert: BudgetAlert?
    @Published private(set) var nonWorkingDays: [NonWorkingDay] = []

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

    /// A stretch of idle time on a running block that the user has to rule on:
    /// discard it from the block or keep it. Nothing is changed until answered.
    @Published private(set) var pendingIdle: PendingIdle?
    /// When the current stretch of being away began; cleared on return.
    private var idleStartedAt: Date?

    /// Set on the first weekday of the month when there are hours to invoice; the
    /// menu bar label watches it and opens the invoices window once.
    @Published private(set) var shouldOpenInvoices = false

    /// Set when the Dock icon is clicked while the app runs; the menu bar label
    /// watches it and brings the Settings window up once.
    @Published private(set) var shouldOpenSettings = false

    /// Set once a day when an invoice has passed its due date; the app delegate
    /// turns it into a notification.
    @Published private(set) var overdueAlert: OverdueAlert?

    private var tracker: Tracker?
    private var timer: Timer?
    private var wifiObserver: AnyCancellable?
    private var updateObserver: AnyCancellable?
    private var loginObserver: AnyCancellable?
    private var wakeObserver: AnyCancellable?

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

    /// One day's hours for one project, the unit the chart plots.
    struct DayProjectTotal: Identifiable, Equatable {
        var day: Date
        var project: String
        var seconds: TimeInterval
        var id: String { "\(day.timeIntervalSince1970)-\(project)" }
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

    /// A stretch of idle time on a running block, waiting for the user to say
    /// whether it counts as work.
    struct PendingIdle: Equatable {
        var entryId: Int64
        var profileId: Int64
        var startedAt: Date
        var endedAt: Date
        var seconds: TimeInterval
    }

    /// An unpaid invoice that has passed its due date, announced once a day.
    struct OverdueAlert: Equatable {
        var count: Int
        var oldestNumber: String
        var customerName: String
        var daysLate: Int

        var body: String {
            let days = daysLate == 1 ? "1 day" : "\(daysLate) days"
            if count == 1 {
                return "Invoice \(oldestNumber) for \(customerName) is \(days) overdue."
            }
            return "\(count) invoices are unpaid; the oldest, \(oldestNumber) for \(customerName), is \(days) overdue."
        }
    }

    /// A project that just crossed its 80% or 100% budget threshold.
    struct BudgetAlert: Equatable {
        var profileId: Int64
        var projectLabel: String
        var customerName: String
        var level: ProjectBudget.Level
        var budgetSeconds: TimeInterval
        var usedSeconds: TimeInterval

        var title: String {
            level == .exceeded ? "Project budget reached" : "Project budget at 80%"
        }

        var body: String {
            let used = Formatting.duration(usedSeconds)
            let total = Formatting.duration(budgetSeconds)
            let tail = level == .exceeded ? "Over budget." : "\(Formatting.duration(max(0, budgetSeconds - usedSeconds))) left."
            return "\(customerName) · \(projectLabel): \(used) of \(total) used. \(tail)"
        }
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

        // Both revenue gimmicks are off unless the user ticked them in Settings.
        showEarningsInIcon = UserDefaults.standard.bool(forKey: Self.showEarningsInIconKey)
        showEarningsInMenu = UserDefaults.standard.bool(forKey: Self.showEarningsInMenuKey)
        // Restore the workday end from the database.
        if let settings = try? tracker?.store.settings() {
            workdayEndMinutes = settings.workdayEndMinutes
            workdayStartMinutes = settings.workdayStartMinutes
            projectPrompt = settings.projectPrompt
            showBudgetWarnings = settings.budgetWarningsEnabled
            idleThresholdMinutes = settings.idleThresholdMinutes
            tagsEnabled = settings.tagsEnabled
        }
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
        // After the Mac wakes from sleep the network often did not change, so the
        // watcher's poll sees nothing new. Re-evaluate it so a wake at a client
        // can still ask which project to work on.
        wakeObserver = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.handleWake() }
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

    /// Stores a setting in the database, so the tracker reads the same value.
    private func persistSetting(key: String, value: Int) {
        guard let tracker else { return }
        do {
            try tracker.store.setSetting(key: key, value: value)
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// After the Mac wakes from sleep: re-check the network. Only relevant when
    /// Tickoala is set to ask for a project; otherwise waking must not restart
    /// tracking by itself.
    private func handleWake() {
        guard projectPrompt != .never else { return }
        wifi.recheckAfterWake()
    }

    /// Processes a network signal. A start on another network while a block runs
    /// is not applied silently: the user first chooses continue or start new.
    private func handle(_ event: ContextEvent) {
        guard let tracker else { return }
        // A block left running past the workday end (Mac slept, app closed) is
        // closed first, so a morning arrival starts fresh instead of asking whether
        // the block from yesterday should continue.
        _ = try? tracker.closeBlocksPastWorkday()
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

    /// Stop the current block after a network change, without starting a new one.
    func stopAfterNetworkSwitch() {
        guard let pending = pendingNetworkSwitch else { return }
        pendingNetworkSwitch = nil
        perform { try $0.stop(profileId: pending.runningProfileId) }
    }

    /// A location context (`geo:<id>`) shows the customer's name instead.
    func displayContext(_ context: String) -> String {
        guard context.hasPrefix("geo:"), let id = Int64(context.dropFirst(4)) else { return context }
        return (try? tracker?.store.profile(id: id))?.name ?? context
    }

    var profiles: [ProfileStatus] { status?.profiles ?? [] }

    var menuBarTitle: String { status?.menuBarTitle ?? "–" }

    var menuBarSymbol: String { (status?.mode ?? .stopped).symbol }

    /// The month revenue to show next to the icon, `nil` when the option is off
    /// or there is nothing to show. It grows every second while a block runs,
    /// because each `refresh()` measures the running block up to now.
    var menuBarEarnings: String? {
        guard showEarningsInIcon, let primary = status?.primary else { return nil }
        return Formatting.money(cents: primary.monthAmountCents, currency: primary.profile.currency)
    }

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
            // The same for an idle question whose block is gone.
            if let pending = pendingIdle, (try? tracker.store.entry(id: pending.entryId)) == nil {
                pendingIdle = nil
            }
            var active: [Int64: [Project]] = [:]
            var all: [Int64: [Project]] = [:]
            for item in try tracker.store.profiles(includeInactive: false) {
                active[item.id] = try tracker.store.projects(profileId: item.id, includeInactive: false)
                all[item.id] = try tracker.store.projects(profileId: item.id, includeInactive: true)
            }
            projectsPerProfile = active
            allProjectsPerProfile = all
            reloadBudgets()
            nonWorkingDays = try tracker.store.nonWorkingDays()
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
        monitorIdle()
        ensureSelectedCustomer()
        followTodayIfNeeded()
        reloadOverview()
        checkInvoiceReminder()
        checkOverdueReminder()
    }

    /// Watches how long the Mac has had no keyboard or mouse input. While a block
    /// runs and the idle time passes the threshold, the moment the user returns is
    /// turned into a question: discard that stretch or keep it. Nothing is changed
    /// until the user answers, so the raw block always stays intact.
    private func monitorIdle(now: Date = Date()) {
        guard idleThresholdMinutes > 0, let tracker else {
            idleStartedAt = nil
            return
        }
        // No running block means there is nothing to ask about.
        guard let running = try? tracker.store.runningEntries().first else {
            idleStartedAt = nil
            return
        }
        // One open question at a time.
        guard pendingIdle == nil else { return }

        let idle = Self.systemIdleSeconds()
        let threshold = TimeInterval(idleThresholdMinutes * 60)
        if idle >= threshold {
            // Remember where the absence began; the block keeps counting until
            // the user has answered.
            if idleStartedAt == nil { idleStartedAt = now.addingTimeInterval(-idle) }
            return
        }
        // Input is back: close the idle stretch and ask about it.
        guard let started = idleStartedAt else { return }
        idleStartedAt = nil
        let ended = now.addingTimeInterval(-idle)
        let seconds = max(0, ended.timeIntervalSince(started))
        guard seconds >= threshold else { return }
        pendingIdle = PendingIdle(
            entryId: running.id,
            profileId: running.profileId,
            startedAt: started,
            endedAt: ended,
            seconds: seconds
        )
    }

    /// Seconds since the last keyboard or mouse input, read from the system. This
    /// needs no permission and nothing leaves the Mac.
    private static func systemIdleSeconds() -> TimeInterval {
        let anyInput = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    /// The idle stretch counts as work; nothing is changed.
    func keepIdleTime() {
        pendingIdle = nil
    }

    /// Takes the idle stretch off the block. The block keeps its start and end;
    /// only the worked duration drops, exactly like a break.
    func discardIdleTime() {
        guard let pending = pendingIdle else { return }
        pendingIdle = nil
        perform { try $0.addIdle(entryId: pending.entryId, seconds: pending.seconds) }
    }

    /// A pending coalesced refresh, so typing or a held stepper does not reload
    /// every profile, project and overview row on every single change. The store
    /// write still happens at once; only this heavier read-back is delayed.
    private var pendingRefresh: Task<Void, Never>?

    private func refreshSoon() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// Advances the overview anchor when the day has rolled over and the anchor
    /// was still on the day the app started; a day the user chose stays.
    private func followTodayIfNeeded() {
        let now = Date()
        let today = Formatting.calendar.startOfDay(for: now)
        guard today != anchorDay else { return }
        if Reporting.shouldFollowToday(anchor: anchor, lastDay: anchorDay, now: now) {
            anchor = now
        }
        anchorDay = today
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
            refreshSoon()
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
    func addCustomer(
        name: String,
        contexts: [String],
        hourlyRateCents: Int,
        currency: Currency,
        billingAddress: String = "",
        vatNumber: String = ""
    ) -> Bool {
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
                name: name, contexts: cleaned, hourlyRateCents: hourlyRateCents, currency: currency,
                vatRatePercent: invoiceSettings().defaultVatRatePercent
            )
            try tracker.store.updateProfileInvoicing(
                id: profile.id, billingAddress: billingAddress, vatNumber: vatNumber,
                vatRatePercent: invoiceSettings().defaultVatRatePercent, poNumber: ""
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
            refreshSoon()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func updateBillingRules(profileId: Int64, rules: BillingRules) {
        guard let tracker else { return }
        do {
            try tracker.store.updateBillingRules(profileId: profileId, rules: rules)
            refreshSoon()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func updateCustomerTravelRates(id: Int64, travelRateCents: Int, commuteRateCents: Int) {
        guard let tracker else { return }
        do {
            try tracker.store.updateProfile(
                id: id, travelRateCents: travelRateCents, commuteRateCents: commuteRateCents
            )
            refreshSoon()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func retainer(for profileId: Int64) -> Retainer? {
        try? tracker?.store.retainer(profileId: profileId)
    }

    func addNonWorkingDay(_ date: Date, label: String, kind: NonWorkingKind) {
        guard let tracker else { return }
        do {
            try tracker.store.addNonWorkingDay(date, label: label, kind: kind)
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func removeNonWorkingDay(_ date: Date) {
        guard let tracker else { return }
        do {
            try tracker.store.deleteNonWorkingDay(date)
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func setRetainer(
        profileId: Int64,
        description: String,
        amountCents: Int,
        active: Bool,
        endsAt: Date? = nil,
        recurrence: RetainerRecurrence = .monthly
    ) {
        guard let tracker else { return }
        do {
            try tracker.store.setRetainer(
                profileId: profileId,
                description: description,
                amountCents: amountCents,
                active: active,
                endsAt: endsAt,
                recurrence: recurrence
            )
            refreshSoon()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func clearRetainer(profileId: Int64) {
        guard let tracker else { return }
        do {
            try tracker.store.clearRetainer(profileId: profileId)
            refreshSoon()
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
    func addProject(profileId: Int64, number: String, name: String, budgetMinutes: Int = 0) -> Bool {
        guard let tracker else { return false }
        let number = number.trimmingCharacters(in: .whitespaces)
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !number.isEmpty, !name.isEmpty else {
            errorMessage = "Enter both a project number and a project name."
            return false
        }
        do {
            let previousActive = (try? tracker.store.state(profileId: profileId))?.activeProjectId
            let project = try tracker.createProject(
                profileId: profileId, number: number, name: name, budgetMinutes: max(0, budgetMinutes)
            )
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
                    _ = try? self?.tracker?.createProject(
                        profileId: profileId, number: number, name: name, budgetMinutes: max(0, budgetMinutes)
                    )
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
            refreshSoon()
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
                              profileId: project.profileId, number: project.number, name: project.name,
                              budgetMinutes: project.budgetMinutes
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

    // MARK: - Project budgets

    /// The burn-down of a project with a budget; `nil` when it has none.
    func budget(for projectId: Int64) -> ProjectBudget? { projectBudgets[projectId] }

    /// The projects of a customer that carry a budget, for the menu.
    func budgetedProjects(for profileId: Int64) -> [Project] {
        allProjects(for: profileId).filter { $0.hasBudget }
    }

    /// Sets or clears a project's hour budget; 0 clears it. Changing the budget
    /// re-arms the warnings, because the thresholds moved.
    func setProjectBudget(id: Int64, minutes: Int) {
        guard let tracker else { return }
        let value = max(0, minutes)
        do {
            let previous = try? tracker.store.project(id: id)
            try tracker.store.updateProject(id: id, budgetMinutes: value)
            UserDefaults.standard.removeObject(forKey: Self.budgetWarnedKey(id))
            if let previous, previous.budgetMinutes != value {
                record("Change budget",
                    perform: { [weak self] in
                        try? self?.tracker?.store.updateProject(id: id, budgetMinutes: previous.budgetMinutes)
                        UserDefaults.standard.removeObject(forKey: Self.budgetWarnedKey(id))
                    },
                    revert: { [weak self] in
                        try? self?.tracker?.store.updateProject(id: id, budgetMinutes: value)
                        UserDefaults.standard.removeObject(forKey: Self.budgetWarnedKey(id))
                    })
            }
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: - Expenses and mileage

    /// All expenses of a customer, for the management window.
    func expenses(for profileId: Int64) -> [Expense] {
        (try? tracker?.store.expenses(profileId: profileId)) ?? []
    }

    /// Net cents of the billable expenses of a customer within a window, so the
    /// invoices window can show what will be added on top of the hours.
    func expenseTotalCents(for profileId: Int64, in range: DateRange) -> Int {
        ((try? tracker?.store.expenses(profileId: profileId, from: range.start, to: range.end)) ?? [])
            .filter { $0.billable }
            .reduce(0) { $0 + $1.amountCents }
    }

    func setCustomerKmRate(id: Int64, cents: Int) {
        guard let tracker else { return }
        do {
            try tracker.store.updateProfile(id: id, kmRateCents: max(0, cents))
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Adds an expense or mileage claim. The amount of a mileage claim is worked
    /// out here; a plain expense stores the amount as both amount and unit rate so
    /// the invoice can show `1 × €12.50`.
    @discardableResult
    func addExpense(
        profileId: Int64,
        date: Date,
        description: String,
        kind: ExpenseKind,
        quantity: Double,
        unitRateCents: Int,
        amountCents: Int,
        billable: Bool,
        note: String
    ) -> Bool {
        guard let tracker else { return false }
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            errorMessage = "Enter a description for the expense."
            return false
        }
        let values = normalizedExpense(kind: kind, quantity: quantity, unitRateCents: unitRateCents, amountCents: amountCents)
        guard values.amountCents > 0 else {
            errorMessage = "The amount must be greater than zero."
            return false
        }
        do {
            _ = try tracker.store.createExpense(
                profileId: profileId,
                date: Formatting.calendar.startOfDay(for: date),
                description: description,
                kind: kind,
                quantity: values.quantity,
                unitRateCents: values.unitRateCents,
                amountCents: values.amountCents,
                billable: billable,
                note: note.isEmpty ? nil : note
            )
            refresh()
            return true
        } catch {
            errorMessage = "\(error)"
            return false
        }
    }

    func updateExpense(
        id: Int64,
        date: Date,
        description: String,
        kind: ExpenseKind,
        quantity: Double,
        unitRateCents: Int,
        amountCents: Int,
        billable: Bool,
        note: String
    ) {
        guard let tracker else { return }
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            errorMessage = "Enter a description for the expense."
            return
        }
        let values = normalizedExpense(kind: kind, quantity: quantity, unitRateCents: unitRateCents, amountCents: amountCents)
        do {
            try tracker.store.updateExpense(
                id: id,
                date: Formatting.calendar.startOfDay(for: date),
                description: description,
                kind: kind,
                quantity: values.quantity,
                unitRateCents: values.unitRateCents,
                amountCents: values.amountCents,
                billable: billable,
                note: .some(note.isEmpty ? nil : note)
            )
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func deleteExpense(id: Int64) {
        guard let tracker else { return }
        do {
            try tracker.store.deleteExpense(id: id)
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func normalizedExpense(
        kind: ExpenseKind,
        quantity: Double,
        unitRateCents: Int,
        amountCents: Int
    ) -> (quantity: Double, unitRateCents: Int, amountCents: Int) {
        switch kind {
        case .mileage:
            let kilometres = max(0, quantity)
            let rate = max(0, unitRateCents)
            return (kilometres, rate, Expense.mileageAmountCents(kilometres: kilometres, rateCentsPerKm: rate))
        case .expense:
            let amount = max(0, amountCents)
            return (1, amount, amount)
        }
    }

    private static func budgetWarnedKey(_ projectId: Int64) -> String { "budget-warned-\(projectId)" }

    /// Recomputes the burn-down of every budgeted project and raises a warning on
    /// a fresh threshold crossing. The highest warned level is remembered per
    /// project, so a warning is not repeated every tick or after a restart.
    private func reloadBudgets() {
        guard let tracker else { return }
        let usage = (try? tracker.store.projectUsageSeconds()) ?? [:]
        let defaults = UserDefaults.standard
        var budgets: [Int64: ProjectBudget] = [:]
        for projects in allProjectsPerProfile.values {
            for project in projects where project.hasBudget {
                let budget = ProjectBudget(budgetSeconds: project.budgetSeconds, usedSeconds: usage[project.id] ?? 0)
                budgets[project.id] = budget
                guard showBudgetWarnings else { continue }
                let key = Self.budgetWarnedKey(project.id)
                let previous = ProjectBudget.Level(rawValue: defaults.integer(forKey: key)) ?? .none
                guard let crossed = budget.crossedLevel(above: previous) else { continue }
                defaults.set(crossed.rawValue, forKey: key)
                let customer = profiles.first { $0.profile.id == project.profileId }?.profile.name ?? ""
                budgetAlert = BudgetAlert(
                    profileId: project.profileId,
                    projectLabel: project.label,
                    customerName: customer,
                    level: crossed,
                    budgetSeconds: budget.budgetSeconds,
                    usedSeconds: budget.usedSeconds
                )
            }
        }
        projectBudgets = budgets
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
            var entries = try tracker.store.entries(from: report.range.start, to: report.range.end, profileId: profileFilter)
            // The tag filter narrows the table and the footer totals only; the
            // tag breakdown keeps every tag, so the filter stays switchable.
            if tagsEnabled, let tagFilter {
                entries = entries.filter { entry in
                    entry.tags.contains { $0.caseInsensitiveCompare(tagFilter) == .orderedSame }
                }
            }
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
                let base = try entry.projectId.flatMap { try tracker.store.project(id: $0) }?.label ?? "(no project)"
                let projectLabel = entry.kind == .work ? base : "\(base) · \(entry.kind.label)"
                return EntryRow(
                    entry: entry,
                    profileName: profile?.name ?? "?",
                    projectLabel: projectLabel,
                    hourlyRateCents: profile?.rateCents(for: entry.kind) ?? 0,
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
            overviewByTag = report.byTag
            overviewAmountCents = report.amountCents
            overviewByDayProject = try chartRows(store: tracker.store, report: report, entries: entries)
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// The per-day, per-project hours the chart plots. Built from the same
    /// entries the table shows, so a tag or customer filter is reflected here too.
    private func chartRows(
        store: Store,
        report: Report,
        entries: [TimeEntry]
    ) throws -> [DayProjectTotal] {
        let calendar = Formatting.calendar
        var projectCache: [Int64: String] = [:]
        var grouped: [Date: [String: TimeInterval]] = [:]
        for entry in entries {
            guard entry.kind == .work else { continue }
            let day = calendar.startOfDay(for: entry.startedAt)
            let label: String
            if let projectId = entry.projectId {
                if let cached = projectCache[projectId] {
                    label = cached
                } else {
                    let project = try store.project(id: projectId)
                    label = project?.label ?? "(no project)"
                    projectCache[projectId] = label
                }
            } else {
                label = "(no project)"
            }
            grouped[day, default: [:]][label, default: 0] += entry.duration()
        }
        return grouped
            .flatMap { day, projects in
                projects.map { DayProjectTotal(day: day, project: $0.key, seconds: $0.value) }
            }
            .sorted { ($0.day, $0.project) < ($1.day, $1.project) }
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
        tags: [String]? = nil,
        status: EntryStatus,
        kind: EntryKind = .work
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
                tags: tags,
                status: status,
                kind: kind,
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
                            tags: previous.tags,
                            status: previous.status,
                            kind: previous.kind,
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
                            tags: tags,
                            status: status,
                            kind: kind,
                            note: .some(note.isEmpty ? nil : note)
                        )
                    })
            }
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Moves a block on the timeline: start and end shift together, break included.
    func shiftEntry(id: Int64, minutes: Int) {
        guard minutes != 0, let tracker, let entry = try? tracker.store.entry(id: id) else { return }
        let delta = TimeInterval(minutes * 60)
        updateEntry(
            id: id, projectId: entry.projectId,
            start: entry.startedAt.addingTimeInterval(delta),
            end: entry.endedAt?.addingTimeInterval(delta),
            breakStart: entry.breakStartedAt?.addingTimeInterval(delta),
            breakEnd: entry.breakEndedAt?.addingTimeInterval(delta),
            note: entry.note ?? "", status: entry.status, kind: entry.kind
        )
    }

    /// Changes the end of a block on the timeline, for dragging its right edge.
    func resizeEntryEnd(id: Int64, minutes: Int) {
        guard minutes != 0, let tracker, let entry = try? tracker.store.entry(id: id), let currentEnd = entry.endedAt else {
            return
        }
        let delta = TimeInterval(minutes * 60)
        let lowest = max(entry.startedAt.addingTimeInterval(60), entry.breakEndedAt ?? entry.startedAt)
        let newEnd = max(lowest, currentEnd.addingTimeInterval(delta))
        updateEntry(
            id: id, projectId: entry.projectId,
            start: entry.startedAt, end: newEnd,
            breakStart: entry.breakStartedAt, breakEnd: entry.breakEndedAt,
            note: entry.note ?? "", status: entry.status, kind: entry.kind
        )
    }

    @discardableResult
    func addEntry(
        profileId: Int64,
        projectId: Int64?,
        start: Date,
        end: Date,
        breakStart: Date? = nil,
        breakEnd: Date? = nil,
        note: String,
        tags: [String] = [],
        kind: EntryKind = .work
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
                tags: tags, status: .completed, source: .manual, kind: kind, note: note.isEmpty ? nil : note
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
                        tags: entry.tags,
                        status: entry.status,
                        source: entry.source,
                        kind: entry.kind,
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
                            idleSeconds: previous.idleSeconds,
                            tags: previous.tags,
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

    /// Whether one invoice covers a month, a week or two weeks.
    @Published var invoicePeriodKind: InvoicePeriodKind = .month

    /// Moves the invoices window one period forward or back.
    func shiftInvoicePeriod(_ direction: Int) {
        invoicePeriod = invoicePeriodKind.shifted(direction, from: invoicePeriod.start)
    }

    /// Switches the invoice length, keeping the same starting day.
    func setInvoicePeriodKind(_ kind: InvoicePeriodKind) {
        invoicePeriodKind = kind
        invoicePeriod = kind.range(containing: invoicePeriod.start)
    }

    /// The month that just ended: what the automatic reminder opens.
    func showPreviousInvoiceMonth() {
        invoicePeriodKind = .month
        invoicePeriod = Invoicing.previousMonthRange(containing: Date())
    }

    /// The period we are in now: the starting point when the window is opened by
    /// hand, so the hours booked so far can be invoiced right away. Keeps the
    /// chosen length (month, week or two weeks).
    func showCurrentInvoicePeriod() {
        invoicePeriod = invoicePeriodKind.range(containing: Date())
    }

    struct InvoiceCandidate: Identifiable {
        var profile: Profile
        var grossSeconds: TimeInterval
        var netSeconds: TimeInterval
        var expensesCents: Int = 0
        var amountCents: Int
        var number: String?
        var id: Int64 { profile.id }
    }

    /// Every customer with hours in the invoiced period, or with an already issued
    /// invoice for it. The window lists these.
    func invoiceCandidates() -> [InvoiceCandidate] {
        guard let tracker else { return [] }
        let period = invoicePeriod
        var result: [InvoiceCandidate] = []
        for profile in (try? tracker.store.profiles()) ?? [] {
            let report = try? Reporting.report(
                store: tracker.store, range: period, profileId: profile.id
            )
            let number = try? tracker.store.issuedInvoiceNumber(profileId: profile.id, periodStart: period.start)
            let gross = report?.total ?? 0
            let expenses = (try? tracker.store.expenses(profileId: profile.id, from: period.start, to: period.end)) ?? []
            let expenseCents = expenses.filter { $0.billable }.reduce(0) { $0 + $1.amountCents }
            if gross <= 0 && number == nil && expenseCents == 0 { continue }
            let net = report?.netTotal ?? 0
            result.append(InvoiceCandidate(
                profile: profile,
                grossSeconds: gross,
                netSeconds: net,
                expensesCents: expenseCents,
                amountCents: profile.amountCents(for: net) + expenseCents,
                number: number
            ))
        }
        return result.sorted { $0.profile.name.localizedCaseInsensitiveCompare($1.profile.name) == .orderedAscending }
    }

    /// Every invoice issued so far, for the history list.
    func issuedInvoices() -> [Store.IssuedInvoice] {
        (try? tracker?.store.issuedInvoices()) ?? []
    }

    /// Jumps the invoices window to the period a stored invoice covers.
    func showInvoicePeriod(_ range: DateRange) {
        invoicePeriodKind = InvoicePeriodKind.matching(start: range.start, end: range.end)
        invoicePeriod = range
    }

    /// Removes one invoice from the history. The hours remain.
    func deleteInvoice(_ invoice: Store.IssuedInvoice) {
        guard let tracker else { return }
        do {
            try tracker.store.deleteInvoice(number: invoice.number)
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Records that an invoice was paid, or reopens it again.
    func setInvoicePaid(_ invoice: Store.IssuedInvoice, paid: Bool) {
        guard let tracker else { return }
        do {
            try tracker.store.setInvoicePaid(number: invoice.number, paidAt: paid ? Date() : nil)
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Issued invoices that are still open: not paid, not a credit note and with
    /// something to pay.
    var outstandingInvoices: [Store.IssuedInvoice] {
        issuedInvoices().filter { !$0.isCredit && !$0.isPaid && $0.totalCents > 0 }
    }

    /// Open invoices that are past their due date.
    var overdueInvoices: [Store.IssuedInvoice] {
        outstandingInvoices.filter { $0.isOverdue() }
    }

    /// The open amount per currency. Several currencies are kept apart, since
    /// they cannot be added up into one figure.
    var outstandingTotals: [(currency: Currency, cents: Int)] {
        var totals: [Currency: Int] = [:]
        for invoice in outstandingInvoices { totals[invoice.currency, default: 0] += invoice.totalCents }
        return totals.map { ($0.key, $0.value) }.sorted { $0.cents > $1.cents }
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

    /// Creates the credit note that reverses an issued invoice, with its own
    /// number and a reference to the original.
    func makeCredit(originalNumber: String) -> Invoice? {
        guard let tracker else { return nil }
        do {
            return try Invoicing.credit(store: tracker.store, originalNumber: originalNumber)
        } catch {
            errorMessage = "\(error)"
            return nil
        }
    }

    /// Rebuilds a stored credit note for its PDF or UBL export.
    func makeCredit(_ credit: Store.IssuedInvoice) -> Invoice? {
        guard let tracker else { return nil }
        do {
            return try Invoicing.restoredCredit(store: tracker.store, credit: credit)
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

    /// Writes the UBL/Peppol XML for the invoice, for import in bookkeeping.
    func writeUBL(_ invoice: Invoice, to url: URL) -> Bool {
        do {
            try UBLExport.data(for: invoice).write(to: url)
            return true
        } catch {
            errorMessage = "Could not write the UBL file: \(error)"
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
            for: invoice, to: recipient, pdf: InvoicePDF.data(for: invoice),
            csv: csv, includeUBL: settings.attachUBL
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

    /// The quarterly VAT return for the given period, or `nil` on a read error.
    func vatReport(for period: VATPeriod) -> VATReport? {
        guard let tracker else { return nil }
        return try? VAT.report(store: tracker.store, period: period)
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
        billingEmail: String,
        billingCc: String
    ) {
        guard let tracker else { return }
        do {
            try tracker.store.updateProfileInvoicing(
                id: id, billingAddress: billingAddress, vatNumber: vatNumber,
                vatRatePercent: vatRatePercent, poNumber: poNumber,
                billingEmail: billingEmail, billingCc: billingCc
            )
            refreshSoon()
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

    /// Once a day, announce the oldest invoice that is past its due date. The
    /// day is remembered, so it is a nudge and not a nag; marking the invoice
    /// paid clears it.
    private func checkOverdueReminder() {
        let overdue = overdueInvoices
        guard let oldest = overdue.max(by: { $0.daysLate() < $1.daysLate() }) else {
            if overdueAlert != nil { overdueAlert = nil }
            return
        }
        let key = "overdue-reminder-shown"
        let today = Formatting.day(Date())
        guard UserDefaults.standard.string(forKey: key) != today else { return }
        UserDefaults.standard.set(today, forKey: key)
        overdueAlert = OverdueAlert(
            count: overdue.count,
            oldestNumber: oldest.number,
            customerName: oldest.profileName,
            daysLate: oldest.daysLate()
        )
    }

    // MARK: - Import

    /// Opens a file picker and imports a Toggl Track, Harvest or Clockify CSV
    /// export. The picker carries the format and an optional client override; the
    /// result is shown in an alert. Running it twice skips what is already there.
    func importEntriesPanel() {
        guard let tracker else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the CSV you exported from your old time tracker"

        let formatPopup = NSPopUpButton()
        for format in ImportFormat.allCases { formatPopup.addItem(withTitle: format.label) }
        formatPopup.selectItem(at: 0)
        let clientField = NSTextField(string: "")
        clientField.placeholderString = "use the file's client column"
        clientField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let userField = NSTextField(string: "")
        userField.placeholderString = "everyone in the file"
        userField.widthAnchor.constraint(equalToConstant: 130).isActive = true

        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Format:"), formatPopup,
            NSTextField(labelWithString: "Client:"), clientField,
            NSTextField(labelWithString: "User:"), userField,
        ])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        panel.accessoryView = stack

        NSApp.activateForUI()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let index = max(0, min(formatPopup.indexOfSelectedItem, ImportFormat.allCases.count - 1))
        let format = ImportFormat.allCases[index]
        let override = clientField.stringValue.trimmingCharacters(in: .whitespaces)
        let user = userField.stringValue.trimmingCharacters(in: .whitespaces)

        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            var entries = try Importer.parse(text, format: format, user: user)
            if !override.isEmpty {
                entries = entries.map { var entry = $0; entry.client = override; return entry }
            }
            let summary = try Importer.apply(
                entries, to: tracker.store, tagsEnabled: tagsEnabled
            )
            refresh()
            presentAlert(title: "Import complete", message: "\(format.label): \(summary.description).")
        } catch {
            errorMessage = "\(error)"
            presentAlert(title: "Import failed", message: "\(error)")
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
