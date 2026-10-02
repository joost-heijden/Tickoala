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
            Text("No customer configured yet")
            Button("Add customer…") { openCustomers() }
        }

        idlePrompt
        networkPrompts
        quickStartSection

        if !model.profiles.isEmpty {
            // Choose the customer right away: the menu opens the Customers window
            // with that customer selected, so you don't have to search first.
            Menu("Customer: \(model.selectedCustomer?.name ?? "none")") {
                ForEach(model.profiles, id: \.profile.id) { item in
                    Button(item.profile.id == model.selectedCustomerId
                           ? "✓ \(item.profile.name)"
                           : "   \(item.profile.name)") {
                        model.selectedCustomerId = item.profile.id
                        NSApp.activateForUI()
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
                if model.showEarningsInMenu {
                    Text("Month \(Formatting.money(cents: item.monthAmountCents, currency: item.profile.currency))")
                        .monospacedDigit()
                }
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
                        NSApp.activateForUI()
                        openWindow(id: "projects")
                    }
                    Button("Manage customer") {
                        model.selectedCustomerId = item.profile.id
                        openCustomers()
                    }
                }

                if model.showBudgetWarnings {
                    ForEach(model.budgetedProjects(for: item.profile.id)) { project in
                        if let budget = model.budget(for: project.id) {
                            Text(budgetLine(project: project, budget: budget))
                        }
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

        goalsSection
        outstandingSection

        Divider()

        Button("Open Tickoala") {
            NSApp.activateForUI()
            openWindow(id: "main")
        }

        Button("Overview and corrections") {
            NSApp.activateForUI()
            openWindow(id: "overview")
        }
        .keyboardShortcut("o")

        Button("Invoices") {
            NSApp.activateForUI()
            model.showCurrentInvoicePeriod()
            openWindow(id: "invoices")
        }
        .keyboardShortcut("i")

        Button("Expenses") {
            NSApp.activateForUI()
            openWindow(id: "expenses")
        }

        Button("VAT return") {
            NSApp.activateForUI()
            openWindow(id: "vat")
        }

        Divider()

        Menu("Data") {
            Button("Import time entries…") { model.importEntriesPanel() }
            Divider()
            Button("Back up everything…") { model.backupToFilePanel() }
            Button("Restore from a backup…") { model.restoreFromFilePanel() }
        }

        Button("Settings…") {
            NSApp.activateForUI()
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
            Button("View the new version") {
                NSWorkspace.shared.open(UpdateChecker.releasesURL)
            }
        }

        Divider()

        Button("Quit Tickoala") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Quick start: pinned favourites and recent client+project pairs, one click
    /// each, so the timer starts without opening a window.
    @ViewBuilder
    private var quickStartSection: some View {
        let favorites = model.favoriteStarts
        let recents = model.recentStarts
        if !favorites.isEmpty || !recents.isEmpty {
            Menu("Start") {
                if !favorites.isEmpty {
                    Section("Favorites") {
                        ForEach(favorites) { start in
                            quickStartButton(start)
                        }
                    }
                }
                if !recents.isEmpty {
                    Section("Recent") {
                        ForEach(recents) { start in
                            quickStartButton(start)
                        }
                    }
                }
                Divider()
                Text("Pin a pair from a customer's menu below")
            }
        }
    }

    /// One quick-start row: starts on click, with a context menu to pin or unpin.
    @ViewBuilder
    private func quickStartButton(_ start: AppModel.QuickStart) -> some View {
        Button(start.label) {
            model.startQuick(profileId: start.profileId, projectId: start.projectId)
        }
        .contextMenu {
            Button(start.isFavorite ? "Unpin" : "Pin as favorite") {
                model.toggleFavoriteStart(profileId: start.profileId, projectId: start.projectId)
            }
        }
    }

    /// The idle question, kept in the menu so it can still be answered after the
    /// notification has gone.
    @ViewBuilder
    private var idlePrompt: some View {
        if let pending = model.pendingIdle {
            Section("Away from the Mac") {
                Text("Away for \(Formatting.duration(pending.seconds))")
                    .font(.headline)
                Text("Discard that time from the block, or keep it?")
                Button("Discard the idle time") { model.discardIdleTime() }
                Button("Keep it") { model.keepIdleTime() }
            }
            Divider()
        }
    }

    /// Progress towards the day and week goals, summed over every client.
    @ViewBuilder
    private var goalsSection: some View {
        let today = model.todayGoal
        let week = model.weekGoal
        if today != nil || week != nil {
            Section("Goals") {
                if let today {
                    Text("Today \(today.summary)")
                }
                if let week {
                    Text("Week \(week.summary)")
                }
            }
        }
    }

    /// Open invoices, so an unpaid or overdue one is not missed.
    @ViewBuilder
    private var outstandingSection: some View {
        let totals = model.outstandingTotals
        if !totals.isEmpty {
            let overdue = model.overdueInvoices.count
            Section("Invoices") {
                ForEach(totals.indices, id: \.self) { index in
                    Text("Outstanding \(Formatting.money(cents: totals[index].cents, currency: totals[index].currency))")
                }
                if overdue > 0 {
                    Text("⚠︎ \(overdue) overdue")
                }
                Button("Open invoices") {
                    NSApp.activateForUI()
                    openWindow(id: "invoices")
                }
            }
        }
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
                Button("Stop \(pending.runningLabel)") {
                    model.stopAfterNetworkSwitch()
                }
            }
            Divider()
        }
    }

    private func openCustomers() {
        NSApp.activateForUI()
        openWindow(id: "customers")
    }

    /// A burn-down line for the menu: a warning sign once the budget is near or
    /// passed, otherwise just how much is left.
    private func budgetLine(project: Project, budget: ProjectBudget) -> String {
        if budget.isOver {
            return "⚠︎ \(project.label): over budget by \(Formatting.duration(budget.overSeconds))"
        }
        if budget.level == .nearLimit {
            return "⚠︎ \(project.label): \(Formatting.duration(budget.remainingSeconds)) of \(Formatting.duration(budget.budgetSeconds)) left"
        }
        return "Budget \(project.label): \(Formatting.duration(budget.remainingSeconds)) left"
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
