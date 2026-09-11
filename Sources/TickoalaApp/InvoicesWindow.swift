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
    @State private var status: String?
    @State private var sendingId: Int64?
    @State private var sendTarget: AppModel.InvoiceCandidate?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.invoiceCandidates().isEmpty {
                Spacer()
                Text("No hours to invoice for \(periodLabel).")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(model.invoiceCandidates()) { candidate in
                            candidateBox(candidate)
                        }
                    }
                    .padding()
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 480)
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
            Text("The invoice PDF is attached. This cannot be undone.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Invoices \(periodLabel)").font(.headline)
                Text("The previous month, ready to send.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let status {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button("Invoice settings") {
                NSApp.activate(ignoringOtherApps: true)
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

    private func candidateBox(_ candidate: AppModel.InvoiceCandidate) -> some View {
        GroupBox {
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

                HStack(spacing: 8) {
                    TextField("PO number", text: poBinding(candidate), prompt: Text("Purchase order, optional"))
                        .frame(maxWidth: 200)
                    TextField("Email", text: emailBinding(candidate), prompt: Text("client@example.com"))
                        .frame(maxWidth: 220)
                }

                HStack(spacing: 8) {
                    Button("Create PDF…") { createPDF(candidate) }
                    Button("Export CSV…") { exportCSV(candidate) }
                    Spacer()
                    if sendingId == candidate.id {
                        ProgressView().controlSize(.small)
                    }
                    Button("Approve & send") { sendTarget = candidate }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSend(candidate) || sendingId != nil)
                }
            }
            .padding(6)
        }
    }

    private var periodLabel: String {
        String(Formatting.day(model.invoicePeriod.start).prefix(7))
    }

    private func summary(_ candidate: AppModel.InvoiceCandidate) -> String {
        let worked = Formatting.decimalHours(candidate.grossSeconds)
        let net = Formatting.decimalHours(candidate.netSeconds)
        let money = candidate.profile.hasHourlyRate
            ? Formatting.money(cents: candidate.amountCents, currency: candidate.profile.currency)
            : "no rate"
        return "\(worked) h worked · \(net) h net · \(money)"
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

    private func email(_ candidate: AppModel.InvoiceCandidate) -> String {
        (emails[candidate.id] ?? candidate.profile.billingEmail ?? "").trimmingCharacters(in: .whitespaces)
    }

    private func canSend(_ candidate: AppModel.InvoiceCandidate) -> Bool {
        model.invoiceSettings().canSendEmail && !email(candidate).isEmpty
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
        guard let invoice = model.makeInvoice(profileId: candidate.profile.id, poNumber: po(candidate)) else { return }
        if model.write(invoice, to: url) {
            status = "Invoice \(invoice.number) saved."
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

    private func send(_ candidate: AppModel.InvoiceCandidate) {
        let recipient = email(candidate)
        guard !recipient.isEmpty else {
            status = "No email address for \(candidate.profile.name)."
            return
        }
        guard let invoice = model.makeInvoice(profileId: candidate.profile.id, poNumber: po(candidate)) else { return }
        sendingId = candidate.id
        status = "Sending invoice \(invoice.number)…"
        Task {
            do {
                try await model.sendInvoice(invoice, to: recipient)
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