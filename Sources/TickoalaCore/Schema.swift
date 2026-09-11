import Foundation

/// Migraties worden op volgorde toegepast; `user_version` houdt bij hoe ver we zijn.
enum Schema {
    static let migrations: [String] = [
        """
        CREATE TABLE profiles (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            active INTEGER NOT NULL DEFAULT 1,
            created_at INTEGER NOT NULL
        );

        -- Eén-op-veel: een profiel kan aan meerdere wifinetwerken hangen
        -- (bijvoorbeeld een gast- en een personeelsnetwerk bij dezelfde klant).
        -- Eén context hoort maar bij één profiel.
        CREATE TABLE profile_contexts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
            context_name TEXT NOT NULL UNIQUE COLLATE NOCASE,
            created_at INTEGER NOT NULL
        );

        CREATE INDEX idx_profile_contexts_profile ON profile_contexts (profile_id);

        CREATE TABLE projects (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
            number TEXT NOT NULL,
            name TEXT NOT NULL,
            active INTEGER NOT NULL DEFAULT 1,
            created_at INTEGER NOT NULL,
            UNIQUE (profile_id, number)
        );

        CREATE TABLE time_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
            project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
            started_at INTEGER NOT NULL,
            ended_at INTEGER,
            status TEXT NOT NULL,
            source TEXT NOT NULL,
            note TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );

        CREATE INDEX idx_entries_profile_start ON time_entries (profile_id, started_at);
        CREATE INDEX idx_entries_status ON time_entries (status);

        CREATE TABLE profile_state (
            profile_id INTEGER PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
            active_project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
            paused INTEGER NOT NULL DEFAULT 0,
            pending_stop_at INTEGER,
            pending_stop_entry_id INTEGER REFERENCES time_entries(id) ON DELETE SET NULL,
            attention TEXT
        );

        CREATE TABLE events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            context_name TEXT NOT NULL,
            kind TEXT NOT NULL,
            occurred_at INTEGER NOT NULL,
            dedupe_key TEXT NOT NULL UNIQUE,
            outcome TEXT NOT NULL,
            detail TEXT,
            created_at INTEGER NOT NULL
        );

        CREATE TABLE settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """,

        // Automatische pauzeaftrek per klant. Staat standaard uit, zodat bestaande
        // registraties ongewijzigd blijven tot de regel bewust wordt aangezet.
        """
        ALTER TABLE profiles ADD COLUMN break_enabled INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE profiles ADD COLUMN break_minutes INTEGER NOT NULL DEFAULT 30;
        ALTER TABLE profiles ADD COLUMN break_threshold_minutes INTEGER NOT NULL DEFAULT 360;
        """,

        // Uurtarief per klant, in hele centen. Nul betekent: nog geen tarief, er
        // worden dan ook geen bedragen getoond.
        """
        ALTER TABLE profiles ADD COLUMN hourly_rate_cents INTEGER NOT NULL DEFAULT 0;
        """,
    ]

    static func migrate(_ database: Database) throws {
        let current = try database.query("PRAGMA user_version;").first?.int("user_version") ?? 0
        guard Int(current) < migrations.count else { return }
        for index in Int(current)..<migrations.count {
            try database.execute("BEGIN;\n" + migrations[index] + "\nPRAGMA user_version = \(index + 1);\nCOMMIT;")
        }
    }
}
