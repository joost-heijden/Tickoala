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

    /// Which customer the Customers window shows and where the Projects open.
    @Published var selectedCustomerId: Int64?

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
    @Published private(set) var overviewTotal: TimeInterval = 0
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

    /// Set on the first weekday of the month when there are hours to invoice; the
    /// menu bar label watches it and opens the invoices window once.
    @Published private(set) var shouldOpenInvoices = false

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
        var id: Int64 { entry.id }

        /// Gross amount of this block at the customer's rate; the break deduction
        /// appears as a separate row in the export, not here.
        var amountCents: Int {
            guard hourlyRateCents > 0 else { return 0 }
            return Int((entry.duration() / 3600 * Double(hourlyRateCents)).rounded())
        }
    }

    struct WifiProjectSelection: Equatable {
        var profileId: Int64
        var ssid: String
        var eventAt: Date
        var projects: [Project]
    }

    init() {
        do {
            tracker = Tracker(store: try Store(path: try Store.defaultDatabasePath()))
        } catch {
            errorMessage = "Cannot open the database: \(error)"
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
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

    /// Processes a network signal and remembers the outcome for the menu.
    private func handle(_ event: ContextEvent) {
        guard let tracker else { return }
        do {
            let outcome = try tracker.handle(event)
            lastWifiOutcome = "\(Formatting.clock(event.at))  \(event.context) \(event.kind.rawValue): \(outcome.summary)"

            switch outcome {
            case .needsProjectChoice(let profileId, let projectIds):
                let projects = projectIds.compactMap { try? tracker.store.project(id: $0) }
                if projects.count > 1 {
                    pendingWifiProjectSelection = WifiProjectSelection(
                        profileId: profileId,
                        ssid: event.context,
                        eventAt: event.at,
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
            _ = try tracker.start(profileId: selection.profileId, now: selection.eventAt, source: .wifi)
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
            try tracker.createProject(profileId: profileId, number: number, name: name)
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
            try tracker.store.updateProject(id: id, number: number, name: name)
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
            try tracker.store.updateProject(id: id, active: active)
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func activeProjectId(for profileId: Int64) -> Int64? {
        profiles.first(where: { $0.profile.id == profileId })?.project?.id
    }

    // MARK: - Control

    func selectProject(profileId: Int64, projectId: Int64) {
        if pendingWifiProjectSelection?.profileId == profileId {
            pendingWifiProjectSelection = nil
        }
        perform { try $0.selectProject(profileId: profileId, projectId: projectId) }
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
            overviewEntries = try entries.map { entry in
                let profile = try tracker.store.profile(id: entry.profileId)
                return EntryRow(
                    entry: entry,
                    profileName: profile?.name ?? "?",
                    projectLabel: try entry.projectId.flatMap { try tracker.store.project(id: $0) }?.label ?? "(no project)",
                    hourlyRateCents: profile?.hourlyRateCents ?? 0,
                    currency: profile?.currency ?? .eur
                )
            }
            overviewTotal = report.total
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

    func updateEntry(id: Int64, projectId: Int64?, start: Date, end: Date?, note: String, status: EntryStatus) {
        guard let tracker else { return }
        guard end == nil || end! >= start else {
            errorMessage = "The end is before the start."
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

    @discardableResult
    func addEntry(profileId: Int64, projectId: Int64?, start: Date, end: Date, note: String) -> Int64? {
        guard let tracker else { return nil }
        guard end > start else {
            errorMessage = "The end must be after the start."
            return nil
        }
        do {
            let entry = try tracker.store.createEntry(
                profileId: profileId, projectId: projectId, startedAt: start, endedAt: end,
                status: .completed, source: .manual, note: note.isEmpty ? nil : note
            )
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
            refresh()
            return duplicate.id
        } catch {
            errorMessage = "\(error)"
            return nil
        }
    }

    /// Cuts a block in two around a break and returns the new (second) block.
    @discardableResult
    func splitEntry(id: Int64, pauseStart: Date, pauseEnd: Date) -> Int64? {
        guard let tracker else { return nil }
        do {
            let second = try tracker.store.splitEntry(id: id, pauseStart: pauseStart, pauseEnd: pauseEnd)
            refresh()
            return second.id
        } catch {
            errorMessage = "\(error)"
            return nil
        }
    }

    @discardableResult
    func deleteEntry(id: Int64) -> Bool {
        guard let tracker else { return false }
        do {
            try tracker.store.deleteEntry(id: id)
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

    /// The month that just ended: what the reminder and the invoices window act on.
    var invoicePeriod: DateRange { Invoicing.previousMonthRange(containing: Date()) }

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

    /// Builds the invoice for one customer and the invoiced month. Allocates the
    /// number the first time and reuses it afterwards.
    func makeInvoice(profileId: Int64, poNumber: String?) -> Invoice? {
        guard let tracker else { return nil }
        do {
            return try Invoicing.invoice(
                store: tracker.store, profileId: profileId, period: invoicePeriod, poNumber: poNumber
            )
        } catch {
            errorMessage = "\(error)"
            return nil
        }
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

    /// Sends the invoice as a PDF attachment. Blocking SMTP runs off the main
    /// thread; the Keychain supplies the password.
    func sendInvoice(_ invoice: Invoice, to recipient: String) async throws {
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
        let message = InvoiceEmail.message(for: invoice, to: recipient, pdf: InvoicePDF.data(for: invoice))
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
        guard let tracker else { return false }
        do {
            let period = invoicePeriod
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
        let period = invoicePeriod
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
        if hasHours { shouldOpenInvoices = true }
    }

    /// The label opened the window; no need to ask again.
    func acknowledgeInvoiceReminder() {
        shouldOpenInvoices = false
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
