import Foundation
import TickoalaCore

func versionChecks() {
    suite("Version comparison") {
        test("a higher version is newer") {
            expectEqual(VersionCheck.newerVersion(current: "1.1.9", available: ["1.2.0"]), "1.2.0")
            expect(Version("1.2.0")! > Version("1.1.9")!, "1.2.0 should be above 1.1.9")
        }

        test("an equal version yields nothing") {
            expect(VersionCheck.newerVersion(current: "1.2.0", available: ["1.2.0"]) == nil, "equal is not an update")
        }

        test("an older version yields nothing") {
            expect(VersionCheck.newerVersion(current: "1.5.0", available: ["1.4.9", "1.2.0"]) == nil, "older is not an update")
        }

        test("the leading v does not matter") {
            expect(VersionCheck.newerVersion(current: "v1.2.0", available: ["v1.3.0"]) == "v1.3.0")
            expect(VersionCheck.newerVersion(current: "1.2.0", available: ["v1.2.0"]) == nil, "a v-tag counts as the same version")
        }

        test("missing parts count as zero") {
            expectEqual(Version("1.2"), Version("1.2.0"))
            expectEqual(Version("v1"), Version("1.0.0"))
        }

        test("the newest comes out of the list") {
            expectEqual(VersionCheck.newerVersion(current: "1.0.0", available: ["1.1.0", "2.0.0", "1.5.0"]), "2.0.0")
        }

        test("junk yields nil, no guess") {
            expect(Version("junk") == nil, "letters are not a version")
            expect(Version("1.x.3") == nil, "a non-number is unreadable")
            expect(Version("1.2.3.4") == nil, "too many parts")
            expect(Version("1..3") == nil, "an empty part is unreadable")
            expect(Version("") == nil, "empty is unreadable")
            expect(Version("  1.2.3  ") != nil, "surrounding spaces are allowed")
        }

        test("a development build of 0.0.0 never reports an update") {
            expect(VersionCheck.newerVersion(current: "0.0.0", available: ["9.9.9"]) == nil, "0.0.0 is not a release")
            expect(VersionCheck.newerVersion(current: "0.0.0", available: ["junk"]) == nil, "junk reports nothing either")
        }
    }
}
