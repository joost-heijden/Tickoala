import AppKit
import SwiftUI
import TickoalaCore

/// Expenses and mileage per customer. Billable entries are added to that
/// customer's invoice on top of the hours.
struct ExpensesWindow: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    @State private var showingAdd = false
    @State private var editing: Expense?
    @State private var deleting: Expense?
    @State private var kmRateText = ""

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
                content(for: profileId)
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .tickoalaWindowBackground()
        .onAppear(perform: loadKmRate)
        .onChange(of: profileId) { _ in loadKmRate() }
        .sheet(isPresented: $showingAdd) {
            if let profileId {
                ExpenseSheet(model: model, profileId: profileId, expense: nil) { showingAdd = false }
            }
        }
        .sheet(item: $editing) { expense in
            ExpenseSheet(model: model, profileId: expense.profileId, expense: expense) { editing = nil }
        }
        .confirmationDialog(
            "Delete expense \(deleting?.description ?? "")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let target = deleting { model.deleteExpense(id: target.id) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("It is removed from the invoice of this customer.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Customer", selection: Binding(
                get: { profileId },
                set: { model.selectedCustomerId = $0; loadKmRate() }
            )) {
                ForEach(model.profiles, id: \.profile.id) { item in
                    Text(item.profile.name).tag(Int64?.some(item.profile.id))
                }
            }
            .frame(maxWidth: 260)

            FormField(label: "Mileage rate", labelWidth: 90) {
                HStack(spacing: 4) {
                    FormTextField(text: $kmRateText, prompt: "0.23")
                        .frame(width: 70)
                    Text("/ km").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 240)
            .onSubmit { saveKmRate() }

            Spacer()

            Button("Customers") {
                NSApp.activateForUI()
                openWindow(id: "customers")
            }
            .fixedSize()

            Button {
                showingAdd = true
            } label: {
                Label("Add expense", systemImage: "plus")
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
            Button("Manage customers") {
                NSApp.activateForUI()
                openWindow(id: "customers")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func content(for profileId: Int64) -> some View {
        let expenses = model.expenses(for: profileId)
        return Group {
            if expenses.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("No expenses for this customer yet.")
                        .font(.headline)
                    Text("Parking, materials, or a mileage claim; billable entries are added to the invoice.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Add expense") { showingAdd = true }
                        .padding(.top, 4)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                Table(expenses) {
                    TableColumn("Date") { Text(Formatting.day($0.date)) }.width(90)
                    TableColumn("Description") { Text($0.description) }.width(min: 160, ideal: 240)
                    TableColumn("Kind") { Text($0.kind.label) }.width(70)
                    TableColumn("Qty") { expense in
                        Text(expense.kind == .mileage ? "\(Formatting.quantity(expense.quantity)) km" : "—")
                    }.width(70)
                    TableColumn("Rate") { expense in
                        Text(expense.unitRateCents > 0
                             ? Formatting.money(cents: expense.unitRateCents, currency: model.selectedCustomer?.currency ?? .eur)
                             : "—")
                    }.width(70)
                    TableColumn("Amount") { expense in
                        Text(Formatting.money(cents: expense.amountCents, currency: model.selectedCustomer?.currency ?? .eur))
                    }.width(90)
                    TableColumn("Invoice") { expense in
                        Image(systemName: expense.billable ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(expense.billable ? .green : .secondary)
                            .help(expense.billable ? "Added to the invoice" : "Not invoiced")
                    }.width(60)
                    TableColumn("") { expense in
                        HStack(spacing: 6) {
                            Button { editing = expense } label: { Image(systemName: "pencil") }
                                .accessibilityLabel("Edit expense")
                                .help("Edit")
                            Button { deleting = expense } label: { Image(systemName: "trash") }
                                .accessibilityLabel("Delete expense")
                                .help("Delete")
                        }
                    }
                    .width(60)
                }
                .tableStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func loadKmRate() {
        guard let profileId, let profile = model.profile(id: profileId) else {
            kmRateText = ""
            return
        }
        kmRateText = profile.kmRateCents > 0 ? Formatting.decimalAmount(cents: profile.kmRateCents) : ""
    }

    private func saveKmRate() {
        guard let profileId else { return }
        let trimmed = kmRateText.trimmingCharacters(in: .whitespaces)
        let cents = trimmed.isEmpty ? 0 : (Formatting.parseMoneyCents(trimmed) ?? -1)
        guard cents >= 0 else {
            model.errorMessage = "Enter the mileage rate as an amount, for example 0.23."
            return
        }
        model.setCustomerKmRate(id: profileId, cents: cents)
        loadKmRate()
    }
}

/// Add or edit one expense or mileage claim.
private struct ExpenseSheet: View {
    @ObservedObject var model: AppModel
    let profileId: Int64
    let expense: Expense?
    var onClose: () -> Void

    @State private var kind: ExpenseKind
    @State private var date: Date
    @State private var description: String
    @State private var amountText: String
    @State private var kmText: String
    @State private var rateText: String
    @State private var billable: Bool
    @State private var note: String

    init(model: AppModel, profileId: Int64, expense: Expense?, onClose: @escaping () -> Void) {
        self.model = model
        self.profileId = profileId
        self.expense = expense
        self.onClose = onClose
        let profile = model.profile(id: profileId)
        _kind = State(initialValue: expense?.kind ?? .expense)
        _date = State(initialValue: expense?.date ?? Date())
        _description = State(initialValue: expense?.description ?? "")
        _amountText = State(initialValue: expense.map { Formatting.decimalAmount(cents: $0.amountCents) } ?? "")
        _kmText = State(initialValue: (expense?.kind == .mileage) ? Formatting.quantity(expense?.quantity ?? 0) : "")
        _rateText = State(initialValue: {
            if let expense, expense.kind == .mileage, expense.unitRateCents > 0 {
                return Formatting.decimalAmount(cents: expense.unitRateCents)
            }
            if let rate = profile?.kmRateCents, rate > 0 { return Formatting.decimalAmount(cents: rate) }
            return ""
        }())
        _billable = State(initialValue: expense?.billable ?? true)
        _note = State(initialValue: expense?.note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FormSection(title: expense == nil ? "Add expense" : "Edit expense") {
                Picker("Kind", selection: $kind) {
                    ForEach(ExpenseKind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                DatePicker("Date", selection: $date, displayedComponents: .date)

                FormField(label: "Description") {
                    FormTextField(text: $description, prompt: "Parking, materials, travel…")
                }

                if kind == .expense {
                    FormField(label: "Amount") {
                        FormTextField(text: $amountText, prompt: "12.50")
                    }
                } else {
                    FormField(label: "Kilometres") {
                        FormTextField(text: $kmText, prompt: "120")
                    }
                    FormField(label: "Rate per km") {
                        FormTextField(text: $rateText, prompt: "0.23")
                    }
                    Text("Amount: \(Formatting.money(cents: mileageCents, currency: model.selectedCustomer?.currency ?? .eur))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Toggle("Add to the invoice", isOn: $billable)

                FormField(label: "Note") {
                    FormTextField(text: $note, prompt: "optional")
                }
            }

            if let error = model.errorMessage, !error.isEmpty, !isValid {
                Text(error).foregroundStyle(.red)
            }

            HStack {
                Button(expense == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
                Button("Cancel", role: .cancel) { onClose() }
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    private var mileageCents: Int {
        let km = Double(kmText.replacingOccurrences(of: ",", with: ".")) ?? 0
        let rate = Formatting.parseMoneyCents(rateText) ?? 0
        return Expense.mileageAmountCents(kilometres: km, rateCentsPerKm: rate)
    }

    private var isValid: Bool {
        guard !description.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch kind {
        case .expense:
            return (Formatting.parseMoneyCents(amountText) ?? 0) > 0
        case .mileage:
            let km = Double(kmText.replacingOccurrences(of: ",", with: ".")) ?? 0
            return km > 0 && (Formatting.parseMoneyCents(rateText) ?? 0) > 0
        }
    }

    private func save() {
        let km = Double(kmText.replacingOccurrences(of: ",", with: ".")) ?? 0
        let rate = Formatting.parseMoneyCents(rateText) ?? 0
        let amount = Formatting.parseMoneyCents(amountText) ?? 0
        if let expense {
            model.updateExpense(
                id: expense.id, date: date, description: description, kind: kind,
                quantity: km, unitRateCents: rate, amountCents: amount, billable: billable, note: note
            )
        } else {
            guard model.addExpense(
                profileId: profileId, date: date, description: description, kind: kind,
                quantity: km, unitRateCents: rate, amountCents: amount, billable: billable, note: note
            ) else { return }
        }
        onClose()
    }
}
