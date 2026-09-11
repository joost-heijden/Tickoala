import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum DatabaseError: Error, CustomStringConvertible {
    case open(String)
    case statement(String)
    case constraint(String)

    public var description: String {
        switch self {
        case .open(let m): return "cannot open database: \(m)"
        case .statement(let m): return "database error: \(m)"
        case .constraint(let m): return m
        }
    }
}

/// Value that can be written to or read from SQLite.
public enum SQLValue: Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
}

public final class Database {
    private var handle: OpaquePointer?

    public init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close_v2(db)
            throw DatabaseError.open(message)
        }
        self.handle = db
        // WAL lets the menu bar app and the adapter command work at the same time.
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA busy_timeout = 5000;")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    public func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw DatabaseError.statement(message)
        }
    }

    @discardableResult
    public func run(_ sql: String, _ parameters: [SQLValue] = []) throws -> Int64 {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw currentError()
        }
        return sqlite3_last_insert_rowid(handle)
    }

    public func query(_ sql: String, _ parameters: [SQLValue] = []) throws -> [Row] {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }

        var columns: [String] = []
        for index in 0..<sqlite3_column_count(statement) {
            columns.append(String(cString: sqlite3_column_name(statement, index)))
        }

        var rows: [Row] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw currentError() }

            var values: [String: SQLValue] = [:]
            for (index, name) in columns.enumerated() {
                let i = Int32(index)
                switch sqlite3_column_type(statement, i) {
                case SQLITE_NULL:
                    values[name] = .null
                case SQLITE_INTEGER:
                    values[name] = .int(sqlite3_column_int64(statement, i))
                case SQLITE_FLOAT:
                    values[name] = .double(sqlite3_column_double(statement, i))
                default:
                    if let raw = sqlite3_column_text(statement, i) {
                        values[name] = .text(String(cString: raw))
                    } else {
                        values[name] = .null
                    }
                }
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    /// Runs `body` in a single transaction; on error everything is rolled back.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let value = try body()
            try execute("COMMIT;")
            return value
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public var changes: Int32 { sqlite3_changes(handle) }

    private func prepare(_ sql: String, _ parameters: [SQLValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw currentError()
        }
        for (index, parameter) in parameters.enumerated() {
            let position = Int32(index + 1)
            switch parameter {
            case .null:
                sqlite3_bind_null(statement, position)
            case .int(let value):
                sqlite3_bind_int64(statement, position, value)
            case .double(let value):
                sqlite3_bind_double(statement, position, value)
            case .text(let value):
                sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT)
            }
        }
        return statement
    }

    private func currentError() -> DatabaseError {
        let message = String(cString: sqlite3_errmsg(handle))
        if sqlite3_extended_errcode(handle) & 0xFF == SQLITE_CONSTRAINT {
            return .constraint(message)
        }
        return .statement(message)
    }
}

/// One row from a query, with typed accessors.
public struct Row {
    public let values: [String: SQLValue]

    public func int(_ column: String) -> Int64? {
        if case .int(let value)? = values[column] { return value }
        if case .double(let value)? = values[column] { return Int64(value) }
        return nil
    }

    public func double(_ column: String) -> Double? {
        if case .double(let value)? = values[column] { return value }
        if case .int(let value)? = values[column] { return Double(value) }
        return nil
    }

    public func string(_ column: String) -> String? {
        if case .text(let value)? = values[column] { return value }
        return nil
    }

    public func bool(_ column: String) -> Bool {
        (int(column) ?? 0) != 0
    }

    public func date(_ column: String) -> Date? {
        guard let seconds = int(column) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}
