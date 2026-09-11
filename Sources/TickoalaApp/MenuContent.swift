import AppKit
import SwiftUI
import TickoalaCore

/// De inhoud van het menubalkmenu: status, projectwissel en snelle bediening.
struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.profiles.isEmpty {
            Text("Nog geen profiel ingesteld")
            Text("Gebruik: tickoala profile add --name … --context …")
        }

        Section("Wifi") {
            if let explanation = model.wifi.access.explanation {
                Text("⚠︎ \(explanation)")
                Button("Toegang tot Locatievoorzieningen regelen…") {
                    NSApp.activate(ignoringOtherApps: true)
                    model.wifi.requestAccess()
                }
            } else if let ssid = model.wifi.currentSSID {
                Text("Netwerk: \(ssid)\(model.isKnownNetwork(ssid) ? "" : " (niet gekoppeld)")")
                if !model.isKnownNetwork(ssid) {
                    Menu("Koppel \(ssid) aan…") {
                        ForEach(model.profiles, id: \.profile.id) { item in
                            Button(item.profile.name) {
                                model.linkCurrentNetwork(to: item.profile.id)
                            }
                        }
                    }
                }
            } else {
                Text("Geen wifiverbinding")
            }

            if let outcome = model.lastWifiOutcome {
                Text(outcome)
            }

            if let selection = model.pendingWifiProjectSelection {
                Divider()
                Text("Meerdere projecten voor \(selection.ssid)")
                    .font(.headline)
                Text("Kies het juiste project om te starten.")
                ForEach(selection.projects) { project in
                    Button(project.label) {
                        model.chooseWifiProject(selection, projectId: project.id)
                    }
                }
                Button("Annuleren") { model.cancelWifiProjectSelection() }
            }
        }

        Divider()

        ForEach(model.profiles, id: \.profile.id) { item in
            Section(item.profile.name) {
                Text(headline(for: item))
                Text("Vandaag \(Formatting.duration(item.todayTotal))  ·  Week \(Formatting.duration(item.weekTotal))")
                if item.todayBreak > 0 {
                    Text("Netto, pauze vandaag -\(Formatting.duration(item.todayBreak))")
                }

                if let attention = item.attention {
                    Text("⚠︎ \(attention)")
                    Button("Melding wissen") { model.clearAttention(profileId: item.profile.id) }
                }

                Menu("Project: \(item.project?.label ?? "geen")") {
                    let projects = model.projects(for: item.profile.id)
                    if projects.isEmpty {
                        Text("Geen actieve projecten")
                    }
                    ForEach(projects) { project in
                        Button(project.id == item.project?.id ? "✓ \(project.label)" : "   \(project.label)") {
                            model.selectProject(profileId: item.profile.id, projectId: project.id)
                        }
                    }
                    Divider()
                    Button("Projecten beheren…") {
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "projecten")
                    }
                }

                if item.runningEntry != nil {
                    Button("Pauzeer") { model.pause(profileId: item.profile.id) }
                    Button("Stop") { model.stop(profileId: item.profile.id) }
                } else if item.mode == .paused {
                    Button("Hervat") { model.resume(profileId: item.profile.id) }
                } else {
                    Button("Start") { model.start(profileId: item.profile.id) }
                        .disabled(item.project == nil)
                }
            }
        }

        Divider()

        Button("Overzicht en correcties…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "overzicht")
        }
        .keyboardShortcut("o")

        Button("Projecten beheren…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "projecten")
        }
        .keyboardShortcut("p")

        Button("Pauze-instellingen…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "pauze")
        }

        Button("Exporteer CSV…") { exportCSV() }
            .keyboardShortcut("e")

        if let error = model.errorMessage {
            Divider()
            Text("Fout: \(error)")
        }

        if let versie = model.updateChecker.beschikbareVersie {
            Divider()
            Text("Versie \(versie) beschikbaar")
            Button("Open de release-pagina") {
                NSWorkspace.shared.open(UpdateChecker.releasePageURL)
            }
            Button("Updates niet meer controleren") {
                model.updateChecker.disable()
            }
        }

        Divider()

        Button("Stop Tickoala") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func headline(for item: ProfileStatus) -> String {
        switch item.mode {
        case .working:
            let pending = item.pendingStopAt.map { " (stop vanaf \(Formatting.clock($0)))" } ?? ""
            return "\(item.mode.label) \(Formatting.duration(item.elapsedCurrent))\(pending)"
        case .paused, .stopped, .attention:
            return item.mode.label
        }
    }

    private func exportCSV() {
        guard let csv = model.exportCSV() else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = model.suggestedExportName()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "Exporteer de getoonde periode (\(model.period.label.lowercased()))"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            model.errorMessage = "Kon niet exporteren: \(error)"
        }
    }
}
