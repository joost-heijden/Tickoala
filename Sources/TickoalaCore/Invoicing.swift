import Foundation

/// Sender details and numbering for the invoice, shared by every client. Stored
/// as JSON in the `settings` table, so it needs no schema of its own.
public struct InvoiceSettings: Equatable, Sendable, Codable {
    public var senderName: String
    public var senderAddress: String
    public var senderKvk: String
    public var senderVatNumber: String
    public var senderIban: String
    public var senderEmail: String
    /// Days between the invoice date and the due date.
    public var paymentTermDays: Int
    /// Optional prefix for the invoice number, for example `2026-`.
    public var invoiceNumberPrefix: String
    /// The next number to hand out. Never lowered automatically.
    public var nextInvoiceNumber: Int
    /// File name of a logo in Tickoala's support folder, shown on the invoice.
    public var logoFileName: String?
    /// SMTP server for sending the invoice straight from the app. The password
    /// is deliberately not here: it lives in the macOS Keychain.
    public var smtpHost: String
    public var smtpPort: Int
    public var smtpUsername: String
    public var smtpFromEmail: String
    /// Implicit TLS (SMTPS). True for port 465; STARTTLS on 587 is not supported.
    public var smtpUseTLS: Bool

    public static let `default` = InvoiceSettings()

    public init(
        senderName: String = "",
        senderAddress: String = "",
        senderKvk: String = "",
        senderVatNumber: String = "",
        senderIban: String = "",
        senderEmail: String = "",
        paymentTermDays: Int = 30,
        invoiceNumberPrefix: String = "",
        nextInvoiceNumber: Int = 1,
        logoFileName: String? = nil,
        smtpHost: String = "",
        smtpPort: Int = 465,
        smtpUsername: String = "",
        smtpFromEmail: String = "",
        smtpUseTLS: Bool = true
    ) {
        self.senderName = senderName
        self.senderAddress = senderAddress
        self.senderKvk = senderKvk
        self.senderVatNumber = senderVatNumber
        self.senderIban = senderIban
        self.senderEmail = senderEmail
        self.paymentTermDays = paymentTermDays
        self.invoiceNumberPrefix = invoiceNumberPrefix
        self.nextInvoiceNumber = nextInvoiceNumber
        self.logoFileName = logoFileName
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpUsername = smtpUsername
        self.smtpFromEmail = smtpFromEmail
        self.smtpUseTLS = smtpUseTLS
    }

    /// Can an invoice be emailed? Host and a from-address are the minimum; the
    /// password is checked separately in the Keychain.
    public var canSendEmail: Bool {
        !smtpHost.trimmingCharacters(in: .whitespaces).isEmpty
            && !smtpFromEmail.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The number that `nextInvoiceNumber` will produce.
    public var nextNumberText: String {
        String(format: "%@%04d", invoiceNumberPrefix, max(1, nextInvoiceNumber))
    }

    /// Tolerant decoding: missing keys fall back to the default, so a settings
    /// blob written by an older build keeps working when fields are added.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = InvoiceSettings.default
        senderName = try container.decodeIfPresent(String.self, forKey: .senderName) ?? fallback.senderName
        senderAddress = try container.decodeIfPresent(String.self, forKey: .senderAddress) ?? fallback.senderAddress
        senderKvk = try container.decodeIfPresent(String.self, forKey: .senderKvk) ?? fallback.senderKvk
        senderVatNumber = try container.decodeIfPresent(String.self, forKey: .senderVatNumber) ?? fallback.senderVatNumber
        senderIban = try container.decodeIfPresent(String.self, forKey: .senderIban) ?? fallback.senderIban
        senderEmail = try container.decodeIfPresent(String.self, forKey: .senderEmail) ?? fallback.senderEmail
        paymentTermDays = try container.decodeIfPresent(Int.self, forKey: .paymentTermDays) ?? fallback.paymentTermDays
        invoiceNumberPrefix = try container.decodeIfPresent(String.self, forKey: .invoiceNumberPrefix) ?? fallback.invoiceNumberPrefix
        nextInvoiceNumber = try container.decodeIfPresent(Int.self, forKey: .nextInvoiceNumber) ?? fallback.nextInvoiceNumber
        logoFileName = try container.decodeIfPresent(String.self, forKey: .logoFileName) ?? fallback.logoFileName
        smtpHost = try container.decodeIfPresent(String.self, forKey: .smtpHost) ?? fallback.smtpHost
        smtpPort = try container.decodeIfPresent(Int.self, forKey: .smtpPort) ?? fallback.smtpPort
        smtpUsername = try container.decodeIfPresent(String.self, forKey: .smtpUsername) ?? fallback.smtpUsername
        smtpFromEmail = try container.decodeIfPresent(String.self, forKey: .smtpFromEmail) ?? fallback.smtpFromEmail
        smtpUseTLS = try container.decodeIfPresent(Bool.self, forKey: .smtpUseTLS) ?? fallback.smtpUseTLS
    }
}

/// One line of the invoice: a project, or the automatic break deduction.
public struct InvoiceLine: Equatable, Sendable {
    public var label: String
    /// Recorded seconds; negative for the break deduction.
    public var seconds: TimeInterval
    public var hourlyRateCents: Int
    public var amountCents: Int

    public var isDeduction: Bool { seconds < 0 }
}

/// Everything the PDF and the CLI need, fully computed.
public struct Invoice: Equatable, Sendable {
    public var number: String
    public var poNumber: String?
    public var sender: InvoiceSettings
    public var profile: Profile
    public var periodStart: Date
    public var periodEnd: Date
    public var issuedAt: Date
    public var dueAt: Date
    public var lines: [InvoiceLine]
    /// Net seconds invoiced (after break deduction).
    public var netSeconds: TimeInterval
    public var subtotalCents: Int
    public var vatRatePercent: Int
    public var vatCents: Int
    public var totalCents: Int
    public var currency: Currency
}

public enum Invoicing {
    /// The day the reminder appears: the first weekday of the month. If the 1st
    /// is on a Saturday or Sunday, it slides to the Monday after.
    public static func reminderDate(
        forMonthContaining date: Date,
        calendar: Calendar = Formatting.calendar
    ) -> Date {
        let first = calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        switch calendar.component(.weekday, from: first) {
        case 1: return calendar.date(byAdding: .day, value: 1, to: first) ?? first // Sunday → Monday
        case 7: return calendar.date(byAdding: .day, value: 2, to: first) ?? first // Saturday → Monday
        default: return first
        }
    }

    /// True from the first weekday of this month until the end of that month.
    public static func isReminderDue(
        now: Date = Date(),
        calendar: Calendar = Formatting.calendar
    ) -> Bool {
        let interval = calendar.dateInterval(of: .month, for: now)
        let reminder = reminderDate(forMonthContaining: now, calendar: calendar)
        guard let end = interval?.end else { return false }
        return now >= reminder && now < end
    }

    /// The month before the one `date` falls in, as a half-open range.
    public static func previousMonthRange(
        containing date: Date,
        calendar: Calendar = Formatting.calendar
    ) -> DateRange {
        let previous = calendar.date(byAdding: .month, value: -1, to: date) ?? date
        return Reporting.range(.month, containing: previous, calendar: calendar)
    }

    /// Builds the invoice for one client and one month. The number is allocated
    /// on first generation and reused afterwards, so the same month can never
    /// produce a duplicate.
    public static func invoice(
        store: Store,
        profileId: Int64,
        period: DateRange,
        poNumber: String? = nil,
        issuedAt: Date = Date(),
        now: Date = Date(),
        calendar: Calendar = Formatting.calendar
    ) throws -> Invoice {
        guard let profile = try store.profile(id: profileId) else {
            throw TrackerError.unknownProfile(String(profileId))
        }
        let report = try Reporting.report(
            store: store,
            period: .month,
            containing: period.start,
            profileId: profileId,
            now: now,
            calendar: calendar
        )

        let rate = profile.hourlyRateCents
        func amount(_ seconds: TimeInterval) -> Int {
            guard rate > 0 else { return 0 }
            return Int((seconds / 3600 * Double(rate)).rounded())
        }

        var lines = report.byProject.map { item in
            InvoiceLine(
                label: item.label,
                seconds: item.total,
                hourlyRateCents: rate,
                amountCents: amount(item.total)
            )
        }
        if report.breakDeduction > 0 {
            lines.append(InvoiceLine(
                label: "Automatic break deduction",
                seconds: -report.breakDeduction,
                hourlyRateCents: rate,
                amountCents: amount(-report.breakDeduction)
            ))
        }
        if lines.isEmpty {
            lines.append(InvoiceLine(
                label: "No hours recorded in this period",
                seconds: 0,
                hourlyRateCents: rate,
                amountCents: 0
            ))
        }

        let subtotal = lines.reduce(0) { $0 + $1.amountCents }
        let vat = Int((Double(subtotal) * Double(max(0, profile.vatRatePercent)) / 100).rounded())

        let stored = try store.storeInvoice(
            profileId: profileId,
            periodStart: report.range.start,
            periodEnd: report.range.end,
            poNumber: poNumber,
            issuedAt: issuedAt,
            totalCents: subtotal + vat,
            currency: profile.currency
        )

        let dueAt = calendar.date(byAdding: .day, value: max(0, stored.sender.paymentTermDays), to: issuedAt) ?? issuedAt

        return Invoice(
            number: stored.number,
            poNumber: stored.poNumber,
            sender: stored.sender,
            profile: profile,
            periodStart: report.range.start,
            periodEnd: report.range.end,
            issuedAt: issuedAt,
            dueAt: dueAt,
            lines: lines,
            netSeconds: report.netTotal,
            subtotalCents: subtotal,
            vatRatePercent: profile.vatRatePercent,
            vatCents: vat,
            totalCents: subtotal + vat,
            currency: profile.currency
        )
    }
}

/// The email that carries the invoice PDF.
public enum InvoiceEmail {
    public static func subject(for invoice: Invoice) -> String {
        let sender = invoice.sender.senderName.trimmingCharacters(in: .whitespaces)
        return sender.isEmpty ? "Invoice \(invoice.number)" : "Invoice \(invoice.number) - \(sender)"
    }

    public static func body(for invoice: Invoice) -> String {
        var lines = [
            "Dear \(invoice.profile.name),",
            "",
            "Here is invoice \(invoice.number) for \(Formatting.monthName(invoice.periodStart)).",
        ]
        if let po = invoice.poNumber, !po.isEmpty {
            lines.append("Purchase order: \(po)")
        }
        lines.append("")
        lines.append("Total: \(Formatting.money(cents: invoice.totalCents, currency: invoice.currency))")
        lines.append("")
        lines.append("Kind regards,")
        let sender = invoice.sender.senderName.trimmingCharacters(in: .whitespaces)
        if !sender.isEmpty { lines.append(sender) }
        if !invoice.sender.senderEmail.isEmpty { lines.append(invoice.sender.senderEmail) }
        return lines.joined(separator: "\r\n")
    }

    /// The message as the app sends it, with the rendered PDF attached.
    public static func message(for invoice: Invoice, to recipient: String, pdf: Data) -> EmailMessage {
        EmailMessage(
            from: invoice.sender.smtpFromEmail.isEmpty ? invoice.sender.senderEmail : invoice.sender.smtpFromEmail,
            to: [recipient],
            subject: subject(for: invoice),
            body: body(for: invoice),
            attachment: (name: "invoice-\(invoice.number).pdf", data: pdf)
        )
    }
}

// MARK: - Store: invoice settings and numbering

extension Store {
    /// Folder beside the database, used for the stored logo. Tests get their own
    /// temporary folder through the same `TICKOALA_DB` override as the database.
    public static func supportDirectory() throws -> URL {
        URL(fileURLWithPath: try defaultDatabasePath()).deletingLastPathComponent()
    }

    public func invoiceSettings() throws -> InvoiceSettings {
        guard let row = try database.query(
            "SELECT value FROM settings WHERE key = ?;", [.text("invoice-settings")]
        ).first,
        let raw = row.string("value"),
        let data = raw.data(using: .utf8),
        let decoded = try? JSONDecoder().decode(InvoiceSettings.self, from: data)
        else {
            return .default
        }
        return decoded
    }

    public func updateInvoiceSettings(_ settings: InvoiceSettings) throws {
        let data = try JSONEncoder().encode(settings)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        try database.run(
            "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
            [.text("invoice-settings"), .text(json)]
        )
    }

    /// What was stored for an issued invoice: its number, PO and sender details.
    public struct StoredInvoice: Equatable, Sendable {
        public var number: String
        public var poNumber: String?
        public var sender: InvoiceSettings
    }

    /// Allocates the number for this client and month on the first call and
    /// reuses it on every later call. New numbers skip any that already exist.
    @discardableResult
    public func storeInvoice(
        profileId: Int64,
        periodStart: Date,
        periodEnd: Date,
        poNumber: String?,
        issuedAt: Date,
        totalCents: Int,
        currency: Currency
    ) throws -> StoredInvoice {
        let start = Int64(periodStart.timeIntervalSince1970)
        if let row = try database.query(
            "SELECT * FROM invoices WHERE profile_id = ? AND period_start = ?;",
            [.int(profileId), .int(start)]
        ).first, let number = row.string("number") {
            let effectivePO = poNumber ?? row.string("po_number")
            try database.run(
                "UPDATE invoices SET po_number = ?, total_cents = ?, currency = ?, issued_at = ? WHERE id = ?;",
                [
                    effectivePO.map { SQLValue.text($0) } ?? .null,
                    .int(Int64(totalCents)),
                    .text(currency.rawValue),
                    .int(Int64(issuedAt.timeIntervalSince1970)),
                    row.int("id").map { SQLValue.int($0) } ?? .null,
                ]
            )
            return StoredInvoice(number: number, poNumber: effectivePO, sender: try invoiceSettings())
        }

        var settings = try invoiceSettings()
        var number = settings.nextNumberText
        while try invoiceNumberExists(number) {
            settings.nextInvoiceNumber += 1
            number = settings.nextNumberText
        }
        settings.nextInvoiceNumber += 1
        try updateInvoiceSettings(settings)

        try database.run(
            """
            INSERT INTO invoices (profile_id, period_start, period_end, number, po_number, issued_at, total_cents, currency)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .int(profileId),
                .int(start),
                .int(Int64(periodEnd.timeIntervalSince1970)),
                .text(number),
                poNumber.map { SQLValue.text($0) } ?? .null,
                .int(Int64(issuedAt.timeIntervalSince1970)),
                .int(Int64(totalCents)),
                .text(currency.rawValue),
            ]
        )
        return StoredInvoice(number: number, poNumber: poNumber, sender: settings)
    }

    /// The number already handed out for this client and month, if any.
    public func issuedInvoiceNumber(profileId: Int64, periodStart: Date) throws -> String? {
        try database.query(
            "SELECT number FROM invoices WHERE profile_id = ? AND period_start = ?;",
            [.int(profileId), .int(Int64(periodStart.timeIntervalSince1970))]
        ).first?.string("number")
    }

    /// Is this invoice number already handed out? Used to skip duplicates after
    /// a manual edit of the counter.
    public func invoiceNumberExists(_ number: String) throws -> Bool {
        try database.query("SELECT 1 FROM invoices WHERE number = ? LIMIT 1;", [.text(number)]).first != nil
    }
}