import AppKit
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
        .tickoalaWindowBackground()
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
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .tickoalaWindow))
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
    @State private var travelRateText = ""
    @State private var commuteRateText = ""
    @State private var retainerDescription = ""
    @State private var retainerAmountText = ""
    @State private var retainerActive = false
    @State private var roundingMinutes = 0
    @State private var roundUp = false
    @State private var minimumText = ""
    @State private var eveningPercent = 0
    @State private var weekendPercent = 0
    @State private var eveningStart = Date()
    @State private var newContext = ""
    @State private var active = true
    @State private var loaded = false
    @State private var newProjectNumber = ""
    @State private var newProjectName = ""
    @State private var billingAddress = ""
    @State private var vatNumber = ""
    @State private var vatRate = 21
    @State private var poNumber = ""
    @State private var billingEmail = ""
    @State private var billingCc = ""
    @State private var radius = 150
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                FormSection(title: "Customer") {
                    FormField(label: "Name") {
                        TextField("", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .onSubmit { save() }
                            .onChange(of: name) { _ in save() }
                    }
                    FormField(label: "Hourly rate") {
                        HStack(spacing: 8) {
                            TextField("", text: $rateText, prompt: Text("0.00"))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                                .multilineTextAlignment(.leading)
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
                    }
                    FormField(label: "Travel rate") {
                        HStack(spacing: 8) {
                            TextField("", text: $travelRateText, prompt: Text("same as hourly"))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                                .multilineTextAlignment(.leading)
                                .onSubmit { saveTravelRates() }
                                .onChange(of: travelRateText) { _ in saveTravelRates() }
                            Text("per hour for client travel")
                                .foregroundStyle(.secondary)
                        }
                    }
                    FormField(label: "Commute rate") {
                        HStack(spacing: 8) {
                            TextField("", text: $commuteRateText, prompt: Text("not billed"))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                                .multilineTextAlignment(.leading)
                                .onSubmit { saveTravelRates() }
                                .onChange(of: commuteRateText) { _ in saveTravelRates() }
                            Text("per hour; empty means the commute is not invoiced")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Active", isOn: $active)
                        .onChange(of: active) { _ in save() }
                }

                FormSection(title: "Invoicing") {
                    FormFieldStacked(label: "Billing address") {
                        TextField("", text: $billingAddress, axis: .vertical)
                            .lineLimit(2...4)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .onChange(of: billingAddress) { _ in saveInvoicing() }
                    }
                    FormField(label: "VAT number") {
                        TextField("", text: $vatNumber)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .onChange(of: vatNumber) { _ in saveInvoicing() }
                    }
                    Stepper(value: $vatRate, in: 0...100) {
                        Text("VAT rate: \(vatRate) %")
                            .monospacedDigit()
                    }
                    .onChange(of: vatRate) { _ in saveInvoicing() }
                    FormField(label: "Invoice email") {
                        TextField("", text: $billingEmail, prompt: Text("client@example.com"))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .onChange(of: billingEmail) { _ in saveInvoicing() }
                    }
                    FormFieldStacked(label: "CC") {
                        TextField("", text: $billingCc, prompt: Text("extra copies, separated by commas"), axis: .vertical)
                            .lineLimit(1...3)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .onChange(of: billingCc) { _ in saveInvoicing() }
                    }
                    FormField(label: "PO number") {
                        TextField("", text: $poNumber)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .onChange(of: poNumber) { _ in saveInvoicing() }
                    }
                }

                FormSection(title: "Billing rules") {
                    HStack {
                        Text("Round invoiced time")
                        Spacer()
                        Stepper(value: $roundingMinutes, in: 0...60, step: 5) {
                            Text(roundingMinutes == 0 ? "off" : "\(roundingMinutes) min")
                                .monospacedDigit()
                        }
                        .frame(width: 150, alignment: .trailing)
                        .onChange(of: roundingMinutes) { _ in saveBillingRules() }
                    }
                    Toggle("Round up", isOn: $roundUp)
                        .onChange(of: roundUp) { _ in saveBillingRules() }
                        .disabled(roundingMinutes == 0)
                    FormField(label: "Minimum") {
                        TextField("", text: $minimumText, prompt: Text("e.g. 1:00, off"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .multilineTextAlignment(.leading)
                            .onChange(of: minimumText) { _ in saveBillingRules() }
                    }
                    Stepper(value: $eveningPercent, in: 0...200, step: 5) {
                        Text("Evening surcharge: \(eveningPercent) %")
                            .monospacedDigit()
                    }
                    .onChange(of: eveningPercent) { _ in saveBillingRules() }
                    FormField(label: "Evening from") {
                        DatePicker("", selection: $eveningStart, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .onChange(of: eveningStart) { _ in saveBillingRules() }
                    }
                    Stepper(value: $weekendPercent, in: 0...200, step: 5) {
                        Text("Weekend surcharge: \(weekendPercent) %")
                            .monospacedDigit()
                    }
                    .onChange(of: weekendPercent) { _ in saveBillingRules() }
                    Text("Applied when the invoice is built; your recorded time is never changed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                FormSection(title: "Retainer") {
                    FormField(label: "Monthly amount") {
                        TextField("", text: $retainerAmountText, prompt: Text("0.00"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                            .multilineTextAlignment(.leading)
                            .onSubmit { saveRetainer() }
                            .onChange(of: retainerAmountText) { _ in saveRetainer() }
                    }
                    FormField(label: "Description") {
                        TextField("", text: $retainerDescription, prompt: Text("Support contract"))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .onChange(of: retainerDescription) { _ in saveRetainer() }
                    }
                    Toggle("Add to every invoice", isOn: $retainerActive)
                        .onChange(of: retainerActive) { _ in saveRetainer() }
                    Text("A fixed amount per month, put on the invoice automatically. Empty means none.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                FormSection(title: "Networks") {
                    if profile.wifiContexts.isEmpty {
                        Text("No networks linked — the tracker will not start automatically.")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    ForEach(profile.wifiContexts, id: \.self) { context in
                        HStack {
                            Image(systemName: "network")
                                .foregroundStyle(.secondary)
                            Text(context)
                            Spacer()
                            Button {
                                model.removeCustomerContext(profileId: profile.id, context: context)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Unlink network \(context)")
                            .help("Unlink network")
                        }
                    }

                    FormField(label: "Network") {
                        HStack(spacing: 8) {
                            TextField("", text: $newContext, prompt: Text("Wi-Fi SSID or wired DHCP domain"))
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.leading)
                                .onSubmit { addContext() }
                            Button("Link") { addContext() }
                                .disabled(newContext.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }

                FormSection(title: "Location") {
                    if profile.hasLocation, let latitude = profile.latitude, let longitude = profile.longitude {
                        Text(String(format: "%.5f, %.5f", latitude, longitude))
                            .font(.system(.body, design: .monospaced))
                        Stepper(value: $radius, in: 50...2000, step: 50) {
                            Text("Radius: \(radius) m")
                                .monospacedDigit()
                        }
                        .onChange(of: radius) { _ in
                            model.applyCustomerLocation(
                                id: profile.id, latitude: latitude, longitude: longitude, radiusMeters: radius
                            )
                        }
                        Button("Clear location") { model.clearCustomerLocation(id: profile.id) }
                    } else {
                        Text("No location stored. Use this when the client has no linkable Wi-Fi network.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Use current location") { model.setCustomerLocation(id: profile.id, radiusMeters: radius) }
                    }
                    Text("Only used when detection is set to Location.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                FormSection(title: "Projects") {
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

                    FormField(label: "New project") {
                        HStack(spacing: 8) {
                            TextField("", text: $newProjectNumber, prompt: Text("Number"))
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.leading)
                                .frame(width: 90)
                            TextField("", text: $newProjectName, prompt: Text("Project name"))
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.leading)
                                .onSubmit { addProject() }
                            Button("Add") { addProject() }
                                .disabled(newProjectNumber.trimmingCharacters(in: .whitespaces).isEmpty
                                          || newProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }

                FormSection {
                    LabeledContent("Rate", value: rateSummary)
                    Text("Changes are saved immediately.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }

                HStack {
                    Button("Delete customer", role: .destructive) { confirmDelete = true }
                    Spacer()
                }
            }
            .padding(16)
        }
        .onAppear(perform: load)
        .confirmationDialog("Delete \(profile.name) with all projects and blocks?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteCustomer(id: profile.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All projects, blocks and invoices of this customer are removed. Press ⌘Z to undo.")
        }
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
        billingAddress = profile.billingAddress ?? ""
        vatNumber = profile.vatNumber ?? ""
        vatRate = profile.vatRatePercent
        poNumber = profile.poNumber ?? ""
        billingEmail = profile.billingEmail ?? ""
        billingCc = profile.billingCc ?? ""
        radius = profile.presenceRadiusMeters
        travelRateText = profile.travelRateCents > 0 ? Formatting.decimalAmount(cents: profile.travelRateCents) : ""
        commuteRateText = profile.commuteRateCents > 0 ? Formatting.decimalAmount(cents: profile.commuteRateCents) : ""
        if let retainer = model.retainer(for: profile.id) {
            retainerDescription = retainer.description
            retainerAmountText = retainer.amountCents > 0 ? Formatting.decimalAmount(cents: retainer.amountCents) : ""
            retainerActive = retainer.active
        }
        let rules = profile.billingRules
        roundingMinutes = rules.roundingMinutes
        roundUp = rules.roundUp
        minimumText = rules.minimumMinutes > 0
            ? Formatting.duration(TimeInterval(rules.minimumMinutes) * 60)
            : ""
        eveningPercent = rules.eveningSurchargePercent
        weekendPercent = rules.weekendSurchargePercent
        var components = DateComponents()
        components.hour = rules.eveningStartMinutes / 60
        components.minute = rules.eveningStartMinutes % 60
        eveningStart = Formatting.calendar.date(from: components) ?? Date()
        loaded = true
    }

    private func saveBillingRules() {
        guard loaded else { return }
        let trimmed = minimumText.trimmingCharacters(in: .whitespaces)
        var minimum = 0
        if !trimmed.isEmpty {
            guard let parsed = Formatting.parseHoursMinutes(trimmed) else {
                model.errorMessage = "Cannot read the minimum hours: '\(trimmed)'."
                return
            }
            minimum = parsed
        }
        let clock = Formatting.calendar.dateComponents([.hour, .minute], from: eveningStart)
        let eveningStartMinutes = (clock.hour ?? 0) * 60 + (clock.minute ?? 0)
        model.updateBillingRules(
            profileId: profile.id,
            rules: BillingRules(
                roundingMinutes: roundingMinutes,
                roundUp: roundUp,
                minimumMinutes: minimum,
                eveningSurchargePercent: eveningPercent,
                weekendSurchargePercent: weekendPercent,
                eveningStartMinutes: eveningStartMinutes
            )
        )
    }

    private func saveRetainer() {
        guard loaded else { return }
        let trimmed = retainerAmountText.trimmingCharacters(in: .whitespaces)
        let cents: Int
        if trimmed.isEmpty {
            cents = 0
        } else if let parsed = Formatting.parseMoneyCents(trimmed) {
            cents = parsed
        } else {
            model.errorMessage = "Cannot read the retainer amount: '\(trimmed)'."
            return
        }
        if cents == 0 && retainerDescription.trimmingCharacters(in: .whitespaces).isEmpty {
            model.clearRetainer(profileId: profile.id)
        } else {
            model.setRetainer(
                profileId: profile.id,
                description: retainerDescription,
                amountCents: cents,
                active: retainerActive && cents > 0
            )
        }
    }

    /// Travel and commute rates save the same way as the hourly rate: empty means
    /// zero, and unreadable input is left in place with a message.
    private func saveTravelRates() {
        guard loaded else { return }
        func cents(_ text: String, _ label: String) -> Int? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return 0 }
            guard let parsed = Formatting.parseMoneyCents(trimmed) else {
                model.errorMessage = "Cannot read the \(label) rate: '\(trimmed)'."
                return nil
            }
            return parsed
        }
        guard let travel = cents(travelRateText, "travel"), let commute = cents(commuteRateText, "commute") else { return }
        model.updateCustomerTravelRates(id: profile.id, travelRateCents: travel, commuteRateCents: commute)
    }

    private func saveInvoicing() {
        guard loaded else { return }
        model.updateCustomerInvoicing(
            id: profile.id,
            billingAddress: billingAddress,
            vatNumber: vatNumber,
            vatRatePercent: vatRate,
            poNumber: poNumber,
            billingEmail: billingEmail,
            billingCc: billingCc
        )
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
    @State private var billingAddress = ""
    @State private var vatNumber = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            FormSection(title: "Add customer") {
                FormField(label: "Name") {
                    TextField("", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                }
                FormFieldStacked(label: "Wi-Fi networks") {
                    TextField("", text: $contexts, prompt: Text("e.g. Acme-Guest, Acme-Staff"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                }
                Text("Separate multiple networks with a comma.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FormField(label: "Hourly rate") {
                    HStack(spacing: 8) {
                        TextField("", text: $rateText, prompt: Text("0.00"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .multilineTextAlignment(.leading)
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
            }

            FormSection(title: "Invoice details") {
                FormFieldStacked(label: "Billing address") {
                    TextField("", text: $billingAddress, prompt: Text("Street, postal code, city"), axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                }
                FormField(label: "VAT number") {
                    TextField("", text: $vatNumber, prompt: Text("client's VAT number, optional"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
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
                    if model.addCustomer(
                        name: name, contexts: list, hourlyRateCents: cents, currency: currency,
                        billingAddress: billingAddress, vatNumber: vatNumber
                    ) {
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
        .padding(16)
        .frame(width: 480)
    }
}
