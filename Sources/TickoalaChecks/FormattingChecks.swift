import Foundation
import TickoalaCore

/// Times a user picks are minute precision. The seconds of the original block
/// must not leak into a manually corrected one (08:00, not 08:00:46).
func formattingChecks() {
    suite("Minute precision") {
        test("dropping the seconds keeps the minute") {
            expectEqual(Formatting.minute(at("2026-09-15 08:00:46")), at("2026-09-15 08:00"))
            expectEqual(Formatting.minute(at("2026-09-15 16:30:26")), at("2026-09-15 16:30"))
        }

        test("a corrected block spans exactly the picked minutes") {
            let start = Formatting.minute(at("2026-09-15 08:00:46"))
            let end = Formatting.minute(at("2026-09-15 16:30:26"))
            expectEqual(Formatting.duration(end.timeIntervalSince(start)), "8:30")
        }
    }
}
