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
            DetectionSettings(model: model)
                .tabItem { Label("Detection", systemImage: "wifi") }
            BreakWindow(model: model)
                .tabItem { Label("Breaks", systemImage: "pause.circle") }
            InvoiceSettingsWindow(model: model)
                .tabItem { Label("Invoices", systemImage: "doc.text") }
            UpdateSettings(model: model)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        // macOS draws the tab strip flush against the title bar; a little top
        // margin keeps it clear of the window title.
        .padding(.top, 8)
        .frame(minWidth: 620, minHeight: 520)
    }
}

/// Start at login, the welcome screen and the version.
private struct GeneralSettings: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("Start automatically") {
                Toggle("Start Tickoala automatically at login", isOn: Binding(
                    get: { model.launchAtLogin.isEnabled },
                    set: { model.launchAtLogin.setEnabled($0) }
                ))
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

            Section("Onboarding") {
                Button("Show welcome screen") {
                    NSApp.activateForUI()
                    openWindow(id: "welcome")
                }
            }

            Section("About") {
                LabeledContent("Version", value: model.updateChecker.currentVersion)
                Button("View on GitHub") {
                    NSWorkspace.shared.open(UpdateChecker.repositoryURL)
                }
            }
        }
        .formStyle(.grouped)
        .padding(6)
    }
}

/// How Tickoala knows where you are, and what it sees right now.
private struct DetectionSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Detect by") {
                Picker("Detect by", selection: $model.presenceSource) {
                    ForEach(PresenceSource.allCases, id: \.self) { source in
                        Text(source.label).tag(source)
                    }
                }
                .pickerStyle(.inline)
            }

            Section("Status") {
                Text(currentStatus)
                if let outcome = model.lastWifiOutcome {
                    Text(outcome)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.wifi.access.needsAttention {
                Section("Location Services") {
                    Text(model.wifi.access.explanation
                         ?? "Tickoala only reads the Wi-Fi network name, nothing else.")
                    Button("Grant Location Services access") {
                        NSApp.activateForUI()
                        model.wifi.requestAccess()
                    }
                }
            }

            if model.presenceSource == .wifi, let ssid = model.wifi.currentSSID, !model.isKnownNetwork(ssid) {
                Section("This network") {
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
        .formStyle(.grouped)
        .padding(6)
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

/// The daily version check and the escape hatch to turn it off.
private struct UpdateSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Version") {
                LabeledContent("Current version", value: model.updateChecker.currentVersion)
                if let version = model.updateChecker.availableVersion {
                    Text("Version \(version) is available.")
                    if let url = UpdateChecker.tagURL(for: version) {
                        Button("View the new version") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } else {
                    Text("You are on the latest version.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Automatic check") {
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
                Button("Check now") { model.updateChecker.checkNow() }
                    .disabled(!model.updateChecker.isEnabled)
                Text("This is the only request Tickoala makes by itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(6)
    }
}
