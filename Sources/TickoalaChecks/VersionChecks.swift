import Foundation
import TickoalaCore

func versionChecks() {
    suite("Versievergelijking") {
        test("een hogere versie is nieuwer") {
            expectEqual(VersionCheck.newerVersion(current: "1.1.9", available: ["1.2.0"]), "1.2.0")
            expect(Version("1.2.0")! > Version("1.1.9")!, "1.2.0 hoort boven 1.1.9 te liggen")
        }

        test("een gelijke versie levert niets op") {
            expect(VersionCheck.newerVersion(current: "1.2.0", available: ["1.2.0"]) == nil, "gelijk is geen update")
        }

        test("een oudere versie levert niets op") {
            expect(VersionCheck.newerVersion(current: "1.5.0", available: ["1.4.9", "1.2.0"]) == nil, "ouder is geen update")
        }

        test("de v ervoor maakt niet uit") {
            expect(VersionCheck.newerVersion(current: "v1.2.0", available: ["v1.3.0"]) == "v1.3.0")
            expect(VersionCheck.newerVersion(current: "1.2.0", available: ["v1.2.0"]) == nil, "v-tag telt als dezelfde versie")
        }

        test("ontbrekende delen tellen als nul") {
            expectEqual(Version("1.2"), Version("1.2.0"))
            expectEqual(Version("v1"), Version("1.0.0"))
        }

        test("uit de lijst komt de nieuwste") {
            expectEqual(VersionCheck.newerVersion(current: "1.0.0", available: ["1.1.0", "2.0.0", "1.5.0"]), "2.0.0")
        }

        test("rommel levert nil, geen gok") {
            expect(Version("rommel") == nil, "letters zijn geen versie")
            expect(Version("1.x.3") == nil, "een niet-getal is onleesbaar")
            expect(Version("1.2.3.4") == nil, "te veel delen")
            expect(Version("1..3") == nil, "een leeg deel is onleesbaar")
            expect(Version("") == nil, "leeg is onleesbaar")
            expect(Version("  1.2.3  ") != nil, "omringende spaties mogen")
        }

        test("een ontwikkelbuild van 0.0.0 meldt nooit een update") {
            expect(VersionCheck.newerVersion(current: "0.0.0", available: ["9.9.9"]) == nil, "0.0.0 is geen release")
            expect(VersionCheck.newerVersion(current: "0.0.0", available: ["rommel"]) == nil, "ook rommel meldt niets")
        }
    }
}
