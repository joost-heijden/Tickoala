import Foundation

public enum Formatting {
    /// Alles wordt in de lokale tijdzone getoond; opslag gebeurt in unix-seconden.
    public static var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2 // maandag
        calendar.minimumDaysInFirstWeek = 4 // ISO-8601 weeknummering
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

    /// `1:05` voor de menubalk, `0:00` als er nog niets staat.
    public static func duration(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval.rounded()))
        return String(format: "%d:%02d", total / 3600, (total % 3600) / 60)
    }

    /// Decimale uren voor export en totalen, afgerond op twee decimalen.
    public static func decimalHours(_ interval: TimeInterval) -> String {
        String(format: "%.2f", max(0, interval) / 3600)
    }

    /// Bedrag in centen als `€ 1.234,56`; het teken staat vóór het euroteken.
    public static func money(cents: Int) -> String {
        let sign = cents < 0 ? "-" : ""
        let absolute = abs(cents)
        return "\(sign)€ \(grouped(absolute / 100)),\(String(format: "%02d", absolute % 100))"
    }

    /// Bedrag in centen als `1234.56`, met punt als decimaalteken, voor de CSV.
    public static func decimalAmount(cents: Int) -> String {
        let sign = cents < 0 ? "-" : ""
        let absolute = abs(cents)
        return "\(sign)\(absolute / 100).\(String(format: "%02d", absolute % 100))"
    }

    /// Leest een ingevoerd tarief als `87,50`, `87.50` of `87` en geeft centen
    /// terug. `nil` bij onleesbare of negatieve invoer.
    public static func parseMoneyCents(_ input: String) -> Int? {
        var text = input
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: " ", with: "")
        if text.contains(",") {
            // Nederlandse notatie: punt is duizendtal, komma is decimaal.
            text = text.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        }
        guard !text.isEmpty, let value = Double(text), value >= 0 else { return nil }
        return Int((value * 100).rounded())
    }

    private static func grouped(_ value: Int) -> String {
        let digits = Array(String(value).reversed())
        var result = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, index % 3 == 0 { result.append(".") }
            result.append(digit)
        }
        return String(result.reversed())
    }

    /// Accepteert `2026-09-10 09:15`, `2026-09-10T09:15`, met of zonder seconden,
    /// en volledige ISO-8601 met tijdzone.
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
