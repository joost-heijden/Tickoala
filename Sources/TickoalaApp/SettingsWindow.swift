import AppKit
import SwiftUI
import TickoalaCore

/// Everything that is configured once and rarely changed, in one window: start at
/// login, presence detection, breaks, invoices and updates. The menu keeps the
/// daily work.
struct SettingsWindow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            ManageSettings(model: model)
                .tabItem { Label("Manage", systemImage: "rectangle.3.group") }
            DetectionSettings(model: model)
                .tabItem { Label("Detection", systemImage: "wifi") }
            BreakWindow(model: model)
                .tabItem { Label("Workday", systemImage: "sun.max") }
            InvoiceSettingsWindow(model: model)
                .tabItem { Label("Invoices", systemImage: "doc.text") }
            UpdateSettings(model: model)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        // macOS draws the tab strip flush against the title bar; a little top
        // margin keeps it clear of the window title.
        .padding(.top, 8)
        .frame(minWidth: 620, minHeight: 520)
        .tickoalaWindowBackground()
    }
}

/// Start at login, the welcome screen and the version.
private struct GeneralSettings: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FormSection(title: "Start automatically") {
                    Toggle(isOn: Binding(
                        get: { model.launchAtLogin.isEnabled },
                        set: { model.launchAtLogin.setEnabled($0) }
                    )) {
                        Text("Start Tickoala automatically at login")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("Tickoala can only watch Wi-Fi while it runs. "
                         + "Turn this on to start it after every restart.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let error = model.launchAtLogin.errorMessage {
                        Text(error)
                            .foregroundStyle(.orange)
                        Button("Open Login Items") {
                            model.launchAtLogin.openLoginItemsSettings()
                        }
                    }
                }

                FormSection(title: "Menu bar") {
                    Toggle(isOn: $model.showTimerInIcon) {
                        Text("Show the running timer next to the menu bar icon")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("The elapsed time of the running block, ticking every second, so you can "
                         + "read the clock without opening the menu. Off by default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                FormSection(title: "Month revenue") {
                    Toggle(isOn: $model.showEarningsInIcon) {
                        Text("Show this month's revenue next to the menu bar icon")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Toggle(isOn: $model.showEarningsInMenu) {
                        Text("Show this month's revenue per customer in the menu")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("The amount counts up every second while you work. Both are off by default. "
                         + "If the running timer is also shown, it takes the icon and the revenue stays in the menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                FormSection(title: "Weekly summary") {
                    Toggle(isOn: $model.weeklySummaryEnabled) {
                        Text("Review last week once a week")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Toggle(isOn: $model.weeklySummaryEmail) {
                        Text("Also email it to me")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(!model.weeklySummaryEnabled)
                    if model.weeklySummaryEnabled && model.weeklySummaryEmail {
                        if model.invoiceSettings().canSendEmail {
                            HStack {
                                Text("Sent over the SMTP server from Invoice settings, to your sender address.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Send now") { model.sendWeeklySummaryNow() }
                            }
                        } else {
                            Text("Set the SMTP server under Invoice settings first.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Text("A short recap of the hours, clients and amount of the week that just "
                         + "ended, on the first day of the new week. Off by default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                FormSection(title: "Project budgets") {
                    Toggle(isOn: $model.showBudgetWarnings) {
                        Text("Warn when a project reaches 80% and 100% of its hour budget")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("Set an hour budget per project in the Projects window; the burn-down "
                         + "then shows how much is left. This only adds the notification, off by default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                FormSection(title: "About") {
                    LabeledContent("Version", value: model.updateChecker.currentVersion)
                    HStack {
                        Button("Show welcome screen") {
                            NSApp.activateForUI()
                            openWindow(id: "welcome")
                        }
                        Button("View on GitHub") {
                            NSWorkspace.shared.open(UpdateChecker.repositoryURL)
                        }
                        Spacer()
                    }
                }
            }
            .padding(16)
            .toggleStyle(.switch)
        }
    }
}

/// How Tickoala knows where you are, and what it sees right now.
private struct DetectionSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FormSection(title: "Detect by") {
                    Picker("Detect by", selection: $model.presenceSource) {
                        ForEach(PresenceSource.allCases, id: \.self) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                FormSection(title: "Status") {
                    Text(currentStatus)
                    if let outcome = model.lastWifiOutcome {
                        Text(outcome)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if model.wifi.access.needsAttention {
                    FormSection(title: "Location Services") {
                        Text(model.wifi.access.explanation
                             ?? "Tickoala only reads the Wi-Fi network name, nothing else.")
                        Button("Grant Location Services access") {
                            NSApp.activateForUI()
                            model.wifi.requestAccess()
                        }
                    }
                }

                if model.presenceSource == .wifi, let ssid = model.wifi.currentSSID, !model.isKnownNetwork(ssid) {
                    FormSection(title: "This network") {
                        Text("Network: \(ssid) (not linked)")
                        Menu("Link \(ssid) to") {
                            ForEach(model.profiles, id: \.profile.id) { item in
                                Button(item.profile.name) {
                                    model.linkCurrentNetwork(to: item.profile.id)
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private var currentStatus: String {
        if model.presenceSource == .location {
            if let name = model.currentLocationName { return "Location: \(name)" }
            if model.wifi.latitude != nil { return "Not at a stored location" }
            return "Waiting for a location fix…"
        }
        if let ssid = model.wifi.currentSSID {
            return "Network: \(ssid)\(model.isKnownNetwork(ssid) ? "" : " (not linked)")"
        }
        return "No network connection"
    }
}

/// The way in to everything that is not an app-wide setting: customers, projects,
/// corrections, invoices, expenses and the VAT return each have their own window.
/// This tab is the map, so it is clear where a thing is configured.
private struct ManageSettings: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private struct Destination: Identifiable {
        let id: String
        let title: String
        let summary: String
        let symbol: String
    }

    private let destinations: [Destination] = [
        Destination(
            id: "customers", title: "Customers", summary: "Names, hourly, travel and commute rates, billing details, billing rules, a retainer, and the Wi-Fi networks and location used for detection.",
            symbol: "person.2"
        ),
        Destination(
            id: "projects", title: "Projects", summary: "Project numbers and names, the active project, and an optional hour budget with a burn-down.",
            symbol: "folder"
        ),
        Destination(
            id: "overview", title: "Overview and corrections", summary: "Day, week and month totals. Correct, add, duplicate or delete blocks in a table or on a draggable timeline.",
            symbol: "calendar"
        ),
        Destination(
            id: "invoices", title: "Invoices", summary: "The monthly invoices: PDF, UBL/Peppol, hours CSV, sending by email, and the full history.",
            symbol: "doc.text"
        ),
        Destination(
            id: "expenses", title: "Expenses and mileage", summary: "Parking, materials and kilometres per customer, added to the invoice as their own lines.",
            symbol: "creditcard"
        ),
        Destination(
            id: "vat", title: "VAT return", summary: "The quarterly turnover and VAT per rate, ready to copy into the Belastingdienst form.",
            symbol: "percent"
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FormSection(title: "Manage") {
                    Text("Each of these opens its own window. The tabs around this one hold the app-wide settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ForEach(destinations) { destination in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: destination.symbol)
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(destination.title).font(.headline)
                                Text(destination.summary)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Button("Open") {
                                NSApp.activateForUI()
                                openWindow(id: destination.id)
                            }
                        }
                    }
                }

                FormSection(title: "Settings tabs") {
                    Text("General — start at login, the running month revenue and budget warnings.")
                    Text("Detection — Wi-Fi network or location, plus the Location Services permission.")
                    Text("Workday — day start and end, the project prompt, tags, idle detection, the automatic break deduction and the holidays and vacation days.")
                    Text("Invoices — your sender details, VAT rate, logo, numbering and the email (SMTP) server.")
                    Text("Updates — the version you are running and the daily check.")
                }
                .font(.callout)
            }
            .padding(14)
        }
    }
}

/// The daily version check and the escape hatch to turn it off.
private struct UpdateSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FormSection(title: "Version") {
                    LabeledContent("Current version", value: model.updateChecker.currentVersion)
                    if let version = model.updateChecker.availableVersion {
                        Text("Version \(version) is available.")
                        Button("View the new version") {
                            NSWorkspace.shared.open(UpdateChecker.releasesURL)
                        }
                    } else {
                        Text("You are on the latest version.")
                            .foregroundStyle(.secondary)
                    }
                }

                FormSection(title: "Automatic check") {
                    Toggle("Check for a new version once a day", isOn: Binding(
                        get: { model.updateChecker.isEnabled },
                        set: { enabled in
                            if enabled {
                                model.updateChecker.enable()
                            } else {
                                model.updateChecker.disable()
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    Button("Check now") { model.updateChecker.checkNow() }
                        .disabled(!model.updateChecker.isEnabled)
                    Text("This is the only request Tickoala makes by itself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }
}
