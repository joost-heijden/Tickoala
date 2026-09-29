import AppKit
import SwiftUI
import TickoalaCore

/// The monthly invoices: what the reminder opens. Per customer a PO field, an
/// email address, and buttons to save the PDF, export the hours, or send it.
struct InvoicesWindow: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    @State private var poNumbers: [Int64: String] = [:]
    @State private var emails: [Int64: String] = [:]
    @State private var attachCSV: [Int64: Bool] = [:]
    @State private var status: String?
    @State private var sendingId: Int64?
    @State private var sendTarget: AppModel.InvoiceCandidate?
    @State private var deleteTarget: Store.IssuedInvoice?
    @State private var showHistory = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    let candidates = model.invoiceCandidates()
                    if candidates.isEmpty {
                        Text("No hours to invoice for \(periodLabel).")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    } else {
                        ForEach(candidates) { candidate in
                            candidateBox(candidate)
                        }
                    }
                    historySection
                }
                .padding()
            }
            Divider()
            footer
        }
        // Narrower and the history row is wider than the pane, clipping its left.
        .frame(minWidth: 760, minHeight: 480)
        .tickoalaWindowBackground()
        .onAppear(perform: loadFields)
        .confirmationDialog(
            "Send invoice to \(sendTarget?.profile.name ?? "")?",
            isPresented: Binding(get: { sendTarget != nil }, set: { if !$0 { sendTarget = nil } }),
            titleVisibility: .visible
        ) {
            if let target = sendTarget {
                Button("Send to \(email(target))") {
                    let candidate = target
                    sendTarget = nil
                    send(candidate)
                }
            }
            Button("Cancel", role: .cancel) { sendTarget = nil }
        } message: {
            Text(includeCSV(sendTarget)
                ? "The invoice PDF and the hours CSV are attached. This cannot be undone."
                : "The invoice PDF is attached. This cannot be undone.")
        }
        .alert(
            "Delete invoice \(deleteTarget?.number ?? "")?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let target = deleteTarget { model.deleteInvoice(target) }
                deleteTarget = nil
                status = "Invoice removed from the history."
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Removes it from the history. The recorded hours stay, so you can issue it again.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Invoices").font(.headline)
                    Button { model.shiftInvoicePeriod(-1) } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .help("Previous period")
                    Text(periodLabel).font(.headline).monospacedDigit()
                    Button { model.shiftInvoicePeriod(1) } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .help("Next period")
                }
                Text(periodCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: periodKindBinding) {
                ForEach(InvoicePeriodKind.allCases, id: \.self) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("How much time one invoice covers")
            if let status {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button("Invoice settings") {
                NSApp.activateForUI()
                openWindow(id: "invoice-settings")
            }
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            if model.invoiceSettings().senderName.isEmpty {
                Text("⚠︎ Fill in your sender details first, otherwise the invoice has no address.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if !model.invoiceSettings().canSendEmail {
                Text("Set the SMTP server under Invoice settings to send invoices by email.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Tip: close this window when you are done; it reopens automatically on the 1st.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
    }

    /// Every invoice ever issued, so past months stay findable. Clicking the row
    /// jumps the window to that month; the buttons rebuild the PDF, export the
    /// hours, or send the invoice again.
    @ViewBuilder
    private var historySection: some View {
        let invoices = model.issuedInvoices()
        if !invoices.isEmpty {
            DisclosureGroup(isExpanded: $showHistory) {
                VStack(spacing: 0) {
                    ForEach(invoices) { invoice in
                        HStack(spacing: 8) {
                            Button {
                                model.showInvoicePeriod(DateRange(start: invoice.periodStart, end: invoice.periodEnd))
                            } label: {
                                HStack(spacing: 10) {
                                    Text(historyLabel(invoice))
                                        .monospacedDigit()
                                        .frame(width: 150, alignment: .leading)
                                    Text(invoice.profileName).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text("Invoice \(invoice.number)")
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .fixedSize()
                                    Text(Formatting.money(cents: invoice.totalCents, currency: invoice.currency))
                                        .monospacedDigit()
                                        .frame(width: 100, alignment: .trailing)
                                    Text(Formatting.day(invoice.issuedAt))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                        .frame(width: 90, alignment: .trailing)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Show the period of this invoice")

                            if sendingId == invoice.profileId {
                                ProgressView().controlSize(.small)
                            }
                            Button("PDF…") { saveHistoryPDF(invoice) }
                            Button("UBL…") { saveHistoryUBL(invoice) }
                            Button("CSV…") { exportHistoryCSV(invoice) }
                            Button("Resend…") { resendHistory(invoice) }
                            Button {
                                deleteTarget = invoice
                            } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("Delete invoice \(invoice.number)")
                            .help("Delete this invoice from the history")
                        }
                        .controlSize(.small)
                        .disabled(sendingId != nil)
                        .padding(.vertical, 3)
                        Divider()
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Invoice history (\(invoices.count))").font(.headline)
            }
            .padding(.top, 8)
        }
    }

    private func candidateBox(_ candidate: AppModel.InvoiceCandidate) -> some View {
        FormSection {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(candidate.profile.name).font(.headline)
                    Spacer()
                    if let number = candidate.number {
                        Text("Invoice \(number)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(summary(candidate))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                let missing = missingFields(candidate)
                if !missing.isEmpty {
                    Text("⚠︎ Not ready to invoice: fill in \(missing.joined(separator: ", ")).")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 8) {
                    TextField("PO number", text: poBinding(candidate), prompt: Text("Purchase order, optional"))
                        .frame(maxWidth: 200)
                    TextField("Email", text: emailBinding(candidate), prompt: Text("client@example.com"))
                        .frame(maxWidth: 220)
                }

                HStack(spacing: 8) {
                    Button("Create PDF…") { createPDF(candidate) }
                        .disabled(!missing.isEmpty)
                    Button("Export UBL…") { exportUBL(candidate) }
                        .disabled(!missing.isEmpty)
                        .help("Peppol/UBL invoice for your bookkeeping")
                    Button("Export CSV…") { exportCSV(candidate) }
                    Spacer()
                    Toggle("Include hours CSV", isOn: csvBinding(candidate))
                        .toggleStyle(.checkbox)
                    if sendingId == candidate.id {
                        ProgressView().controlSize(.small)
                    }
                    Button("Approve & send") { sendTarget = candidate }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!missing.isEmpty || !canSend(candidate) || sendingId != nil)
                }
            }
        }
    }

    private var periodKindBinding: Binding<InvoicePeriodKind> {
        Binding(
            get: { model.invoicePeriodKind },
            set: { model.setInvoicePeriodKind($0) }
        )
    }

    private var periodLabel: String {
        let range = model.invoicePeriod
        switch model.invoicePeriodKind {
        case .month:
            return String(Formatting.day(range.start).prefix(7))
        case .week, .twoWeeks:
            let last = Formatting.calendar.date(byAdding: .day, value: -1, to: range.end) ?? range.end
            return "\(Formatting.day(range.start)) – \(Formatting.day(last))"
        }
    }

    private var periodCaption: String {
        let kind = model.invoicePeriodKind
        if model.invoicePeriod.start == kind.shifted(-1, from: Date()).start {
            return "The previous \(kind.noun), ready to send."
        }
        if model.invoicePeriod.start == kind.range(containing: Date()).start {
            return "This \(kind.noun) so far, ready to send."
        }
        return "Manually chosen \(kind.noun), ready to send."
    }

    private func summary(_ candidate: AppModel.InvoiceCandidate) -> String {
        let worked = Formatting.decimalHours(candidate.grossSeconds)
        let net = Formatting.decimalHours(candidate.netSeconds)
        let money = candidate.profile.hasHourlyRate
            ? Formatting.money(cents: candidate.amountCents - candidate.expensesCents, currency: candidate.profile.currency)
            : "no rate"
        var line = "\(worked) h worked · \(net) h net · \(money)"
        if candidate.expensesCents > 0 {
            line += " + \(Formatting.money(cents: candidate.expensesCents, currency: candidate.profile.currency)) expenses"
        }
        return line
    }

    private func poBinding(_ candidate: AppModel.InvoiceCandidate) -> Binding<String> {
        Binding(
            get: { poNumbers[candidate.id] ?? candidate.profile.poNumber ?? "" },
            set: { poNumbers[candidate.id] = $0 }
        )
    }

    private func emailBinding(_ candidate: AppModel.InvoiceCandidate) -> Binding<String> {
        Binding(
            get: { emails[candidate.id] ?? candidate.profile.billingEmail ?? "" },
            set: { emails[candidate.id] = $0 }
        )
    }

    private func csvBinding(_ candidate: AppModel.InvoiceCandidate) -> Binding<Bool> {
        Binding(
            get: { includeCSV(candidate) },
            set: { attachCSV[candidate.id] = $0 }
        )
    }

    private func includeCSV(_ candidate: AppModel.InvoiceCandidate?) -> Bool {
        guard let candidate else { return false }
        return attachCSV[candidate.id] ?? model.invoiceSettings().attachHoursCSV
    }

    private func email(_ candidate: AppModel.InvoiceCandidate) -> String {
        (emails[candidate.id] ?? candidate.profile.billingEmail ?? "").trimmingCharacters(in: .whitespaces)
    }

    private func canSend(_ candidate: AppModel.InvoiceCandidate) -> Bool {
        model.invoiceSettings().canSendEmail && !email(candidate).isEmpty
    }

    /// Invoice details the Belastingdienst requires that are still blank for this
    /// customer, so it is clear why a PDF is refused.
    private func missingFields(_ candidate: AppModel.InvoiceCandidate) -> [String] {
        Invoicing.missingRequiredFields(profile: candidate.profile, sender: model.invoiceSettings())
    }

    private func loadFields() {
        for candidate in model.invoiceCandidates() {
            if poNumbers[candidate.id] == nil { poNumbers[candidate.id] = candidate.profile.poNumber ?? "" }
            if emails[candidate.id] == nil { emails[candidate.id] = candidate.profile.billingEmail ?? "" }
        }
    }

    private func createPDF(_ candidate: AppModel.InvoiceCandidate) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = pdfName(candidate)
        panel.message = "Save the invoice for \(candidate.profile.name)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let invoice = model.makeInvoice(profileId: candidate.profile.id, poNumber: po(candidate)) else {
            status = model.errorMessage ?? "Could not build the invoice."
            return
        }
        if model.write(invoice, to: url) {
            status = "Invoice \(invoice.number) saved."
        }
        model.refresh()
        loadFields()
    }

    private func exportUBL(_ candidate: AppModel.InvoiceCandidate) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.xml]
        panel.nameFieldStringValue = ublName(candidate)
        panel.message = "Save the UBL/Peppol invoice for \(candidate.profile.name)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let invoice = model.makeInvoice(profileId: candidate.profile.id, poNumber: po(candidate)) else {
            status = model.errorMessage ?? "Could not build the invoice."
            return
        }
        if model.writeUBL(invoice, to: url) {
            status = "UBL \(invoice.number) saved."
        }
        model.refresh()
        loadFields()
    }

    private func exportCSV(_ candidate: AppModel.InvoiceCandidate) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "hours-\(safeName(candidate.profile.name))-\(periodLabel).csv"
        panel.message = "Export the hours of \(candidate.profile.name) for \(periodLabel)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if model.exportMonthlyCSV(profileId: candidate.profile.id, to: url) {
            status = "CSV saved."
        }
    }

    private func historyPeriod(_ invoice: Store.IssuedInvoice) -> DateRange {
        DateRange(start: invoice.periodStart, end: invoice.periodEnd)
    }

    /// How a stored invoice's period reads in the history list.
    private func historyLabel(_ invoice: Store.IssuedInvoice) -> String {
        let range = historyPeriod(invoice)
        guard InvoicePeriodKind.matching(start: range.start, end: range.end) == .month else {
            let last = Formatting.calendar.date(byAdding: .day, value: -1, to: range.end) ?? range.end
            return "\(Formatting.day(range.start)) – \(Formatting.day(last))"
        }
        return String(Formatting.day(range.start).prefix(7))
    }

    /// A short, file-name-safe tag for a stored invoice's period.
    private func fileLabel(_ invoice: Store.IssuedInvoice) -> String {
        Invoicing.periodTag(start: invoice.periodStart, end: invoice.periodEnd)
    }

    private func saveHistoryPDF(_ item: Store.IssuedInvoice) {
        guard let invoice = model.makeInvoice(
            profileId: item.profileId, period: historyPeriod(item), poNumber: item.poNumber
        ) else {
            status = model.errorMessage ?? "Could not rebuild the invoice."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "invoice-\(item.number)-\(safeName(item.profileName)).pdf"
        panel.message = "Save the invoice for \(item.profileName)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if model.write(invoice, to: url) {
            status = "Invoice \(invoice.number) saved."
            NSWorkspace.shared.open(url)
        }
        model.refresh()
        loadFields()
    }

    private func saveHistoryUBL(_ item: Store.IssuedInvoice) {
        guard let invoice = model.makeInvoice(
            profileId: item.profileId, period: historyPeriod(item), poNumber: item.poNumber
        ) else {
            status = model.errorMessage ?? "Could not rebuild the invoice."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.xml]
        panel.nameFieldStringValue = "invoice-\(item.number)-\(safeName(item.profileName)).xml"
        panel.message = "Save the UBL/Peppol invoice for \(item.profileName)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if model.writeUBL(invoice, to: url) {
            status = "UBL \(invoice.number) saved."
            NSWorkspace.shared.open(url)
        }
        model.refresh()
        loadFields()
    }

    private func exportHistoryCSV(_ item: Store.IssuedInvoice) {
        let label = fileLabel(item)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "hours-\(safeName(item.profileName))-\(label).csv"
        panel.message = "Export the hours of \(item.profileName) for \(label)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if model.exportMonthlyCSV(profileId: item.profileId, period: historyPeriod(item), to: url) {
            status = "CSV saved."
        }
    }

    private func resendHistory(_ item: Store.IssuedInvoice) {
        model.showInvoicePeriod(historyPeriod(item))
        if let candidate = model.invoiceCandidates().first(where: { $0.id == item.profileId }) {
            sendTarget = candidate
        } else {
            status = "No invoice to rebuild for \(item.profileName)."
        }
    }

    private func send(_ candidate: AppModel.InvoiceCandidate) {
        let recipient = email(candidate)
        guard !recipient.isEmpty else {
            status = "No email address for \(candidate.profile.name)."
            return
        }
        guard let invoice = model.makeInvoice(profileId: candidate.profile.id, poNumber: po(candidate)) else {
            status = model.errorMessage ?? "Could not build the invoice."
            return
        }
        sendingId = candidate.id
        status = "Sending invoice \(invoice.number)…"
        let csv = includeCSV(candidate)
        Task {
            do {
                try await model.sendInvoice(invoice, to: recipient, attachCSV: csv)
                status = "Invoice \(invoice.number) sent to \(recipient)."
            } catch {
                status = "Sending failed: \(error)"
            }
            sendingId = nil
            model.refresh()
            loadFields()
        }
    }

    private func po(_ candidate: AppModel.InvoiceCandidate) -> String? {
        let value = (poNumbers[candidate.id] ?? "").trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private func ublName(_ candidate: AppModel.InvoiceCandidate) -> String {
        let client = safeName(candidate.profile.name)
        if let number = candidate.number {
            return "invoice-\(number)-\(client).xml"
        }
        return "invoice-\(client)-\(periodLabel).xml"
    }

    private func pdfName(_ candidate: AppModel.InvoiceCandidate) -> String {
        let client = safeName(candidate.profile.name)
        if let number = candidate.number {
            return "invoice-\(number)-\(client).pdf"
        }
        return "invoice-\(client)-\(periodLabel).pdf"
    }

    private func safeName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}