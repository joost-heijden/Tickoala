import Foundation

/// Eén versienummer zoals `"1.2.3"` of `"v1.2.3"`.
///
/// Ontbrekende delen tellen als nul: `1.2` en `1.2.0` zijn dus gelijk. Onleesbare
/// invoer bestaat bewust niet als waarde — de init geeft dan `nil`, zodat de
/// vergelijking nooit hoeft te gokken. Dit bestand doet geen netwerk; het is puur
/// rekenwerk en daarom in TickoalaCore te controleren.
public struct Version: Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    /// Nulversie: staat voor een ontwikkelbuild of een clone zonder tags.
    public static let zero = Version(major: 0, minor: 0, patch: 0)

    public init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        // Leeg laten ontploffen we niet; dat is gewoon onleesbaar.
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 3 else { return nil }

        var numbers: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            numbers.append(value)
        }

        self.init(
            major: numbers[0],
            minor: numbers.count > 1 ? numbers[1] : 0,
            patch: numbers.count > 2 ? numbers[2] : 0
        )
    }

    private init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: Version, rhs: Version) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// Vergelijkt de versie die de app draait met wat er beschikbaar is. Geen netwerk:
/// de aanroeper haalt de tags op en geeft ze hier als tekst door.
public enum VersionCheck {
    /// Geeft de nieuwste beschikbare versie terug die hoger is dan `current`.
    ///
    /// `nil` betekent "niets nieuwers". Dat is ook het antwoord als de app zichzelf
    /// niet kent (`0.0.0`, een ontwikkelbuild of een clone zonder tags); zo'n build
    /// hoort niet met releases te vergelijken. Onleesbare tags worden genegeerd.
    public static func newerVersion(current: String, available: [String]) -> String? {
        guard let huidig = Version(current), huidig != .zero else { return nil }

        return available
            .compactMap { tag -> (raw: String, version: Version)? in
                guard let version = Version(tag), version > huidig else { return nil }
                return (tag, version)
            }
            .max { $0.version < $1.version }
            .map(\.raw)
    }
}
