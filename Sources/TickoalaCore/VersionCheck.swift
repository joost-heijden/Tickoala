import Foundation

/// A single version number such as `"1.2.3"` or `"v1.2.3"`.
///
/// Missing parts count as zero: `1.2` and `1.2.0` are therefore equal. Unreadable
/// input deliberately does not exist as a value — the init returns `nil` then, so
/// the comparison never has to guess. This file does no networking; it is pure
/// arithmetic and that is why it lives in TickoalaCore where it can be checked.
public struct Version: Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    /// Zero version: stands for a development build or a clone without tags.
    public static let zero = Version(major: 0, minor: 0, patch: 0)

    public init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        // We don't blow up on an empty string; that is simply unreadable.
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

/// Compares the version the app is running with what is available. No networking:
/// the caller fetches the tags and passes them in here as text.
public enum VersionCheck {
    /// Returns the newest available version that is higher than `current`.
    ///
    /// `nil` means "nothing newer". That is also the answer when the app doesn't
    /// know itself (`0.0.0`, a development build or a clone without tags); such a
    /// build should not be compared against releases. Unreadable tags are ignored.
    public static func newerVersion(current: String, available: [String]) -> String? {
        guard let current = Version(current), current != .zero else { return nil }

        return available
            .compactMap { tag -> (raw: String, version: Version)? in
                guard let version = Version(tag), version > current else { return nil }
                return (tag, version)
            }
            .max { $0.version < $1.version }
            .map(\.raw)
    }
}
