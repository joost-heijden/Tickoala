import Foundation

/// Backing up and restoring the whole database. Everything Tickoala knows lives
/// in one SQLite file, so a backup is one file and a restore replaces it.
///
/// The backup is made with SQLite's own `VACUUM INTO`, which writes a clean,
/// fully-checked copy in one step — it is safe while the app (and the WAL) is
/// running, unlike copying the file by hand.
public enum Backup {
    /// Writes a copy of the store's database to `url`. The parent directory must
    /// exist. Overwrites an existing file.
    public static func write(store: Store, to url: URL) throws {
        // `VACUUM INTO` fails if the target exists; remove it first so a repeated
        // backup to the same name just works.
        try? FileManager.default.removeItem(at: url)
        try store.database.execute("VACUUM INTO '\(escaped(url.path))';")
    }

    /// A default, dated file name such as `tickoala-backup-2026-10-02.sqlite3`
    /// in the desktop or home folder. The caller chooses the folder.
    public static func suggestedFileName(now: Date = Date()) -> String {
        "tickoala-backup-\(Formatting.day(now)).sqlite3"
    }

    /// Reads a backup's basic facts without letting it touch the live database:
    /// row counts and the schema version. Throws when the file is not a Tickoala
    /// database, so a wrong file is refused before anything is replaced.
    public struct Peek: Equatable, Sendable {
        public var schemaVersion: Int
        public var profiles: Int
        public var projects: Int
        public var entries: Int
        public var invoices: Int
        public var expenses: Int

        public var summary: String {
            "\(profiles) client\(profiles == 1 ? "" : "s"), \(entries) block\(entries == 1 ? "" : "s"), "
                + "\(projects) project\(projects == 1 ? "" : "s"), \(invoices) invoice\(invoices == 1 ? "" : "s"), "
                + "\(expenses) expense\(expenses == 1 ? "" : "s")"
        }
    }

    public static func peek(at url: URL) throws -> Peek {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TrackerError.invalidRange("no file at \(url.path)")
        }
        let database: Database
        do {
            // Read-only, so peeking never writes to the backup or creates a WAL
            // beside it; a backup stays one self-contained file.
            database = try Database(path: url.path, readOnly: true)
        } catch {
            throw TrackerError.invalidRange("not a readable database: \(error)")
        }
        // A real Tickoala database has these tables; anything else is refused.
        let version = try database.query("PRAGMA user_version;").first?.int("user_version") ?? 0
        func count(_ table: String) -> Int? {
            try? database.query("SELECT COUNT(*) AS n FROM \(table);").first?.int("n").map(Int.init)
        }
        guard let profiles = count("profiles"), let entries = count("time_entries") else {
            throw TrackerError.invalidRange("this file is not a Tickoala database")
        }
        return Peek(
            schemaVersion: Int(version),
            profiles: profiles,
            projects: count("projects") ?? 0,
            entries: entries,
            invoices: count("invoices") ?? 0,
            expenses: count("expenses") ?? 0
        )
    }

    /// Replaces the database at `destination` with the backup at `source`. The
    /// live database must be closed by the caller first (the app quits or the
    /// caller drops its `Store`). The backup is validated, then copied into place
    /// together with its WAL sidecars cleared, so no stale WAL is left behind.
    public static func restore(from source: URL, to destination: URL, now: Date = Date()) throws {
        let peeked = try peek(at: source)
        // Refuse a backup from a newer schema than this build understands, so a
        // restore never silently drops columns. A missing destination (a fresh
        // install) has no schema to compare against and is allowed.
        if let current = try? peek(at: destination).schemaVersion, peeked.schemaVersion > current {
            throw TrackerError.invalidRange(
                "the backup is from a newer version (schema \(peeked.schemaVersion) > \(current))"
            )
        }
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Keep the current database aside first, so a failed copy cannot lose it.
        let safety = directory.appendingPathComponent(destination.lastPathComponent + ".pre-restore-\(Int(now.timeIntervalSince1970))")
        var moved = false
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: safety)
            try FileManager.default.moveItem(at: destination, to: safety)
            moved = true
        }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            // A stale WAL/SHM from the replaced file would corrupt the new one.
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: destination.path + suffix)
            }
        } catch {
            if moved { try? FileManager.default.moveItem(at: safety, to: destination) }
            throw error
        }
    }

    /// SQL string literal escaping: a single quote is doubled.
    private static func escaped(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "''")
    }
}
