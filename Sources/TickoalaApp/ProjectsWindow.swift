import SwiftUI
import TickoalaCore

/// Project management per customer: add, rename, activate and choose the active
/// project. Project numbers are unique within one customer.
struct ProjectsWindow: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var showingAdd = false

    private var profileId: Int64? {
        model.selectedCustomerId ?? model.profiles.first?.profile.id
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.profiles.isEmpty {
                emptyState
            } else if let profileId {
                projectList(for: profileId)
                Divider()
                footer(for: profileId)
            }
        }
        .frame(minWidth: 620, minHeight: 420)
        .tickoalaWindowBackground()
        .sheet(isPresented: $showingAdd) {
            if let profileId {
                AddProjectSheet(model: model, profileId: profileId) { showingAdd = false }
            }
        }
    }

    private var header: some View {
        HStack {
            Picker("Customer", selection: Binding(
                get: { profileId },
                set: { model.selectedCustomerId = $0 }
            )) {
                ForEach(model.profiles, id: \.profile.id) { item in
                    Text(item.profile.name).tag(Int64?.some(item.profile.id))
                }
            }
            .frame(maxWidth: 320)

            Button("Manage customers") {
                NSApp.activateForUI()
                openWindow(id: "customers")
            }
            .fixedSize()

            Spacer()

            Button {
                showingAdd = true
            } label: {
                Label("Add project", systemImage: "plus")
            }
            .disabled(profileId == nil)
        }
        .padding(10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No customer configured yet.")
                .font(.headline)
            Text("Add one in the Customers window.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Manage customers") {
                NSApp.activateForUI()
                openWindow(id: "customers")
            }
            Spacer()
        }
        .padding()
    }

    private func projectList(for profileId: Int64) -> some View {
        let projects = model.allProjects(for: profileId)
        let activeId = model.activeProjectId(for: profileId)

        return Group {
            if projects.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("This customer has no projects yet.")
                        .font(.headline)
                    Text("Without a project the tracker does not start automatically on arrival.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Add project") { showingAdd = true }
                        .padding(.top, 4)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(projects) { project in
                        ProjectRow(
                            model: model,
                            project: project,
                            isActiveProject: project.id == activeId
                        )
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func footer(for profileId: Int64) -> some View {
        HStack {
            if let active = model.profiles.first(where: { $0.profile.id == profileId })?.project {
                Text("Active project: \(active.label)")
                    .foregroundStyle(.secondary)
            } else {
                Text("No active project chosen yet — the tracker will not start automatically.")
                    .foregroundStyle(.orange)
            }
            Spacer()
            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(10)
    }
}

/// One project row: edit the name, choose the active project, enable or disable it.
private struct ProjectRow: View {
    @ObservedObject var model: AppModel
    let project: Project
    let isActiveProject: Bool

    @State private var number: String = ""
    @State private var name: String = ""
    @State private var budgetText: String = ""
    @State private var editing = false
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 12) {
            if editing {
                TextField("Number", text: $number)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 90)
                    .onSubmit { commit() }
                TextField("Project name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commit() }
                HStack(spacing: 4) {
                    TextField("Budget", text: $budgetText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .onSubmit { commit() }
                        .help("Hour budget, for example 80 or 40.5. Leave empty for none.")
                    Text("h budget")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Save") { commit() }
                Button("Cancel") { editing = false }
            } else {
                Text(project.number)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 90, alignment: .leading)

                Text(project.name)
                    .foregroundStyle(project.active ? .primary : .secondary)
                if project.hasBudget, let budget = model.budget(for: project.id) {
                    BudgetBurnDown(budget: budget)
                }
                Spacer()

                if isActiveProject {
                    Label("Active project", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                } else if project.active {
                    Button("Make active") {
                        model.selectProject(profileId: project.profileId, projectId: project.id)
                    }
                }

                Button(project.active ? "Deactivate" : "Reactivate") {
                    model.setProjectActive(id: project.id, active: !project.active)
                }

                Button {
                    number = project.number
                    name = project.name
                    budgetText = project.budgetMinutes % 60 == 0
                        ? String(project.budgetMinutes / 60)
                        : String(format: "%.2f", Double(project.budgetMinutes) / 60)
                    editing = true
                } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel("Edit project")
                .help("Change project number, name and hour budget")

                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete project")
                .help("Delete project (⌘Z to undo)")
            }
        }
        .padding(.vertical, 2)
        .confirmationDialog("Delete project \(project.number) — \(project.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteProject(id: project.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The blocks keep their hours but lose the project link. Press ⌘Z to undo.")
        }
    }

    private func commit() {
        let trimmed = budgetText.trimmingCharacters(in: .whitespaces)
        let minutes = trimmed.isEmpty ? 0 : Formatting.parseHoursMinutes(trimmed)
        guard let minutes else {
            model.errorMessage = "The budget must be a number of hours, for example 80 or 80.5."
            return
        }
        // Stays open if the number already exists, so the input isn't lost.
        if model.updateProject(id: project.id, number: number, name: name) {
            if minutes != project.budgetMinutes {
                model.setProjectBudget(id: project.id, minutes: minutes)
            }
            editing = false
        }
    }
}

/// The burn-down of a project: a bar plus what is left, coloured at the 80% and
/// 100% thresholds. Shown only for projects that actually carry a budget.
private struct BudgetBurnDown: View {
    let budget: ProjectBudget

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: min(budget.fraction, 1))
                .progressViewStyle(.linear)
                .tint(tint)
                .frame(width: 120)
            Text(label)
                .font(.caption)
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .help(budget.summary)
    }

    private var tint: Color {
        switch budget.level {
        case .exceeded: return .red
        case .nearLimit: return .orange
        default: return .green
        }
    }

    private var label: String {
        if budget.isOver { return "over by \(Formatting.duration(budget.overSeconds))" }
        return "\(Formatting.duration(budget.remainingSeconds)) left of \(Formatting.duration(budget.budgetSeconds))"
    }
}

/// Create a new project with a number and name.
private struct AddProjectSheet: View {
    @ObservedObject var model: AppModel
    let profileId: Int64
    var onClose: () -> Void

    @State private var number = ""
    @State private var name = ""
    @State private var budgetText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FormSection(title: "Add project") {
                FormField(label: "Number", labelWidth: 110) {
                    TextField("", text: $number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                }
                FormField(label: "Name", labelWidth: 110) {
                    TextField("", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                }
                FormField(label: "Budget (h)", labelWidth: 110) {
                    TextField("optional", text: $budgetText)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                }
                Text("The project number is unique within this customer. "
                     + "A budget shows a burn-down and, if switched on, warns at 80% and 100%.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red)
            }

            HStack {
                Button("Add") {
                    if model.addProject(
                        profileId: profileId, number: number, name: name, budgetMinutes: parsedBudget ?? 0
                    ) {
                        onClose()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(number.trimmingCharacters(in: .whitespaces).isEmpty
                          || name.trimmingCharacters(in: .whitespaces).isEmpty
                          || !budgetIsValid)

                Button("Cancel", role: .cancel) { onClose() }
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    /// Empty means no budget; anything else has to be readable hours.
    private var parsedBudget: Int? {
        let trimmed = budgetText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? 0 : Formatting.parseHoursMinutes(trimmed)
    }

    private var budgetIsValid: Bool {
        budgetText.trimmingCharacters(in: .whitespaces).isEmpty || parsedBudget != nil
    }
}
