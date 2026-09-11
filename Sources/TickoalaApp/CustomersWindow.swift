import SwiftUI
import TickoalaCore

/// Klantbeheer: naam, uurtarief en de wifinetwerken waarop de tracker automatisch
/// start. Dit is de plek waar een klant ook zonder commandoregel ontstaat.
struct CustomersWindow: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var showingAdd = false

    var body: some View {
        NavigationSplitView {
            customerList
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let customer = model.selectedCustomer {
                CustomerForm(model: model, profile: customer) {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "projecten")
                }
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
                             ? "\(Formatting.money(cents: item.profile.hourlyRateCents)) per uur"
                             : "geen uurtarief")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !item.profile.active {
                        Text("inactief")
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
                    Label("Klant toevoegen", systemImage: "plus")
                }
                Spacer()
            }
            .padding(8)
            .background(.bar)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("Nog geen klant ingesteld.")
                .font(.headline)
            Text("Voeg een klant toe met een wifinetwerk en een uurtarief.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Klant toevoegen") { showingAdd = true }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Het detailformulier van één klant: naam, tarief en wifinetwerken.
private struct CustomerForm: View {
    @ObservedObject var model: AppModel
    let profile: Profile
    var onShowProjects: () -> Void

    @State private var name = ""
    @State private var rateText = ""
    @State private var newContext = ""
    @State private var active = true
    @State private var loaded = false

    var body: some View {
        Form {
            Section("Klant") {
                TextField("Naam", text: $name)
                    .onSubmit { save() }
                HStack {
                    Text("Uurtarief")
                    Spacer()
                    TextField("0,00", text: $rateText)
                        .frame(width: 100)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { save() }
                    Text("per uur")
                        .foregroundStyle(.secondary)
                }
                Toggle("Actief", isOn: $active)
                    .onChange(of: active) { _ in save() }
            }

            Section("Wifinetwerken") {
                if profile.contexts.isEmpty {
                    Text("Geen wifinetwerken gekoppeld — de tracker start dan niet automatisch.")
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
                        .help("Wifinetwerk ontkoppelen")
                    }
                }

                HStack {
                    TextField("Naam van het wifinetwerk", text: $newContext)
                        .onSubmit { addContext() }
                    Button("Koppelen") { addContext() }
                        .disabled(newContext.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section {
                LabeledContent("Tarief", value: rateSummary)
                HStack {
                    Button("Bewaren") { save() }
                        .keyboardShortcut(.defaultAction)
                    Button("Projecten") { onShowProjects() }
                    Spacer()
                }
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
            return "geen uurtarief — er worden geen bedragen berekend"
        }
        return "\(Formatting.money(cents: cents)) per uur"
    }

    private func load() {
        guard !loaded else { return }
        name = profile.name
        rateText = profile.hasHourlyRate
            ? Formatting.decimalAmount(cents: profile.hourlyRateCents).replacingOccurrences(of: ".", with: ",")
            : ""
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
        // Leeg laten betekent: geen tarief. Onleesbare invoer laten we staan zodat
        // de gebruiker ziet dat er iets niet klopt.
        let cents: Int
        if rateText.trimmingCharacters(in: .whitespaces).isEmpty {
            cents = 0
        } else if let parsed = Formatting.parseMoneyCents(rateText) {
            cents = parsed
        } else {
            model.errorMessage = "Kan het uurtarief niet lezen: '\(rateText)'."
            return
        }
        model.updateCustomer(id: profile.id, name: name, hourlyRateCents: cents)
        model.setCustomerActive(id: profile.id, active: active)
    }
}

/// Nieuwe klant: naam, één of meer wifinetwerken en een optioneel uurtarief.
private struct AddCustomerSheet: View {
    @ObservedObject var model: AppModel
    var onClose: () -> Void

    @State private var name = ""
    @State private var contexts = ""
    @State private var rateText = ""

    var body: some View {
        Form {
            Section("Klant toevoegen") {
                TextField("Naam", text: $name)
                TextField("Wifinetwerken", text: $contexts, prompt: Text("bijv. Acme-Guest, Acme-Staff"))
                Text("Meerdere netwerken scheid je met een komma.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Uurtarief")
                    Spacer()
                    TextField("0,00", text: $rateText)
                        .frame(width: 100)
                        .multilineTextAlignment(.trailing)
                    Text("per uur")
                        .foregroundStyle(.secondary)
                }
            }

            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red)
            }

            HStack {
                Button("Toevoegen") {
                    let cents = rateText.trimmingCharacters(in: .whitespaces).isEmpty
                        ? 0
                        : Formatting.parseMoneyCents(rateText)
                    guard let cents else {
                        model.errorMessage = "Kan het uurtarief niet lezen: '\(rateText)'."
                        return
                    }
                    let list = contexts
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    if model.addCustomer(name: name, contexts: list, hourlyRateCents: cents) {
                        onClose()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                          || contexts.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("Annuleren", role: .cancel) { onClose() }
                Spacer()
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }
}
