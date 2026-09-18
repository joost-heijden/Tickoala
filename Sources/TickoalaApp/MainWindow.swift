import AppKit
import SwiftUI
import TickoalaCore

/// The hub: the status of every customer with direct control, and the way into
/// the overview, invoices and the lists. Opened with "Open Tickoala" from the menu.
struct MainWindow: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.profiles.isEmpty {
                        Text("No customer configured yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.profiles, id: \.profile.id) { item in
                        CustomerCard(model: model, item: item)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 500)
    }

    private var header: some View {
        HStack(spacing: 12) {
            koala
            VStack(alignment: .leading, spacing: 1) {
                Text("Tickoala")
                    .font(.title2.bold())
                Text("Background time tracking")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("v\(model.updateChecker.currentVersion)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }

    private var koala: some View {
        Group {
            if let image = koalaImage {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "clock.badge.checkmark")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: 36, height: 36)
        .foregroundStyle(Color.accentColor)
    }

    private var koalaImage: NSImage? {
        let theme = colorScheme == .dark ? "dark" : "light"
        guard let url = Bundle.tickoalaURL(
            forResource: "tickoala-menu-working-\(theme)",
            withExtension: "svg"
        ), let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.isTemplate = true
        return image
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Overview") { open("overview") }
            Button("Invoices") {
                NSApp.activate(ignoringOtherApps: true)
                model.showCurrentInvoiceMonth()
                openWindow(id: "invoices")
            }
            Button("Projects") { open("projects") }
            Button("Customers") { open("customers") }
            Spacer()
            Button("Export CSV") { exportCSV() }
            Button("Settings") { open("settings") }
        }
        .padding(12)
    }

    private func open(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
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

/// One customer: status, totals, project and the start/pause/stop controls.
private struct CustomerCard: View {
    @ObservedObject var model: AppModel
    let item: ProfileStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                Text(item.profile.name)
                    .font(.headline)
                Spacer()
                Text(item.statusHeadline)
                    .font(.headline)
                    .monospacedDigit()
            }

            HStack(spacing: 6) {
                Text("Today \(Formatting.duration(item.todayTotal))")
                Text("· Week \(Formatting.duration(item.weekTotal))")
                if item.todayBreak > 0 {
                    Text("· break −\(Formatting.duration(item.todayBreak))")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            HStack {
                Picker("Project", selection: projectBinding) {
                    if projects.isEmpty {
                        Text("No active projects").tag(Int64?.none)
                    }
                    ForEach(projects) { project in
                        Text(project.label).tag(Int64?.some(project.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
                .disabled(projects.isEmpty)

                Spacer()
                controls
            }

            if let attention = item.attention {
                HStack {
                    Text("⚠︎ \(attention)")
                        .foregroundStyle(.orange)
                    Button("Clear notice") {
                        model.clearAttention(profileId: item.profile.id)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var controls: some View {
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

    private var projects: [Project] {
        model.projects(for: item.profile.id)
    }

    private var projectBinding: Binding<Int64?> {
        Binding(
            get: { item.project?.id },
            set: { id in
                guard let id, id != item.project?.id else { return }
                model.selectProject(profileId: item.profile.id, projectId: id)
            }
        )
    }

    private var color: Color {
        switch item.mode {
        case .working: .green
        case .paused: .orange
        case .attention: .red
        case .stopped: .secondary
        }
    }
}
