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
                NSApp.activate(ignoringOtherApps: true)
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
                NSApp.activate(ignoringOtherApps: true)
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
    @State private var editing = false

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
                Button("Save") { commit() }
                Button("Cancel") { editing = false }
            } else {
                Text(project.number)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 90, alignment: .leading)

                Text(project.name)
                    .foregroundStyle(project.active ? .primary : .secondary)
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
                    editing = true
                } label: {
                    Image(systemName: "pencil")
                }
                .help("Change project number and name")
            }
        }
        .padding(.vertical, 2)
    }

    private func commit() {
        // Stays open if the number already exists, so the input isn't lost.
        if model.updateProject(id: project.id, number: number, name: name) {
            editing = false
        }
    }
}

/// Create a new project with a number and name.
private struct AddProjectSheet: View {
    @ObservedObject var model: AppModel
    let profileId: Int64
    var onClose: () -> Void

    @State private var number = ""
    @State private var name = ""

    var body: some View {
        Form {
            Section("Add project") {
                TextField("Project number", text: $number)
                TextField("Project name", text: $name)
                Text("The project number is unique within this customer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red)
            }

            HStack {
                Button("Add") {
                    if model.addProject(profileId: profileId, number: number, name: name) {
                        onClose()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(number.trimmingCharacters(in: .whitespaces).isEmpty
                          || name.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("Cancel", role: .cancel) { onClose() }
                Spacer()
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}
