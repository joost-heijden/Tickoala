import SwiftUI
import TickoalaCore

/// Customer management: name, hourly rate and the Wi-Fi networks on which the
/// tracker starts automatically. This is where a customer is created without the
/// command line too.
struct CustomersWindow: View {
    @ObservedObject var model: AppModel
    @State private var showingAdd = false

    var body: some View {
        NavigationSplitView {
            customerList
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let customer = model.selectedCustomer {
                CustomerForm(model: model, profile: customer)
                    .id(customer.id)
                    .navigationTitle(customer.name)
            } else {
                emptyState
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .sheet(isPresented: $showingAdd) {
            AddCustomerSheet(model: model) { showingAdd = false }
        }
    }

    private var customerList: some View {
        List(selection: $model.selectedCustomerId) {
            ForEach(model.profiles, id: \.profile.id) { item in
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.profile.name)
                        Text(item.profile.hasHourlyRate
                             ? "\(Formatting.money(cents: item.profile.hourlyRateCents, currency: item.profile.currency)) per hour"
                             : "no hourly rate")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !item.profile.active {
                        Text("inactive")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(Int64?.some(item.profile.id))
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add customer", systemImage: "plus")
                }
                Spacer()
            }
            .padding(8)
            .background(.bar)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No customer configured yet.")
                .font(.headline)
            Text("Add a customer with a Wi-Fi network and an hourly rate.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Add customer") { showingAdd = true }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The detail form of one customer: name, rate and Wi-Fi networks.
private struct CustomerForm: View {
    @ObservedObject var model: AppModel
    let profile: Profile

    @State private var name = ""
    @State private var rateText = ""
    @State private var currency: Currency = .eur
    @State private var newContext = ""
    @State private var active = true
    @State private var loaded = false
    @State private var newProjectNumber = ""
    @State private var newProjectName = ""

    var body: some View {
        Form {
            Section("Customer") {
                TextField("Name", text: $name)
                    .onSubmit { save() }
                    .onChange(of: name) { _ in save() }
                HStack {
                    Text("Hourly rate")
                    Spacer()
                    // The empty title plus prompt keeps "0.00" from appearing as a
                    // label next to the field; it is only an example.
                    TextField("", text: $rateText, prompt: Text("0.00"))
                        .labelsHidden()
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { save() }
                        .onChange(of: rateText) { _ in save() }
                    Picker("", selection: $currency) {
                        ForEach(Currency.allCases, id: \.self) { money in
                            Text(money.label).tag(money)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .onChange(of: currency) { _ in save() }
                    Text("per hour")
                        .foregroundStyle(.secondary)
                }
                Toggle("Active", isOn: $active)
                    .onChange(of: active) { _ in save() }
            }

            Section("Wi-Fi networks") {
                if profile.contexts.isEmpty {
                    Text("No Wi-Fi networks linked — the tracker will not start automatically.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                ForEach(profile.contexts, id: \.self) { context in
                    HStack {
                        Image(systemName: "wifi")
                            .foregroundStyle(.secondary)
                        Text(context)
                        Spacer()
                        Button {
                            model.removeCustomerContext(profileId: profile.id, context: context)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Unlink Wi-Fi network")
                    }
                }

                HStack {
                    TextField("Wi-Fi network name", text: $newContext)
                        .onSubmit { addContext() }
                    Button("Link") { addContext() }
                        .disabled(newContext.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("Projects") {
                let projects = model.allProjects(for: profile.id)
                let activeId = model.activeProjectId(for: profile.id)
                if projects.isEmpty {
                    Text("No projects yet. Add the first one below.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(projects) { project in
                        HStack(spacing: 8) {
                            Button {
                                model.selectProject(profileId: profile.id, projectId: project.id)
                            } label: {
                                Image(systemName: project.id == activeId ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(project.id == activeId ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.borderless)
                            .disabled(!project.active)
                            .help("Make this the active project")

                            Text(project.number)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 70, alignment: .leading)
                            Text(project.name)
                                .foregroundStyle(project.active ? .primary : .secondary)
                            Spacer()
                            if !project.active {
                                Text("inactive")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField("Number", text: $newProjectNumber)
                        .frame(width: 90)
                    TextField("Project name", text: $newProjectName)
                        .onSubmit { addProject() }
                    Button("Add") { addProject() }
                        .disabled(newProjectNumber.trimmingCharacters(in: .whitespaces).isEmpty
                                  || newProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section {
                LabeledContent("Rate", value: rateSummary)
                Text("Changes are saved immediately.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    private var rateSummary: String {
        guard let cents = Formatting.parseMoneyCents(rateText), cents > 0 else {
            return "no hourly rate — no amounts are calculated"
        }
        return "\(Formatting.money(cents: cents, currency: currency)) per hour"
    }

    private func load() {
        guard !loaded else { return }
        name = profile.name
        rateText = profile.hasHourlyRate
            ? Formatting.decimalAmount(cents: profile.hourlyRateCents)
            : ""
        currency = profile.currency
        active = profile.active
        loaded = true
    }

    private func addContext() {
        let context = newContext.trimmingCharacters(in: .whitespaces)
        guard !context.isEmpty else { return }
        model.addCustomerContext(profileId: profile.id, context: context)
        newContext = ""
    }

    private func save() {
        guard loaded else { return }
        // Leaving it empty means: no rate. We don't save unreadable input, but
        // leave it in place so the user sees something is wrong.
        let cents: Int
        if rateText.trimmingCharacters(in: .whitespaces).isEmpty {
            cents = 0
        } else if let parsed = Formatting.parseMoneyCents(rateText) {
            cents = parsed
        } else {
            model.errorMessage = "Cannot read the hourly rate: '\(rateText)'."
            return
        }
        model.updateCustomer(id: profile.id, name: name, hourlyRateCents: cents, currency: currency)
        model.setCustomerActive(id: profile.id, active: active)
    }

    private func addProject() {
        let number = newProjectNumber.trimmingCharacters(in: .whitespaces)
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !number.isEmpty, !name.isEmpty else { return }
        guard model.addProject(profileId: profile.id, number: number, name: name) else { return }
        // Set it as the active project right away: you add it to work on it.
        if let created = model.allProjects(for: profile.id).first(where: { $0.number == number }) {
            model.selectProject(profileId: profile.id, projectId: created.id)
        }
        newProjectNumber = ""
        newProjectName = ""
    }
}

/// New customer: name, one or more Wi-Fi networks and an optional hourly rate.
private struct AddCustomerSheet: View {
    @ObservedObject var model: AppModel
    var onClose: () -> Void

    @State private var name = ""
    @State private var contexts = ""
    @State private var rateText = ""
    @State private var currency: Currency = .eur

    var body: some View {
        Form {
            Section("Add customer") {
                TextField("Name", text: $name)
                TextField("Wi-Fi networks", text: $contexts, prompt: Text("e.g. Acme-Guest, Acme-Staff"))
                Text("Separate multiple networks with a comma.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Hourly rate")
                    Spacer()
                    TextField("", text: $rateText, prompt: Text("0.00"))
                        .labelsHidden()
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                    Picker("", selection: $currency) {
                        ForEach(Currency.allCases, id: \.self) { money in
                            Text(money.label).tag(money)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    Text("per hour")
                        .foregroundStyle(.secondary)
                }
            }

            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red)
            }

            HStack {
                Button("Add") {
                    let cents = rateText.trimmingCharacters(in: .whitespaces).isEmpty
                        ? 0
                        : Formatting.parseMoneyCents(rateText)
                    guard let cents else {
                        model.errorMessage = "Cannot read the hourly rate: '\(rateText)'."
                        return
                    }
                    let list = contexts
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    if model.addCustomer(name: name, contexts: list, hourlyRateCents: cents, currency: currency) {
                        onClose()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                          || contexts.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("Cancel", role: .cancel) { onClose() }
                Spacer()
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }
}
