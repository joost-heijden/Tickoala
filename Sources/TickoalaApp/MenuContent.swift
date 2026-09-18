import AppKit
import SwiftUI
import TickoalaCore

/// The contents of the menu bar menu: status, project switching and quick control.
/// Everything that is configured once lives in the Settings window; this stays
/// about the daily work.
struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.canUndo || model.canRedo {
            if model.canUndo {
                Button("Undo \(model.undoTitle)") { model.undo() }
                    .keyboardShortcut("z", modifiers: .command)
            }
            if model.canRedo {
                Button("Redo \(model.redoTitle)") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            Divider()
        }

        if model.profiles.isEmpty {
            Text("No profile configured yet")
            Text("Use: tickoala profile add --name … --context …")
        }

        networkPrompts

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
                Text(item.statusHeadline)
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

        Button("Open Tickoala") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }

        Button("Overview and corrections") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "overview")
        }
        .keyboardShortcut("o")

        Button("Invoices…") {
            NSApp.activate(ignoringOtherApps: true)
            model.showCurrentInvoiceMonth()
            openWindow(id: "invoices")
        }
        .keyboardShortcut("i")

        Divider()

        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }
        .keyboardShortcut(",", modifiers: .command)

        if let error = model.errorMessage {
            Divider()
            Text("Error: \(error)")
        }

        if let version = model.updateChecker.availableVersion {
            Divider()
            Text("Version \(version) available")
            if let url = UpdateChecker.tagURL(for: version) {
                Button("View the new version") {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        Divider()

        Button("Quit Tickoala") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// A question the user has to answer right now, so it stays in the menu even
    /// though the rest of the network handling lives in Settings.
    @ViewBuilder
    private var networkPrompts: some View {
        if let selection = model.pendingWifiProjectSelection {
            Section("Network") {
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
            Divider()
        }

        if let pending = model.pendingNetworkSwitch {
            Section("Network") {
                Text("Network changed to \(model.displayContext(pending.context))")
                    .font(.headline)
                Text("Now running: \(pending.runningLabel)")
                Button("Keep \(pending.runningLabel) running") {
                    model.keepRunningAfterNetworkSwitch()
                }
                Button("Start a new block at \(model.displayContext(pending.context))") {
                    model.startNewBlockAfterNetworkSwitch()
                }
            }
            Divider()
        }
    }

    private func openCustomers() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "customers")
    }
}

extension ProfileStatus {
    /// "Working 3:42 (no signal since 12:00)" or a short status word; shared by the
    /// menu and the hub window.
    var statusHeadline: String {
        switch mode {
        case .working:
            let pending = pendingStopAt.map { " (no signal since \(Formatting.clock($0)))" } ?? ""
            return "\(mode.label) \(Formatting.duration(elapsedCurrent))\(pending)"
        case .paused, .stopped, .attention:
            return mode.label
        }
    }
}
