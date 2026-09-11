import Foundation

/// Migrations are applied in order; `user_version` tracks how far we've come.
enum Schema {
    static let migrations: [String] = [
        """
        CREATE TABLE profiles (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            active INTEGER NOT NULL DEFAULT 1,
            created_at INTEGER NOT NULL
        );

        -- One-to-many: a profile can be linked to multiple Wi-Fi networks
        -- (for example a guest and a staff network at the same client).
        -- A context belongs to only one profile.
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

        // Automatic break deduction per client. Off by default, so existing
        // registrations stay unchanged until the rule is deliberately enabled.
        """
        ALTER TABLE profiles ADD COLUMN break_enabled INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE profiles ADD COLUMN break_minutes INTEGER NOT NULL DEFAULT 30;
        ALTER TABLE profiles ADD COLUMN break_threshold_minutes INTEGER NOT NULL DEFAULT 360;
        """,

        // Hourly rate per client, in whole cents. Zero means: no rate yet, and
        // no amounts are shown either.
        """
        ALTER TABLE profiles ADD COLUMN hourly_rate_cents INTEGER NOT NULL DEFAULT 0;
        """,

        // Currency per client. Existing clients invoice in euros.
        """
        ALTER TABLE profiles ADD COLUMN currency TEXT NOT NULL DEFAULT 'EUR';
        """,

        // Billing data per client, only used for the invoice. All optional; a
        // client without them still produces an invoice, just a barer one.
        """
        ALTER TABLE profiles ADD COLUMN billing_address TEXT;
        ALTER TABLE profiles ADD COLUMN vat_number TEXT;
        ALTER TABLE profiles ADD COLUMN vat_rate_percent INTEGER NOT NULL DEFAULT 21;
        ALTER TABLE profiles ADD COLUMN po_number TEXT;
        """,

        // Who receives the invoice when you send it straight from the app.
        """
        ALTER TABLE profiles ADD COLUMN billing_email TEXT;
        """,

        // Issued invoices, so a number is allocated once per client per month and
        // re-generating the same month never produces a duplicate.
        """
        CREATE TABLE invoices (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
            period_start INTEGER NOT NULL,
            period_end INTEGER NOT NULL,
            number TEXT NOT NULL UNIQUE,
            po_number TEXT,
            issued_at INTEGER NOT NULL,
            total_cents INTEGER NOT NULL,
            currency TEXT NOT NULL,
            UNIQUE (profile_id, period_start)
        );
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
