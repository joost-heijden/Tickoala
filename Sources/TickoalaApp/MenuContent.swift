import AppKit
import SwiftUI
import TickoalaCore

/// The contents of the menu bar menu: status, project switching and quick control.
struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.profiles.isEmpty {
            Text("No profile configured yet")
            Text("Use: tickoala profile add --name … --context …")
        }

        Section("Wi-Fi") {
            if let explanation = model.wifi.access.explanation {
                Text("⚠︎ \(explanation)")
                Button("Grant Location Services access") {
                    NSApp.activate(ignoringOtherApps: true)
                    model.wifi.requestAccess()
                }
            } else if let ssid = model.wifi.currentSSID {
                Text("Network: \(ssid)\(model.isKnownNetwork(ssid) ? "" : " (not linked)")")
                if !model.isKnownNetwork(ssid) {
                    Menu("Link \(ssid) to") {
                        ForEach(model.profiles, id: \.profile.id) { item in
                            Button(item.profile.name) {
                                model.linkCurrentNetwork(to: item.profile.id)
                            }
                        }
                    }
                }
            } else {
                Text("No Wi-Fi connection")
            }

            if let outcome = model.lastWifiOutcome {
                Text(outcome)
            }

            if let selection = model.pendingWifiProjectSelection {
                Divider()
                Text("Multiple projects for \(selection.ssid)")
                    .font(.headline)
                Text("Choose the right project to start.")
                ForEach(selection.projects) { project in
                    Button(project.label) {
                        model.chooseWifiProject(selection, projectId: project.id)
                    }
                }
                Button("Cancel") { model.cancelWifiProjectSelection() }
            }
        }

        Divider()

        if !model.profiles.isEmpty {
            // Choose the customer right away: the menu opens the Customers window
            // with that customer selected, so you don't have to search first.
            Menu("Customer: \(model.selectedCustomer?.name ?? "none")") {
                ForEach(model.profiles, id: \.profile.id) { item in
                    Button(item.profile.id == model.selectedCustomerId
                           ? "✓ \(item.profile.name)"
                           : "   \(item.profile.name)") {
                        model.selectedCustomerId = item.profile.id
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "customers")
                    }
                }
                Divider()
                Button("Manage customers") { openCustomers() }
            }
        }

        ForEach(model.profiles, id: \.profile.id) { item in
            Section(item.profile.name) {
                Text(headline(for: item))
                Text("Today \(Formatting.duration(item.todayTotal))  ·  Week \(Formatting.duration(item.weekTotal))")
                if item.todayBreak > 0 {
                    Text("Net, break today -\(Formatting.duration(item.todayBreak))")
                }

                if let attention = item.attention {
                    Text("⚠︎ \(attention)")
                    Button("Clear notice") { model.clearAttention(profileId: item.profile.id) }
                }

                Menu("Project: \(item.project?.label ?? "none")") {
                    let projects = model.projects(for: item.profile.id)
                    if projects.isEmpty {
                        Text("No active projects")
                    }
                    ForEach(projects) { project in
                        Button(project.id == item.project?.id ? "✓ \(project.label)" : "   \(project.label)") {
                            model.selectProject(profileId: item.profile.id, projectId: project.id)
                        }
                    }
                    Divider()
                    Button("Manage projects") {
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "projects")
                    }
                    Button("Manage customer") {
                        model.selectedCustomerId = item.profile.id
                        openCustomers()
                    }
                }

                if item.runningEntry != nil {
                    Button("Pause") { model.pause(profileId: item.profile.id) }
                    Button("Stop") { model.stop(profileId: item.profile.id) }
                } else if item.mode == .paused {
                    Button("Resume") { model.resume(profileId: item.profile.id) }
                } else {
                    Button("Start") { model.start(profileId: item.profile.id) }
                        .disabled(item.project == nil)
                }
            }
        }

        Divider()

        Button("Overview and corrections") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "overview")
        }
        .keyboardShortcut("o")

        Button("Manage projects") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "projects")
        }
        .keyboardShortcut("p")

        Button("Manage customers") { openCustomers() }
            .keyboardShortcut("k")

        Button("Break settings") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "break-settings")
        }

        Button("Export CSV") { exportCSV() }
            .keyboardShortcut("e")

        if let error = model.errorMessage {
            Divider()
            Text("Error: \(error)")
        }

        Divider()

        Button("Open Tickoala") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "welcome")
        }

        Divider()

        if let version = model.updateChecker.availableVersion {
            Text("Version \(version) available")
            if let url = UpdateChecker.tagURL(for: version) {
                Button("View the new version") {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        // Always visible, even without a new version: here you see which version
        // you are running and turn the check off (or back on).
        Menu("Updates") {
            Text("Current version \(model.updateChecker.currentVersion)")
            Button("Check now") { model.updateChecker.checkNow() }
                .disabled(!model.updateChecker.isEnabled)
            Divider()
            if model.updateChecker.isEnabled {
                Button("Stop checking for updates") { model.updateChecker.disable() }
            } else {
                Button("Check for updates again") { model.updateChecker.enable() }
            }
        }

        Button("Open on GitHub") {
            NSWorkspace.shared.open(UpdateChecker.repositoryURL)
        }

        Divider()

        Button("Quit Tickoala") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func headline(for item: ProfileStatus) -> String {
        switch item.mode {
        case .working:
            let pending = item.pendingStopAt.map { " (stop from \(Formatting.clock($0)))" } ?? ""
            return "\(item.mode.label) \(Formatting.duration(item.elapsedCurrent))\(pending)"
        case .paused, .stopped, .attention:
            return item.mode.label
        }
    }

    private func openCustomers() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "customers")
    }

    private func exportCSV() {
        guard let csv = model.exportCSV() else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = model.suggestedExportName()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "Export the shown period (\(model.period.label.lowercased()))"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            model.errorMessage = "Could not export: \(error)"
        }
    }
}
