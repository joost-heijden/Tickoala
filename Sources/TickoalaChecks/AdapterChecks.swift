import Foundation
import TickoalaCore

/// Runs the real adapter command, exactly as ControlPlane would.
private func runCLI(_ arguments: [String], database: String) throws -> (status: Int32, output: String) {
    let binary = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent()
        .appendingPathComponent("tickoala")
    guard FileManager.default.isExecutableFile(atPath: binary.path) else {
        throw MissingValue(description: "tickoala not found at \(binary.path) — run 'swift build' first")
    }

    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["TICKOALA_DB"] = database
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
    suite("ControlPlane adapter") {
        test("start and stop with explicit times write one completed block") {
            let database = NSTemporaryDirectory() + "tickoala-cli-\(UUID().uuidString).sqlite3"
            defer { Fixture.remove(database) }

            _ = try runCLI(["profile", "add", "--name", "Organization A", "--context", "Office A"], database: database)
            _ = try runCLI(["project", "add", "--profile", "Organization A", "--number", "2401", "--name", "Migration"], database: database)
            _ = try runCLI(["project", "select", "--profile", "Organization A", "--number", "2401"], database: database)

            // A day in the past, so the stop's grace period has already passed.
            let day = Formatting.day(Date().addingTimeInterval(-7 * 24 * 3600))
            let started = try runCLI(["start", "--context", "Office A", "--at", "\(day) 09:00"], database: database)
            expectEqual(started.status, 0, "exit code of start")
            expect(started.output.contains("started"), "output: \(started.output)")

            let stopped = try runCLI(["stop", "--context", "Office A", "--at", "\(day) 17:00"], database: database)
            expect(stopped.output.contains("stopped"), "output: \(stopped.output)")

            let store = try Store(path: database)
            let entries = try store.entries(from: at(day), to: at(day).addingTimeInterval(24 * 3600))
            expectEqual(entries.count, 1)
            expectEqual(entries.first?.duration(), 8 * 3600)
            expectEqual(entries.first?.source, .controlplane)
        }

        test("an unknown context lets the command succeed anyway") {
            let database = NSTemporaryDirectory() + "tickoala-cli-\(UUID().uuidString).sqlite3"
            defer { Fixture.remove(database) }

            let result = try runCLI(["start", "--context", "Café"], database: database)

            expectEqual(result.status, 0, "ControlPlane must not get an error here")
            expect(result.output.contains("unknown context"), "output: \(result.output)")
        }

        test("a missing argument gives exit code 2 with an explanation") {
            let database = NSTemporaryDirectory() + "tickoala-cli-\(UUID().uuidString).sqlite3"
            defer { Fixture.remove(database) }

            let result = try runCLI(["start"], database: database)

            expectEqual(result.status, 2, "exit code on misuse")
            expect(result.output.contains("--context"), "output: \(result.output)")
        }

        test("status --json gives machine-readable output") {
            let database = NSTemporaryDirectory() + "tickoala-cli-\(UUID().uuidString).sqlite3"
            defer { Fixture.remove(database) }

            _ = try runCLI(["profile", "add", "--name", "Organization A", "--context", "Office A"], database: database)
            _ = try runCLI(["project", "add", "--profile", "Organization A", "--number", "2401", "--name", "Migration"], database: database)
            _ = try runCLI(["project", "select", "--number", "2401"], database: database)
            _ = try runCLI(["start", "--context", "Office A"], database: database)

            let result = try runCLI(["status", "--json"], database: database)
            let json = try expectNotNil(
                try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
                "could not read json: \(result.output)"
            )
            expectEqual(json["mode"] as? String, "working")
            let profiles = try expectNotNil(json["profiles"] as? [[String: Any]])
            expectEqual(profiles.first?["project"] as? String, "2401 — Migration")
        }

        test("the adapter command is idempotent on repeat") {
            let database = NSTemporaryDirectory() + "tickoala-cli-\(UUID().uuidString).sqlite3"
            defer { Fixture.remove(database) }

            _ = try runCLI(["profile", "add", "--name", "Organization A", "--context", "Office A"], database: database)
            _ = try runCLI(["project", "add", "--profile", "Organization A", "--number", "2401", "--name", "Migration"], database: database)
            _ = try runCLI(["project", "select", "--number", "2401"], database: database)

            for _ in 0..<3 {
                _ = try runCLI(["start", "--context", "Office A", "--at", "2026-09-10 09:00"], database: database)
            }

            let store = try Store(path: database)
            expectEqual(try store.entries(from: at("2026-09-10"), to: at("2026-09-11")).count, 1, "the same event three times stays one block")
        }

        test("export writes a file") {
            let database = NSTemporaryDirectory() + "tickoala-cli-\(UUID().uuidString).sqlite3"
            let csvPath = NSTemporaryDirectory() + "tickoala-export-\(UUID().uuidString).csv"
            defer {
                Fixture.remove(database)
                try? FileManager.default.removeItem(atPath: csvPath)
            }

            _ = try runCLI(["profile", "add", "--name", "Organization A", "--context", "Office A"], database: database)
            _ = try runCLI(["project", "add", "--profile", "Organization A", "--number", "2401", "--name", "Migration"], database: database)
            _ = try runCLI(["entry", "add", "--number", "2401", "--start", "2026-09-10 09:00", "--end", "2026-09-10 17:00", "--note", "manual block"], database: database)

            let result = try runCLI(["export", "--from", "2026-09-10", "--to", "2026-09-11", "--out", csvPath], database: database)
            expectEqual(result.status, 0, "output: \(result.output)")

            let csv = try String(contentsOfFile: csvPath, encoding: .utf8)
            expect(csv.contains("2401,Migration,2026-09-10,09:00,17:00,8.00,480,0.00,0.00,EUR,completed,manual,manual block"), "content: \(csv)")
        }

        test("updating a block via the command line corrects the duration") {
            let database = NSTemporaryDirectory() + "tickoala-cli-\(UUID().uuidString).sqlite3"
            defer { Fixture.remove(database) }

            _ = try runCLI(["profile", "add", "--name", "Organization A", "--context", "Office A"], database: database)
            _ = try runCLI(["project", "add", "--profile", "Organization A", "--number", "2401", "--name", "Migration"], database: database)
            _ = try runCLI(["entry", "add", "--number", "2401", "--start", "2026-09-10 09:00", "--end", "2026-09-10 17:00"], database: database)
            _ = try runCLI(["entry", "edit", "--id", "1", "--end", "2026-09-10 16:00"], database: database)

            let store = try Store(path: database)
            expectEqual(try store.entry(id: 1)?.duration(), 7 * 3600)
        }
    }
}
