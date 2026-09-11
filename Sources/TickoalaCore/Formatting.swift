import Foundation

public enum Formatting {
    /// Everything is shown in the local time zone; storage uses unix seconds.
    public static var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2 // Monday
        calendar.minimumDaysInFirstWeek = 4 // ISO-8601 week numbering
        return calendar
    }()

    public static func timestamp(_ date: Date) -> String {
        formatter("yyyy-MM-dd HH:mm").string(from: date)
    }

    public static func day(_ date: Date) -> String {
        formatter("yyyy-MM-dd").string(from: date)
    }

    public static func clock(_ date: Date) -> String {
        formatter("HH:mm").string(from: date)
    }

    /// English month and year, for the invoice period line.
    public static func monthName(_ date: Date) -> String {
        formatter("MMMM yyyy").string(from: date)
    }

    /// `1:05` for the menu bar, `0:00` when nothing has been recorded yet.
    public static func duration(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval.rounded()))
        return String(format: "%d:%02d", total / 3600, (total % 3600) / 60)
    }

    /// Decimal hours for export and totals, rounded to two decimals.
    public static func decimalHours(_ interval: TimeInterval) -> String {
        String(format: "%.2f", max(0, interval) / 3600)
    }

    /// Amount in cents as `€1,234.56`; the sign goes in front of the currency symbol.
    public static func money(cents: Int, currency: Currency = .eur) -> String {
        let sign = cents < 0 ? "-" : ""
        let absolute = abs(cents)
        return "\(sign)\(currency.symbol)\(grouped(absolute / 100)).\(String(format: "%02d", absolute % 100))"
    }

    /// Amount in cents as `1234.56`, with a dot as decimal separator, for the CSV.
    public static func decimalAmount(cents: Int) -> String {
        let sign = cents < 0 ? "-" : ""
        let absolute = abs(cents)
        return "\(sign)\(absolute / 100).\(String(format: "%02d", absolute % 100))"
    }

    /// Reads an entered rate as `87.50`, `87,50` or `87` and returns cents.
    /// `nil` for unreadable or negative input.
    public static func parseMoneyCents(_ input: String) -> Int? {
        var text = input
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: " ", with: "")
        if text.contains(",") {
            // Both notations are accepted: dot as thousands separator and comma
            // as decimal separator, or the other way around.
            text = text.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        }
        guard !text.isEmpty, let value = Double(text), value >= 0 else { return nil }
        return Int((value * 100).rounded())
    }

    private static func grouped(_ value: Int) -> String {
        let digits = Array(String(value).reversed())
        var result = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, index % 3 == 0 { result.append(",") }
            result.append(digit)
        }
        return String(result.reversed())
    }

    /// Accepts `2026-09-10 09:15`, `2026-09-10T09:15`, with or without seconds,
    /// and full ISO-8601 with a time zone.
    public static func parseDate(_ input: String) -> Date? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        let patterns = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd",
        ]
        for pattern in patterns {
            if let date = formatter(pattern).date(from: trimmed) { return date }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: trimmed)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }
}
