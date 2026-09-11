import AppKit
import SwiftUI
import TickoalaCore

/// Sender details, payment term, numbering and logo used on every invoice.
struct InvoiceSettingsWindow: View {
    @ObservedObject var model: AppModel

    @State private var settings = InvoiceSettings.default
    @State private var loaded = false
    @State private var password = ""
    @State private var testStatus: String?
    @State private var sendingTest = false

    var body: some View {
        Form {
            Section("Sender") {
                TextField("Name", text: binding(\.senderName))
                TextField("Address", text: binding(\.senderAddress), axis: .vertical)
                    .lineLimit(3...5)
                TextField("KvK number", text: binding(\.senderKvk))
                TextField("VAT number", text: binding(\.senderVatNumber))
                TextField("IBAN", text: binding(\.senderIban))
                TextField("Email", text: binding(\.senderEmail))
            }

            Section("Payment") {
                Stepper(value: binding(\.paymentTermDays), in: 0...120) {
                    Text("Pay within \(settings.paymentTermDays) days")
                        .monospacedDigit()
                }
            }

            Section("Numbering") {
                TextField("Prefix", text: binding(\.invoiceNumberPrefix), prompt: Text("e.g. 2026-"))
                Stepper(value: binding(\.nextInvoiceNumber), in: 1...100000) {
                    Text("Next number: \(settings.nextNumberText)")
                        .monospacedDigit()
                }
                Text("Each customer and month gets one number. Reopening the same month keeps its number.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Email (SMTP)") {
                TextField("Server", text: binding(\.smtpHost), prompt: Text("smtp.example.com"))
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("", value: binding(\.smtpPort), format: .number)
                        .labelsHidden()
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
                TextField("Username", text: binding(\.smtpUsername))
                TextField("From address", text: binding(\.smtpFromEmail), prompt: Text("you@example.com"))
                Toggle("Use TLS (port 465)", isOn: binding(\.smtpUseTLS))
                SecureField("Password", text: $password)
                    .onSubmit { Keychain.setSMTPPassword(password) }
                HStack {
                    Text("The password is stored in the macOS Keychain, not in the database.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if sendingTest {
                        ProgressView().controlSize(.small)
                    }
                    Button("Test") { sendTest() }
                        .disabled(sendingTest || settings.smtpFromEmail.isEmpty)
                }
                if let testStatus {
                    Text(testStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Logo") {
                HStack {
                    if let logo = InvoicePDF.logoImage(settings) {
                        Image(nsImage: logo)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 160, maxHeight: 60)
                    } else {
                        Text("No logo")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose…") { chooseLogo() }
                    if settings.logoFileName != nil {
                        Button("Remove") { removeLogo() }
                    }
                }
            }

            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 520)
        .onAppear(perform: load)
        // Also store the password when the window closes, in case Return was
        // never pressed.
        .onDisappear { Keychain.setSMTPPassword(password) }
    }

    /// Writes on every change, like the other windows.
    private func binding<T>(_ keyPath: WritableKeyPath<InvoiceSettings, T>) -> Binding<T> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { settings[keyPath: keyPath] = $0; save() }
        )
    }

    private func load() {
        guard !loaded else { return }
        settings = model.invoiceSettings()
        password = Keychain.smtpPassword()
        loaded = true
    }

    private func save() {
        guard loaded else { return }
        model.saveInvoiceSettings(settings)
    }

    private func sendTest() {
        Keychain.setSMTPPassword(password)
        sendingTest = true
        testStatus = nil
        let recipient = settings.smtpFromEmail
        Task {
            do {
                try await model.sendTestEmail(to: recipient)
                testStatus = "Test message sent to \(recipient)."
            } catch {
                testStatus = "Test failed: \(error)"
            }
            sendingTest = false
        }
    }

    private func chooseLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .pdf]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a logo for the invoice"
        guard panel.runModal() == .OK, let url = panel.url, let directory = try? Store.supportDirectory() else { return }
        removeLogoFiles(in: directory)
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let name = "logo.\(ext)"
        do {
            try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(name))
            settings.logoFileName = name
            save()
        } catch {
            model.errorMessage = "Could not store the logo: \(error)"
        }
    }

    private func removeLogo() {
        settings.logoFileName = nil
        save()
        if let directory = try? Store.supportDirectory() {
            removeLogoFiles(in: directory)
        }
    }

    private func removeLogoFiles(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("logo.") {
            try? FileManager.default.removeItem(at: file)
        }
    }
}