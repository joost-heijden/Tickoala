import SwiftUI
import TickoalaCore

/// Projectbeheer per organisatie: toevoegen, hernoemen, activeren en het
/// actieve project kiezen. Projectnummers zijn uniek binnen één organisatie.
struct ProjectsWindow: View {
    @ObservedObject var model: AppModel
    @State private var selectedProfile: Int64?
    @State private var showingAdd = false

    private var profileId: Int64? {
        selectedProfile ?? model.profiles.first?.profile.id
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
        .onAppear {
            if selectedProfile == nil { selectedProfile = model.profiles.first?.profile.id }
        }
    }

    private var header: some View {
        HStack {
            Picker("Organisatie", selection: Binding(
                get: { profileId },
                set: { selectedProfile = $0 }
            )) {
                ForEach(model.profiles, id: \.profile.id) { item in
                    Text(item.profile.name).tag(Int64?.some(item.profile.id))
                }
            }
            .frame(maxWidth: 320)

            Spacer()

            Button {
                showingAdd = true
            } label: {
                Label("Project toevoegen", systemImage: "plus")
            }
            .disabled(profileId == nil)
        }
        .padding(10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("Nog geen organisatie ingesteld.")
                .font(.headline)
            Text("Voeg er een toe met:\ntickoala profile add --name \"…\" --context \"SSID\"")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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
                    Text("Deze organisatie heeft nog geen projecten.")
                        .font(.headline)
                    Text("Zonder project start de tracker niet automatisch bij binnenkomst.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Project toevoegen") { showingAdd = true }
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
                Text("Actief project: \(active.label)")
                    .foregroundStyle(.secondary)
            } else {
                Text("Nog geen actief project gekozen — de tracker start dan niet automatisch.")
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

/// Eén projectregel: naam bewerken, actief project kiezen, in- of uitschakelen.
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
                TextField("Nummer", text: $number)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 90)
                    .onSubmit { commit() }
                TextField("Projectnaam", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commit() }
                Button("Bewaren") { commit() }
                Button("Annuleren") { editing = false }
            } else {
                Text(project.number)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 90, alignment: .leading)

                Text(project.name)
                    .foregroundStyle(project.active ? .primary : .secondary)
                Spacer()

                if isActiveProject {
                    Label("Actief project", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                } else if project.active {
                    Button("Maak actief") {
                        model.selectProject(profileId: project.profileId, projectId: project.id)
                    }
                }

                Button(project.active ? "Deactiveren" : "Heractiveren") {
                    model.setProjectActive(id: project.id, active: !project.active)
                }

                Button {
                    number = project.number
                    name = project.name
                    editing = true
                } label: {
                    Image(systemName: "pencil")
                }
                .help("Projectnummer en naam wijzigen")
            }
        }
        .padding(.vertical, 2)
    }

    private func commit() {
        // Blijft open als het nummer al bestaat, zodat de invoer niet verloren gaat.
        if model.updateProject(id: project.id, number: number, name: name) {
            editing = false
        }
    }
}

/// Nieuw project aanmaken met nummer en naam.
private struct AddProjectSheet: View {
    @ObservedObject var model: AppModel
    let profileId: Int64
    var onClose: () -> Void

    @State private var number = ""
    @State private var name = ""

    var body: some View {
        Form {
            Section("Project toevoegen") {
                TextField("Projectnummer", text: $number)
                TextField("Projectnaam", text: $name)
                Text("Het projectnummer is uniek binnen deze organisatie.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red)
            }

            HStack {
                Button("Toevoegen") {
                    if model.addProject(profileId: profileId, number: number, name: name) {
                        onClose()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(number.trimmingCharacters(in: .whitespaces).isEmpty
                          || name.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("Annuleren", role: .cancel) { onClose() }
                Spacer()
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}
