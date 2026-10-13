import Foundation
import SQLite3

// MARK: - Errors

enum SQLiteError: Error, LocalizedError {
    case openFailed(String)
    case execFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "SQLite 打开数据库失败：\(msg)"
        case .execFailed(let msg): return "SQLite 执行失败：\(msg)"
        case .prepareFailed(let msg): return "SQLite 预编译失败：\(msg)"
        case .stepFailed(let msg): return "SQLite step 失败：\(msg)"
        case .bindFailed(let msg): return "SQLite 绑定参数失败：\(msg)"
        }
    }
}

// MARK: - SQLiteDatabase

/// Thin wrapper over the sqlite3 C API.
/// Not internally thread-safe by design — access is serialized by `MessageStore` (actor).
/// `@unchecked Sendable` is safe because the handle is only ever touched from one executor.
final class SQLiteDatabase: @unchecked Sendable {
    private let handle: OpaquePointer?

    /// Opens (or creates) a database at `path`. Use ":memory:" for an in-memory database (tests).
    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw SQLiteError.openFailed(message)
        }
        handle = db
    }

    deinit {
        sqlite3_close(handle)
    }

    var lastErrorMessage: String {
        String(cString: sqlite3_errmsg(handle))
    }

    /// Number of rows changed by the most recently completed statement.
    var changesCount: Int {
        Int(sqlite3_changes(handle))
    }

    /// Executes one or more SQL statements that take no parameters.
    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorMessage)
            throw SQLiteError.execFailed(message)
        }
    }

    /// Runs `body` inside a transaction, committing on success and rolling back on failure.
    /// Callers serialize access (the store is an actor), so nesting cannot happen.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(lastErrorMessage)
        }
        return SQLiteStatement(handle: statement, db: self)
    }

    /// Runs a query and collects all rows via the supplied row reader.
    func query<T>(_ sql: String, bind: (SQLiteStatement) throws -> Void, row: (SQLiteStatement) throws -> T) throws -> [T] {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        try bind(statement)
        var results: [T] = []
        while try statement.step() {
            results.append(try row(statement))
        }
        return results
    }
}

// MARK: - SQLiteStatement

/// A prepared statement. Bind parameters with 1-based indices; read columns with 0-based indices.
final class SQLiteStatement {
    private let handle: OpaquePointer?
    private let db: SQLiteDatabase
    private var finalized = false

    fileprivate init(handle: OpaquePointer?, db: SQLiteDatabase) {
        self.handle = handle
        self.db = db
    }

    deinit {
        // Safety net: statements are expected to be finalized explicitly,
        // but finalize here as well if the caller forgot.
        // sqlite3_finalize must run at most once per statement.
        if !finalized {
            sqlite3_finalize(handle)
        }
    }

    func finalize() {
        if !finalized {
            finalized = true
            sqlite3_finalize(handle)
        }
    }

    // MARK: Binding

    /// SQLITE_TRANSIENT — tells SQLite to copy the bound string.
    private static let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

    private func checkBind(_ result: Int32) throws {
        guard result == SQLITE_OK else {
            throw SQLiteError.bindFailed(db.lastErrorMessage)
        }
    }

    func bindText(_ value: String, at index: Int32) throws {
        try checkBind(sqlite3_bind_text(handle, index, value, -1, Self.transient))
    }

    func bindInt(_ value: Int, at index: Int32) throws {
        try checkBind(sqlite3_bind_int64(handle, index, Int64(value)))
    }

    func bindInt64(_ value: Int64, at index: Int32) throws {
        try checkBind(sqlite3_bind_int64(handle, index, value))
    }

    func bindNull(at index: Int32) throws {
        try checkBind(sqlite3_bind_null(handle, index))
    }

    func bindOptionalText(_ value: String?, at index: Int32) throws {
        if let value {
            try bindText(value, at: index)
        } else {
            try bindNull(at: index)
        }
    }

    func bindOptionalInt(_ value: Int?, at index: Int32) throws {
        if let value {
            try bindInt(value, at: index)
        } else {
            try bindNull(at: index)
        }
    }

    // MARK: Stepping

    /// Advances to the next row. Returns true when a row is available.
    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError.stepFailed(db.lastErrorMessage)
        }
    }

    /// Executes a statement that produces no rows (INSERT/UPDATE/DELETE).
    func run() throws {
        while try step() {}
    }

    // MARK: Reading columns

    func columnText(_ index: Int32) -> String? {
        guard sqlite3_column_type(handle, index) != SQLITE_NULL else { return nil }
        guard let cString = sqlite3_column_text(handle, index) else { return nil }
        return String(cString: cString)
    }

    func columnInt(_ index: Int32) -> Int? {
        guard sqlite3_column_type(handle, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(handle, index))
    }
}
