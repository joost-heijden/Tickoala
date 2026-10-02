import Foundation

/// Progress towards a day or week target. The target is a number of minutes set
/// in the settings; the progress is worked out on top of the recorded hours, like
/// the break deduction, so nothing about the data changes.
public struct Goal: Equatable, Sendable {
    /// The target, in seconds. Zero means the goal is not set.
    public var targetSeconds: TimeInterval
    /// What has been worked towards it, in seconds (net, after break and idle).
    public var workedSeconds: TimeInterval

    public init(targetSeconds: TimeInterval, workedSeconds: TimeInterval) {
        self.targetSeconds = max(0, targetSeconds)
        self.workedSeconds = max(0, workedSeconds)
    }

    /// A goal from a target in minutes; `nil` when the target is zero (off).
    public init?(minutes: Int, workedSeconds: TimeInterval) {
        guard minutes > 0 else { return nil }
        self.init(targetSeconds: TimeInterval(minutes) * 60, workedSeconds: workedSeconds)
    }

    public var isSet: Bool { targetSeconds > 0 }

    /// The fraction of the target reached, capped at 1 so a bar never overflows.
    public var fraction: Double {
        guard targetSeconds > 0 else { return 0 }
        return min(1, workedSeconds / targetSeconds)
    }

    /// The percentage reached, uncapped, so "120%" can be shown when over.
    public var percent: Int {
        guard targetSeconds > 0 else { return 0 }
        return Int((workedSeconds / targetSeconds * 100).rounded())
    }

    public var isReached: Bool { targetSeconds > 0 && workedSeconds >= targetSeconds }

    /// What is still needed; zero once the target is met.
    public var remainingSeconds: TimeInterval { max(0, targetSeconds - workedSeconds) }

    /// The number of seconds beyond the target; zero while under it.
    public var overSeconds: TimeInterval { max(0, workedSeconds - targetSeconds) }

    /// "4:12 of 6:00 · 70%" for lists and menus.
    public var summary: String {
        guard isSet else { return "no goal" }
        var text = "\(Formatting.duration(workedSeconds)) of \(Formatting.duration(targetSeconds)) · \(percent)%"
        if isReached { text += " reached" }
        return text
    }
}
