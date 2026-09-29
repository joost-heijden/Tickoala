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
    /// VAT rate a new customer starts with. Each customer can override it.
    public var defaultVatRatePercent: Int
    /// Optional prefix for the invoice number, for example `2026-`.
    public var invoiceNumberPrefix: String
    /// The next number to hand out. Never lowered automatically.
    public var nextInvoiceNumber: Int
    /// File name of a logo in Tickoala's support folder, shown on the invoice.
    public var logoFileName: String?
    /// Accent colour for the invoice, as `#RRGGBB`. `nil` or empty means the
    /// default greyscale look; see `InvoiceAccent`.
    public var accentColorHex: String?
    /// SMTP server for sending the invoice straight from the app. The password
    /// is deliberately not here: it lives in the macOS Keychain.
    public var smtpHost: String
    public var smtpPort: Int
    public var smtpUsername: String
    public var smtpFromEmail: String
    /// Extra addresses that get a copy of every invoice email (CC). Several can
    /// be entered, separated by commas, semicolons or new lines.
    public var smtpCcEmails: String
    /// Implicit TLS (SMTPS). True for port 465; STARTTLS on 587 is not supported.
    public var smtpUseTLS: Bool
    /// Attach the hour sheet (CSV) to the invoice email by default.
    public var attachHoursCSV: Bool

    public static let `default` = InvoiceSettings()

    public init(
        senderName: String = "",
        senderAddress: String = "",
        senderKvk: String = "",
        senderVatNumber: String = "",
        senderIban: String = "",
        senderEmail: String = "",
        paymentTermDays: Int = 30,
        defaultVatRatePercent: Int = 21,
        invoiceNumberPrefix: String = "",
        nextInvoiceNumber: Int = 1,
        logoFileName: String? = nil,
        accentColorHex: String? = nil,
        smtpHost: String = "",
        smtpPort: Int = 465,
        smtpUsername: String = "",
        smtpFromEmail: String = "",
        smtpCcEmails: String = "",
        smtpUseTLS: Bool = true,
        attachHoursCSV: Bool = false
    ) {
        self.senderName = senderName
        self.senderAddress = senderAddress
        self.senderKvk = senderKvk
        self.senderVatNumber = senderVatNumber
        self.senderIban = senderIban
        self.senderEmail = senderEmail
        self.paymentTermDays = paymentTermDays
        self.defaultVatRatePercent = defaultVatRatePercent
        self.invoiceNumberPrefix = invoiceNumberPrefix
        self.nextInvoiceNumber = nextInvoiceNumber
        self.logoFileName = logoFileName
        self.accentColorHex = accentColorHex
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpUsername = smtpUsername
        self.smtpFromEmail = smtpFromEmail
        self.smtpCcEmails = smtpCcEmails
        self.smtpUseTLS = smtpUseTLS
        self.attachHoursCSV = attachHoursCSV
    }

    /// Splits a free-form list of addresses (commas, semicolons or new lines)
    /// into clean addresses, keeping the order.
    public static func parseAddresses(_ text: String) -> [String] {
        text
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The CC addresses as a clean list, from the free-form text field.
    public var ccRecipients: [String] { Self.parseAddresses(smtpCcEmails) }

    /// Can an invoice be emailed? Host and a from-address are the minimum; the
    /// password is checked separately in the Keychain.
    public var canSendEmail: Bool {
        !smtpHost.trimmingCharacters(in: .whitespaces).isEmpty
            && !smtpFromEmail.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The prefix with any four-digit year in it moved to `year`, so `2026-`
    /// reads `2027-` once the year turns over. A prefix without a year (for
    /// example `INV-`) is left alone.
    public static func prefix(_ prefix: String, forYear year: Int) -> String {
        prefix.replacingOccurrences(
            of: #"(?:19|20)\d{2}"#,
            with: String(year),
            options: .regularExpression
        )
    }

    /// The prefix with its year moved to the current one, for display.
    public var currentPrefix: String {
        Self.prefix(invoiceNumberPrefix, forYear: Formatting.calendar.component(.year, from: Date()))
    }

    /// The number that `nextInvoiceNumber` will produce, with the year in the
    /// prefix set to the year of `date`.
    public func nextNumberText(on date: Date = Date()) -> String {
        let year = Formatting.calendar.component(.year, from: date)
        return String(format: "%@%04d", Self.prefix(invoiceNumberPrefix, forYear: year), max(1, nextInvoiceNumber))
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
        defaultVatRatePercent = try container.decodeIfPresent(Int.self, forKey: .defaultVatRatePercent) ?? fallback.defaultVatRatePercent
        invoiceNumberPrefix = try container.decodeIfPresent(String.self, forKey: .invoiceNumberPrefix) ?? fallback.invoiceNumberPrefix
        nextInvoiceNumber = try container.decodeIfPresent(Int.self, forKey: .nextInvoiceNumber) ?? fallback.nextInvoiceNumber
        logoFileName = try container.decodeIfPresent(String.self, forKey: .logoFileName) ?? fallback.logoFileName
        accentColorHex = try container.decodeIfPresent(String.self, forKey: .accentColorHex) ?? fallback.accentColorHex
        smtpHost = try container.decodeIfPresent(String.self, forKey: .smtpHost) ?? fallback.smtpHost
        smtpPort = try container.decodeIfPresent(Int.self, forKey: .smtpPort) ?? fallback.smtpPort
        smtpUsername = try container.decodeIfPresent(String.self, forKey: .smtpUsername) ?? fallback.smtpUsername
        smtpFromEmail = try container.decodeIfPresent(String.self, forKey: .smtpFromEmail) ?? fallback.smtpFromEmail
        smtpCcEmails = try container.decodeIfPresent(String.self, forKey: .smtpCcEmails) ?? fallback.smtpCcEmails
        smtpUseTLS = try container.decodeIfPresent(Bool.self, forKey: .smtpUseTLS) ?? fallback.smtpUseTLS
        attachHoursCSV = try container.decodeIfPresent(Bool.self, forKey: .attachHoursCSV) ?? fallback.attachHoursCSV
    }
}

/// One line of the invoice: a project, the automatic break deduction, or an
/// expense / mileage claim.
public struct InvoiceLine: Equatable, Sendable {
    public var label: String
    /// Recorded seconds; negative for the break deduction. Zero on an expense.
    public var seconds: TimeInterval
    public var hourlyRateCents: Int
    public var amountCents: Int
    /// On an expense or mileage line: the quantity, its unit (`km`) and the
    /// per-unit rate. `nil` on an hours line.
    public var quantity: Double? = nil
    public var unit: String? = nil
    public var unitRateCents: Int? = nil

    public var isDeduction: Bool { seconds < 0 }
    public var isExpense: Bool { quantity != nil }
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
    /// Billable expenses and mileage included in the subtotal.
    public var expensesCents: Int
    public var subtotalCents: Int
    public var vatRatePercent: Int
    public var vatCents: Int
    public var totalCents: Int
    public var currency: Currency
}

/// How much time one invoice covers. The month is the default; a week or two
/// weeks suit clients who are billed more often.
public enum InvoicePeriodKind: String, CaseIterable, Sendable {
    case month
    case week
    case twoWeeks

    public var label: String {
        switch self {
        case .month: return "Month"
        case .week: return "Week"
        case .twoWeeks: return "2 weeks"
        }
    }

    /// The word used in a sentence, such as "the previous period".
    public var noun: String {
        switch self {
        case .month: return "month"
        case .week: return "week"
        case .twoWeeks: return "two-week period"
        }
    }

    /// The calendar window around `date` for this length, Monday-based.
    public func range(containing date: Date, calendar: Calendar = Formatting.calendar) -> DateRange {
        switch self {
        case .month:
            return Reporting.range(.month, containing: date, calendar: calendar)
        case .week:
            return Reporting.range(.week, containing: date, calendar: calendar)
        case .twoWeeks:
            let week = Reporting.range(.week, containing: date, calendar: calendar)
            let end = calendar.date(byAdding: .day, value: 14, to: week.start) ?? week.end
            return DateRange(start: week.start, end: end)
        }
    }

    /// The window one step forward (`direction` 1) or back (-1) from `date`.
    public func shifted(_ direction: Int, from date: Date, calendar: Calendar = Formatting.calendar) -> DateRange {
        let start = range(containing: date, calendar: calendar).start
        let moved: Date
        switch self {
        case .month:
            moved = calendar.date(byAdding: .month, value: direction, to: start) ?? start
        case .week:
            moved = calendar.date(byAdding: .day, value: 7 * direction, to: start) ?? start
        case .twoWeeks:
            moved = calendar.date(byAdding: .day, value: 14 * direction, to: start) ?? start
        }
        return range(containing: moved, calendar: calendar)
    }

    /// The length a stored window corresponds to, so the history can jump to it.
    public static func matching(start: Date, end: Date, calendar: Calendar = Formatting.calendar) -> InvoicePeriodKind {
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        if days <= 7 { return .week }
        if days <= 14 { return .twoWeeks }
        return .month
    }
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

    /// How the invoice period reads in text and email: a month name for a monthly
    /// invoice, a date range for a shorter period.
    public static func periodText(start: Date, end: Date, calendar: Calendar = Formatting.calendar) -> String {
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        guard days <= 14 else { return Formatting.monthName(start) }
        let last = calendar.date(byAdding: .day, value: -1, to: end) ?? end
        return "\(Formatting.day(start)) – \(Formatting.day(last))"
    }

    /// A short, file-name-safe tag for an invoice period: `2026-09` for a month,
    /// the start day for a shorter period.
    public static func periodTag(start: Date, end: Date, calendar: Calendar = Formatting.calendar) -> String {
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        return days <= 14 ? Formatting.day(start) : String(Formatting.day(start).prefix(7))
    }

    /// The details a full invoice may not go without. Empty means it is complete.
    /// Only the fields that are both legally required and can still be blank in
    /// practice; the sender's btw-id and KvK are optional here because a
    /// KOR-ondernemer does not charge VAT.
    public static func missingRequiredFields(profile: Profile, sender: InvoiceSettings) -> [String] {
        func blank(_ text: String?) -> Bool {
            (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var missing: [String] = []
        if blank(sender.senderName) { missing.append("your name") }
        if blank(sender.senderAddress) { missing.append("your address") }
        if blank(profile.name) { missing.append("the customer name") }
        if blank(profile.billingAddress) { missing.append("the customer address") }
        return missing
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
        let missing = missingRequiredFields(profile: profile, sender: try store.invoiceSettings())
        guard missing.isEmpty else {
            throw TrackerError.invalidRange(
                "cannot issue an invoice: fill in \(missing.joined(separator: ", ")) first"
            )
        }
        let report = try Reporting.report(
            store: store,
            range: period,
            profileId: profileId,
            now: now,
            calendar: calendar
        )

        let rate = profile.hourlyRateCents
        let rules = profile.billingRules
        func amount(_ seconds: TimeInterval) -> Int {
            guard rate > 0 else { return 0 }
            return Int((seconds / 3600 * Double(rate)).rounded())
        }

        // The automatic break deduction is already folded into these net hours;
        // the invoice never shows it as its own line. Billing rules round each
        // line's invoiced time; with no rules set the hours are untouched.
        var lines = report.byProjectNet
            .filter { $0.total > 0 }
            .map { item in
                let seconds = rules.roundingMinutes > 0 ? rules.rounded(item.total) : item.total
                return InvoiceLine(
                    label: item.label,
                    seconds: seconds,
                    hourlyRateCents: rate,
                    amountCents: amount(seconds)
                )
            }
        // A minimum number of billable hours, topped up as its own line.
        if rules.minimumMinutes > 0, rate > 0 {
            let worked = lines.reduce(0) { $0 + $1.seconds }
            let minimum = TimeInterval(rules.minimumMinutes) * 60
            if worked < minimum {
                let short = minimum - worked
                lines.append(InvoiceLine(
                    label: "Minimum billing",
                    seconds: short,
                    hourlyRateCents: rate,
                    amountCents: amount(short)
                ))
            }
        }
        // Travel and commute get their own line, at their own rate. A commute
        // without a rate stays off the invoice; its time is still recorded.
        for kind in [EntryKind.travel, .commute] {
            let seconds = report.byKind[kind] ?? 0
            guard seconds > 0, profile.isBillable(kind: kind) else { continue }
            let kindRate = profile.rateCents(for: kind)
            guard kindRate > 0 else { continue }
            lines.append(InvoiceLine(
                label: kind == .travel ? "Travel time" : "Commute",
                seconds: seconds,
                hourlyRateCents: kindRate,
                amountCents: profile.amountCents(for: seconds, rateCents: kindRate)
            ))
        }
        // A retainer is a fixed monthly amount, added automatically.
        if let retainer = try store.retainer(profileId: profileId), retainer.isSet {
            lines.append(InvoiceLine(
                label: retainer.label,
                seconds: 0,
                hourlyRateCents: 0,
                amountCents: retainer.amountCents,
                quantity: 1,
                unit: nil,
                unitRateCents: retainer.amountCents
            ))
        }
        // Billable expenses and mileage for the same period become their own
        // lines, on top of the hours.
        let expenses = try store.expenses(profileId: profileId, from: period.start, to: period.end)
            .filter { $0.billable && $0.amountCents != 0 }
        lines.append(contentsOf: expenses.map { expense in
            InvoiceLine(
                label: expense.description,
                seconds: 0,
                hourlyRateCents: 0,
                amountCents: expense.amountCents,
                quantity: expense.quantity,
                unit: expense.kind == .mileage ? "km" : nil,
                unitRateCents: expense.unitRateCents
            )
        })
        // Evening and weekend surcharges, as their own line. Their amount is a
        // percentage of the hours, so they carry no quantity of their own.
        if rules.isActive, rate > 0,
           rules.eveningSurchargePercent > 0 || rules.weekendSurchargePercent > 0 {
            let entries = try store.entries(from: period.start, to: period.end, profileId: profileId)
            let extra = Billing.surchargeSeconds(entries: entries, rules: rules, now: now, calendar: calendar)
            func surcharge(_ seconds: TimeInterval, percent: Int, label: String) {
                guard percent > 0, seconds > 0 else { return }
                let amount = Int((Double(amount(seconds)) * Double(percent) / 100).rounded())
                lines.append(InvoiceLine(
                    label: "\(label) surcharge (\(percent)%)",
                    seconds: 0,
                    hourlyRateCents: 0,
                    amountCents: amount,
                    quantity: 1,
                    unit: nil,
                    unitRateCents: amount
                ))
            }
            surcharge(extra.evening, percent: rules.eveningSurchargePercent, label: "Evening")
            surcharge(extra.weekend, percent: rules.weekendSurchargePercent, label: "Weekend")
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
        let expensesTotal = expenses.reduce(0) { $0 + $1.amountCents }
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
            netSeconds: lines.reduce(0) { $0 + max(0, $1.seconds) },
            expensesCents: expensesTotal,
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
            "Here is invoice \(invoice.number) for \(Invoicing.periodText(start: invoice.periodStart, end: invoice.periodEnd)).",
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

    /// The message as the app sends it, with the rendered PDF and optionally the
    /// hour sheet attached.
    public static func message(for invoice: Invoice, to recipient: String, pdf: Data, csv: Data? = nil) -> EmailMessage {
        var attachments = [
            EmailAttachment(name: "invoice-\(invoice.number).pdf", mimeType: "application/pdf", data: pdf)
        ]
        if let csv {
            let client = invoice.profile.name
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let tag = Invoicing.periodTag(start: invoice.periodStart, end: invoice.periodEnd)
            attachments.append(EmailAttachment(
                name: "hours-\(client)-\(tag).csv", mimeType: "text/csv; charset=utf-8", data: csv
            ))
        }
        // The global CC list plus this client's own, without duplicates.
        var cc: [String] = []
        for address in invoice.sender.ccRecipients + InvoiceSettings.parseAddresses(invoice.profile.billingCc ?? "")
        where !cc.contains(where: { $0.caseInsensitiveCompare(address) == .orderedSame }) {
            cc.append(address)
        }
        return EmailMessage(
            from: invoice.sender.smtpFromEmail.isEmpty ? invoice.sender.senderEmail : invoice.sender.smtpFromEmail,
            to: [recipient],
            cc: cc,
            subject: subject(for: invoice),
            body: body(for: invoice),
            attachments: attachments
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

        // The year in the prefix follows the system clock, not the invoice's
        // issue date, so rebuilding an old invoice never rewinds the year.
        var settings = try invoiceSettings()
        var number = settings.nextNumberText()
        while try invoiceNumberExists(number) {
            settings.nextInvoiceNumber += 1
            number = settings.nextNumberText()
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

    /// A stored invoice as the history list shows it, with the client's name.
    public struct IssuedInvoice: Equatable, Sendable, Identifiable {
        public var id: String { number }
        public var number: String
        public var profileId: Int64
        public var profileName: String
        public var periodStart: Date
        public var periodEnd: Date
        public var issuedAt: Date
        public var totalCents: Int
        public var currency: Currency
        public var poNumber: String?
    }

    /// Every invoice ever issued, newest month first: when you invoiced and whom.
    public func issuedInvoices() throws -> [IssuedInvoice] {
        try database.query(
            """
            SELECT i.number, i.profile_id, p.name AS profile_name, i.period_start,
                   i.period_end, i.issued_at, i.total_cents, i.currency, i.po_number
            FROM invoices i JOIN profiles p ON p.id = i.profile_id
            ORDER BY i.period_start DESC, p.name COLLATE NOCASE ASC;
            """
        ).compactMap { row in
            guard let number = row.string("number"),
                  let profileId = row.int("profile_id"),
                  let periodStart = row.date("period_start"),
                  let issuedAt = row.date("issued_at") else { return nil }
            return IssuedInvoice(
                number: number,
                profileId: profileId,
                profileName: row.string("profile_name") ?? "",
                periodStart: periodStart,
                periodEnd: row.date("period_end") ?? periodStart,
                issuedAt: issuedAt,
                totalCents: row.int("total_cents").map(Int.init) ?? 0,
                currency: row.string("currency").flatMap(Currency.init(rawValue:)) ?? .eur,
                poNumber: row.string("po_number")
            )
        }
    }

    /// Removes an issued invoice from the history. The recorded hours stay; only
    /// the stored number and its allocation go away.
    public func deleteInvoice(number: String) throws {
        try database.run("DELETE FROM invoices WHERE number = ?;", [.text(number)])
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