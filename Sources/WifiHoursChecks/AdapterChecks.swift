import Foundation
import WifiHoursCore

/// Draait het echte adaptercommando, precies zoals ControlPlane dat zou doen.
private func runCLI(_ arguments: [String], database: String) throws -> (status: Int32, output: String) {
    let binary = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent()
        .appendingPathComponent("wifihours")
    guard FileManager.default.isExecutableFile(atPath: binary.path) else {
        throw MissingValue(description: "wifihours niet gevonden op \(binary.path) — draai eerst 'swift build'")
    }

    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["WIFIHOURS_DB"] = database
    process.environment = environment

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

func adapterChecks() {
    suite("ControlPlane-adapter") {
        test("start en stop met expliciete tijden schrijven één afgerond blok") {
            let database = NSTemporaryDirectory() + "wifihours-cli-\(UUID().uuidString).sqlite3"
            defer { Fixture.remove(database) }

            _ = try runCLI(["profile", "add", "--name", "Organisatie A", "--context", "Kantoor A"], database: database)
            _ = try runCLI(["project", "add", "--profile", "Organisatie A", "--number", "2401", "--name", "Migratie"], database: database)
            _ = try runCLI(["project", "select", "--profile", "Organisatie A", "--number", "2401"], database: database)

            // Een dag in het verleden, zodat de wachttijd van de stop al verstreken is.
            let dag = Formatting.day(Date().addingTimeInterval(-7 * 24 * 3600))
            let gestart = try runCLI(["start", "--context", "Kantoor A", "--at", "\(dag) 09:00"], database: database)
            expectEqual(gestart.status, 0, "exitcode van start")
            expect(gestart.output.contains("gestart"), "uitvoer: \(gestart.output)")

            let gestopt = try runCLI(["stop", "--context", "Kantoor A", "--at", "\(dag) 17:00"], database: database)
            expect(gestopt.output.contains("gestopt"), "uitvoer: \(gestopt.output)")

            let store = try Store(path: database)
            let entries = try store.entries(from: at(dag), to: at(dag).addingTimeInterval(24 * 3600))
            expectEqual(entries.count, 1)
            expectEqual(entries.first?.duration(), 8 * 3600)
            expectEqual(entries.first?.source, .controlplane)
        }

        test("een onbekende context laat het commando gewoon slagen") {
            let database = NSTemporaryDirectory() + "wifihours-cli-\(UUID().uuidString).sqlite3"
            defer { Fixture.remove(database) }

            let resultaat = try runCLI(["start", "--context", "Café"], database: database)

            expectEqual(resultaat.status, 0, "ControlPlane mag hier geen foutmelding op krijgen")
            expect(resultaat.output.contains("onbekende context"), "uitvoer: \(resultaat.output)")
        }

        test("een ontbrekend argument geeft exitcode 2 met uitleg") {
            let database = NSTemporaryDirectory() + "wifihours-cli-\(UUID().uuidString).sqlite3"
            defer { Fixture.remove(database) }

            let resultaat = try runCLI(["start"], database: database)

            expectEqual(resultaat.status, 2, "exitcode bij verkeerd gebruik")
            expect(resultaat.output.contains("--context"), "uitvoer: \(resultaat.output)")
        }

        test("status --json geeft machinaal leesbare uitvoer") {
            let database = NSTemporaryDirectory() + "wifihours-cli-\(UUID().uuidString).sqlite3"
            defer { Fixture.remove(database) }

            _ = try runCLI(["profile", "add", "--name", "Organisatie A", "--context", "Kantoor A"], database: database)
            _ = try runCLI(["project", "add", "--profile", "Organisatie A", "--number", "2401", "--name", "Migratie"], database: database)
            _ = try runCLI(["project", "select", "--number", "2401"], database: database)
            _ = try runCLI(["start", "--context", "Kantoor A"], database: database)

            let resultaat = try runCLI(["status", "--json"], database: database)
            let json = try expectNotNil(
                try JSONSerialization.jsonObject(with: Data(resultaat.output.utf8)) as? [String: Any],
                "kon json niet lezen: \(resultaat.output)"
            )
            expectEqual(json["modus"] as? String, "working")
            let profielen = try expectNotNil(json["profielen"] as? [[String: Any]])
            expectEqual(profielen.first?["project"] as? String, "2401 — Migratie")
        }

        test("het adaptercommando is idempotent bij herhaling") {
            let database = NSTemporaryDirectory() + "wifihours-cli-\(UUID().uuidString).sqlite3"
            defer { Fixture.remove(database) }

            _ = try runCLI(["profile", "add", "--name", "Organisatie A", "--context", "Kantoor A"], database: database)
            _ = try runCLI(["project", "add", "--profile", "Organisatie A", "--number", "2401", "--name", "Migratie"], database: database)
            _ = try runCLI(["project", "select", "--number", "2401"], database: database)

            for _ in 0..<3 {
                _ = try runCLI(["start", "--context", "Kantoor A", "--at", "2026-09-10 09:00"], database: database)
            }

            let store = try Store(path: database)
            expectEqual(try store.entries(from: at("2026-09-10"), to: at("2026-09-11")).count, 1, "drie keer hetzelfde event blijft één blok")
        }

        test("export schrijft een bestand weg") {
            let database = NSTemporaryDirectory() + "wifihours-cli-\(UUID().uuidString).sqlite3"
            let csvPad = NSTemporaryDirectory() + "wifihours-export-\(UUID().uuidString).csv"
            defer {
                Fixture.remove(database)
                try? FileManager.default.removeItem(atPath: csvPad)
            }

            _ = try runCLI(["profile", "add", "--name", "Organisatie A", "--context", "Kantoor A"], database: database)
            _ = try runCLI(["project", "add", "--profile", "Organisatie A", "--number", "2401", "--name", "Migratie"], database: database)
            _ = try runCLI(["entry", "add", "--number", "2401", "--start", "2026-09-10 09:00", "--end", "2026-09-10 17:00", "--note", "handmatig blok"], database: database)

            let resultaat = try runCLI(["export", "--from", "2026-09-10", "--to", "2026-09-11", "--out", csvPad], database: database)
            expectEqual(resultaat.status, 0, "uitvoer: \(resultaat.output)")

            let csv = try String(contentsOfFile: csvPad, encoding: .utf8)
            expect(csv.contains("2401,Migratie,2026-09-10,09:00,17:00,8.00,480,completed,manual,handmatig blok"), "inhoud: \(csv)")
        }

        test("een blok bijwerken via de opdrachtregel corrigeert de duur") {
            let database = NSTemporaryDirectory() + "wifihours-cli-\(UUID().uuidString).sqlite3"
            defer { Fixture.remove(database) }

            _ = try runCLI(["profile", "add", "--name", "Organisatie A", "--context", "Kantoor A"], database: database)
            _ = try runCLI(["project", "add", "--profile", "Organisatie A", "--number", "2401", "--name", "Migratie"], database: database)
            _ = try runCLI(["entry", "add", "--number", "2401", "--start", "2026-09-10 09:00", "--end", "2026-09-10 17:00"], database: database)
            _ = try runCLI(["entry", "edit", "--id", "1", "--end", "2026-09-10 16:00"], database: database)

            let store = try Store(path: database)
            expectEqual(try store.entry(id: 1)?.duration(), 7 * 3600)
        }
    }
}
