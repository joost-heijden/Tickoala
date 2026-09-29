import Foundation

/// A calendar quarter, the period a Dutch VAT return covers.
public struct VATPeriod: Equatable, Sendable {
    public var year: Int
    /// 1 through 4.
    public var quarter: Int
    public var start: Date
    public var end: Date

    public init(year: Int, quarter: Int, calendar: Calendar = Formatting.calendar) {
        let clamped = min(max(1, quarter), 4)
        self.year = year
        self.quarter = clamped
        var components = DateComponents()
        components.year = year
        components.month = (clamped - 1) * 3 + 1
        components.day = 1
        let start = calendar.date(from: components) ?? Date()
        self.start = start
        self.end = calendar.date(byAdding: .month, value: 3, to: start) ?? start
    }

    public var label: String { "Q\(quarter) \(year)" }

    /// The quarter `date` falls in.
    public static func containing(_ date: Date, calendar: Calendar = Formatting.calendar) -> VATPeriod {
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        return VATPeriod(year: year, quarter: (month - 1) / 3 + 1, calendar: calendar)
    }

    /// One quarter forward (`direction` 1) or back (-1).
    public func shifted(_ direction: Int, calendar: Calendar = Formatting.calendar) -> VATPeriod {
        let absolute = year * 4 + (quarter - 1) + direction
        let newYear = Int(floor(Double(absolute) / 4.0))
        let remainder = absolute - newYear * 4
        return VATPeriod(year: newYear, quarter: remainder + 1, calendar: calendar)
    }
}

/// One VAT rate in the return: the turnover and the VAT charged at that rate.
public struct VATLine: Equatable, Sendable {
    public var ratePercent: Int
    /// Turnover excluding VAT, in cents.
    public var netCents: Int
    public var vatCents: Int
    public var totalCents: Int { netCents + vatCents }
}

/// The quarterly VAT return: turnover and VAT grouped by rate, ready to copy
/// into the Belastingdienst's form. Built from the recorded hours and expenses,
/// exactly as an invoice would show them.
public struct VATReport: Sendable {
    public var period: VATPeriod
    /// One line per VAT rate that occurred, lowest rate first.
    public var lines: [VATLine]

    public var totalNetCents: Int { lines.reduce(0) { $0 + $1.netCents } }
    public var totalVatCents: Int { lines.reduce(0) { $0 + $1.vatCents } }
    public var totalCents: Int { totalNetCents + totalVatCents }
}

public enum VAT {
    /// The return for a quarter. Every client is counted at its own VAT rate;
    /// hours at the client's hourly rate plus the billable expenses, with the
    /// VAT over the sum — the same figures an invoice for that client would show.
    public static func report(
        store: Store,
        period: VATPeriod,
        now: Date = Date(),
        calendar: Calendar = Formatting.calendar
    ) throws -> VATReport {
        var byRate: [Int: VATLine] = [:]
        for profile in try store.profiles() {
            let hours = try Reporting.report(
                store: store, range: DateRange(start: period.start, end: period.end),
                profileId: profile.id, now: now, calendar: calendar
            )
            let hoursCents = profile.amountCents(for: hours.netTotal)
            let expensesCents = try store
                .expenses(profileId: profile.id, from: period.start, to: period.end)
                .filter { $0.billable }
                .reduce(0) { $0 + $1.amountCents }
            let net = hoursCents + expensesCents
            guard net != 0 else { continue }
            let rate = max(0, profile.vatRatePercent)
            let vat = Int((Double(net) * Double(rate) / 100).rounded())
            var line = byRate[rate] ?? VATLine(ratePercent: rate, netCents: 0, vatCents: 0)
            line.netCents += net
            line.vatCents += vat
            byRate[rate] = line
        }
        let lines = byRate.values.sorted { $0.ratePercent < $1.ratePercent }
        return VATReport(period: period, lines: lines)
    }
}
