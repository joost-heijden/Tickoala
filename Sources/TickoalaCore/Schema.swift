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

        // Optional location per client, for detection by place instead of by
        // network name. A client without coordinates keeps working on Wi-Fi.
        """
        ALTER TABLE profiles ADD COLUMN latitude REAL;
        ALTER TABLE profiles ADD COLUMN longitude REAL;
        ALTER TABLE profiles ADD COLUMN presence_radius_m INTEGER NOT NULL DEFAULT 150;
        """,

        // A break as part of a block rather than a gap between two blocks, so the
        // day stays one row. Empty for the usual case; both are set when a break
        // is recorded.
        """
        ALTER TABLE time_entries ADD COLUMN break_started_at INTEGER;
        ALTER TABLE time_entries ADD COLUMN break_ended_at INTEGER;
        """,

        // Extra copy (CC) addresses per client, on top of the global ones.
        """
        ALTER TABLE profiles ADD COLUMN billing_cc TEXT;
        """,

        // Optional hour budget per project, in minutes. Zero means: no budget,
        // and the burn-down and warnings stay off for this project.
        """
        ALTER TABLE projects ADD COLUMN budget_minutes INTEGER NOT NULL DEFAULT 0;
        """,

        // Expenses and mileage per client, billed on the invoice. A mileage entry
        // keeps its kilometres and the rate used at the time; an expense keeps its
        // amount. The default rate per kilometre lives on the client.
        """
        ALTER TABLE profiles ADD COLUMN km_rate_cents INTEGER NOT NULL DEFAULT 0;

        CREATE TABLE expenses (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
            date INTEGER NOT NULL,
            description TEXT NOT NULL,
            kind TEXT NOT NULL DEFAULT 'expense',
            quantity REAL NOT NULL DEFAULT 1,
            unit_rate_cents INTEGER NOT NULL DEFAULT 0,
            amount_cents INTEGER NOT NULL DEFAULT 0,
            billable INTEGER NOT NULL DEFAULT 1,
            note TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );

        CREATE INDEX idx_expenses_profile_date ON expenses (profile_id, date);
        """,

        // Billing rules per client: rounding of the invoiced time, a minimum to
        // bill, and evening/weekend surcharges. All zero by default, which leaves
        // the invoice exactly as it was.
        """
        ALTER TABLE profiles ADD COLUMN rounding_minutes INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE profiles ADD COLUMN rounding_up INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE profiles ADD COLUMN minimum_minutes INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE profiles ADD COLUMN evening_surcharge_percent INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE profiles ADD COLUMN weekend_surcharge_percent INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE profiles ADD COLUMN evening_start_minutes INTEGER NOT NULL DEFAULT 1080;
        """,

        // Travel time: a block can be work, travel to a client, or the commute.
        // Travel and commute get their own rate per client, so they land on the
        // invoice as their own line. Everything recorded before this is work.
        """
        ALTER TABLE time_entries ADD COLUMN kind TEXT NOT NULL DEFAULT 'work';
        ALTER TABLE profiles ADD COLUMN travel_rate_cents INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE profiles ADD COLUMN commute_rate_cents INTEGER NOT NULL DEFAULT 0;
        """,

        // A fixed monthly amount per client, added to every invoice as its own
        // line. Optional: a client without a retainer invoices exactly as before.
        """
        CREATE TABLE retainers (
            profile_id INTEGER PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
            description TEXT NOT NULL DEFAULT '',
            amount_cents INTEGER NOT NULL DEFAULT 0,
            active INTEGER NOT NULL DEFAULT 1
        );
        """,

        // Public holidays and vacation days. Marked by the user, not tied to a
        // client: a day off is a day off everywhere.
        """
        CREATE TABLE non_working_days (
            day INTEGER PRIMARY KEY,
            label TEXT NOT NULL DEFAULT '',
            kind TEXT NOT NULL DEFAULT 'holiday'
        );
        """,

        // Credit notes. A credit is an invoice in reverse: it shares the credited
        // invoice's customer and period, carries its own number and points at the
        // invoice it changes. That is what the Belastingdienst asks of a document
        // that amends an earlier invoice. The uniqueness moves to the pair
        // (customer, period, kind) so one invoice and one credit can coexist; the
        // table is rebuilt because SQLite cannot drop the old unique constraint.
        """
        CREATE TABLE invoices_new (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
            period_start INTEGER NOT NULL,
            period_end INTEGER NOT NULL,
            number TEXT NOT NULL UNIQUE,
            po_number TEXT,
            issued_at INTEGER NOT NULL,
            total_cents INTEGER NOT NULL,
            currency TEXT NOT NULL,
            is_credit INTEGER NOT NULL DEFAULT 0,
            credit_for TEXT,
            UNIQUE (profile_id, period_start, is_credit)
        );
        INSERT INTO invoices_new
            (id, profile_id, period_start, period_end, number, po_number, issued_at, total_cents, currency, is_credit, credit_for)
            SELECT id, profile_id, period_start, period_end, number, po_number, issued_at, total_cents, currency, 0, NULL
            FROM invoices;
        DROP TABLE invoices;
        ALTER TABLE invoices_new RENAME TO invoices;
        """,

        // Idle time that was discarded on a block, in seconds. A calculation on
        // top of the raw block, exactly like the break deduction: the recorded
        // start and end stay untouched, only the worked duration drops. Zero on
        // every existing block.
        """
        ALTER TABLE time_entries ADD COLUMN idle_seconds INTEGER NOT NULL DEFAULT 0;
        """,

        // Payment state of an issued invoice: when it was paid (NULL while it is
        // still open) and when it was due. The due date is stored so later
        // changing the payment term does not move it; rows issued before this
        // column exists get it computed from the current term when read.
        """
        ALTER TABLE invoices ADD COLUMN due_at INTEGER;
        ALTER TABLE invoices ADD COLUMN paid_at INTEGER;
        """,

        // Free-form labels on a block, stored comma-separated. NULL when a block
        // has none, which is every block recorded before this column existed.
        """
        ALTER TABLE time_entries ADD COLUMN tags TEXT;
        """,

        // Tags brought in by an import while the tags feature was off, held aside
        // so switching tags on later does not lose them. NULL in normal use.
        """
        ALTER TABLE time_entries ADD COLUMN imported_tags TEXT;
        """,

        // When a retainer runs to. NULL means open-ended (until switched off).
        // Nesting is checked: setting a new end that would close before a nested
        // retainer's own end is refused.
        """
        ALTER TABLE retainers ADD COLUMN ends_at INTEGER;
        ALTER TABLE retainers ADD COLUMN recurrence TEXT NOT NULL DEFAULT 'monthly';
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
