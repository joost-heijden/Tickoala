import Foundation

/// A short review of one week, built from the same report the overview shows.
/// Used for the opt-in weekly nudge and the optional email to yourself.
public struct WeeklySummary: Sendable {
    /// The week covered, Monday-based and half-open.
    public var range: DateRange
    /// The full report for that week; everything below is rendered from it.
    public var report: Report

    public init(range: DateRange, report: Report) {
        self.range = range
        self.report = report
    }

    /// Builds the summary for the week before `date`, for example the week that
    /// just ended.
    public static func make(
        store: Store,
        weekContaining date: Date = Date(),
        now: Date = Date(),
        calendar: Calendar = Formatting.calendar
    ) throws -> WeeklySummary {
        let previousWeek = calendar.date(byAdding: .day, value: -7, to: date) ?? date
        let range = Reporting.range(.week, containing: previousWeek, calendar: calendar)
        let report = try Reporting.report(store: store, range: range, now: now, calendar: calendar)
        return WeeklySummary(range: range, report: report)
    }

    /// The last day of the week, for the header.
    private var lastDay: Date { range.end.addingTimeInterval(-1) }

    /// "Mon 6 Oct – Sun 12 Oct".
    public var periodText: String {
        "\(Formatting.day(range.start)) – \(Formatting.day(lastDay))"
    }

    public var subject: String {
        "Your week in review (\(periodText))"
    }

    /// The total amount, only when every client with an amount shares a currency,
    /// since different currencies cannot be added up.
    public var totalAmount: (cents: Int, currency: Currency)? {
        let withAmount = report.byProfile.filter { $0.amountCents > 0 }
        let currencies = Set(withAmount.map(\.currency))
        guard currencies.count == 1, let currency = currencies.first else { return nil }
        return (withAmount.reduce(0) { $0 + $1.amountCents }, currency)
    }

    /// A short line for a notification banner.
    public var notificationText: String {
        var parts = ["Last week \(Formatting.duration(report.netTotal)) net"]
        if let total = totalAmount {
            parts.append(Formatting.money(cents: total.cents, currency: total.currency))
        }
        let clients = report.byProfile.filter { $0.total > 0 }.count
        parts.append("\(clients) client\(clients == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    /// The full plain-text review, for the CLI and the email body.
    public var body: String {
        var lines: [String] = []
        lines.append("Your week (\(periodText))")
        lines.append("")
        lines.append("Worked   \(Formatting.duration(report.total))")
        if report.breakDeduction > 0 {
            lines.append("Break    -\(Formatting.duration(report.breakDeduction))")
        }
        lines.append("Net      \(Formatting.duration(report.netTotal))")
        if let total = totalAmount {
            lines.append("Amount   \(Formatting.money(cents: total.cents, currency: total.currency))")
        }

        let clients = report.byProfile.filter { $0.total > 0 }
        if !clients.isEmpty {
            lines.append("")
            lines.append("Per client")
            for client in clients {
                var line = "  \(client.label.padding(toLength: 20, withPad: " ", startingAt: 0))"
                    + Formatting.duration(client.net)
                if client.amountCents > 0 {
                    line += "   \(Formatting.money(cents: client.amountCents, currency: client.currency))"
                }
                lines.append(line)
            }
        }

        if report.hasTags {
            let tags = report.byTag.prefix(8).filter { $0.total > 0 }
            if !tags.isEmpty {
                lines.append("")
                lines.append("Per tag")
                for tag in tags {
                    lines.append("  \(tag.label.padding(toLength: 20, withPad: " ", startingAt: 0))"
                                 + Formatting.duration(tag.total))
                }
            }
        }

        lines.append("")
        lines.append("— Tickoala")
        return lines.joined(separator: "\n")
    }
}
