import Foundation
import SQLCipher

enum DatabaseError: Error, LocalizedError {
    case keyUnavailable
    case open(String)
    case notEncrypted
    case sql(String)

    var errorDescription: String? {
        switch self {
        case .keyUnavailable: "The database key is unavailable. Unlock the device and try again."
        case .open(let m): "Could not open the encrypted database: \(m)"
        case .notEncrypted: "SQLCipher is not active; refusing to store data unencrypted."
        case .sql(let m): "Database error: \(m)"
        }
    }
}

enum SQLValue: Hashable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)

    var string: String? { if case .text(let s) = self { s } else { nil } }
    var int: Int? { if case .int(let i) = self { Int(i) } else { nil } }
    var bool: Bool { int.map { $0 != 0 } ?? false }
}

extension Optional where Wrapped == String {
    var sql: SQLValue { self.map(SQLValue.text) ?? .null }
}
extension String { var sql: SQLValue { .text(self) } }
extension Int { var sql: SQLValue { .int(Int64(self)) } }
extension Bool { var sql: SQLValue { .int(self ? 1 : 0) } }

typealias Row = [String: SQLValue]

/// SQLCipher database (AES-256, encrypted pages, WAL and journals). Key comes from a device-only Keychain entry.
final class EncryptedDatabase {
    private var db: OpaquePointer?
    let url: URL

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL? = nil, filename: String = "ledger.sqlite") throws {
        let dir = try directory ?? EncryptedDatabase.dataDirectory()
        url = dir.appendingPathComponent(filename)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw DatabaseError.open(String(cString: sqlite3_errmsg(handle)))
        }
        db = handle

        let key = try Keychain.databaseKey()
        let hex = key.map { String(format: "%02x", $0) }.joined()
        // Raw 256-bit key: no passphrase derivation needed.
        try exec("PRAGMA key = \"x'\(hex)'\";")
        // Fails here if the key is wrong or the file is not a SQLCipher database.
        guard let version = try query("PRAGMA cipher_version;").first?.values.first?.string, !version.isEmpty else {
            throw DatabaseError.notEncrypted
        }
        _ = try query("SELECT count(*) FROM sqlite_master;")
        try exec("PRAGMA foreign_keys = ON;")
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA secure_delete = ON;")
        try EncryptedDatabase.protect(dir)
    }

    deinit { sqlite3_close_v2(db) }

    /// Application Support/Ledger — excluded from backup, Complete file protection (design §6).
    static func dataDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Ledger", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        try protect(dir)
        return dir
    }

    /// Reapplied on every open because replacing files can drop the attributes.
    static func protect(_ dir: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var d = dir
        try d.setResourceValues(values)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for var f in files {
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: f.path)
            try? f.setResourceValues(values)
        }
    }

    // MARK: - Statements

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DatabaseError.sql(message)
        }
    }

    func run(_ sql: String, _ args: [SQLValue] = []) throws {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DatabaseError.sql(lastError) }
    }

    func query(_ sql: String, _ args: [SQLValue] = []) throws -> [Row] {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw DatabaseError.sql(lastError) }
            var row: Row = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// One atomic transaction; rolls back on any thrown error.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try exec("COMMIT;")
            return result
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    var userVersion: Int {
        get { (try? query("PRAGMA user_version;").first?["user_version"]?.int) ?? 0 }
    }
    func setUserVersion(_ v: Int) throws { try exec("PRAGMA user_version = \(v);") }

    private var lastError: String { String(cString: sqlite3_errmsg(db)) }

    private func prepare(_ sql: String, _ args: [SQLValue]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw DatabaseError.sql(lastError) }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .real(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, EncryptedDatabase.transient)
            }
        }
        return stmt
    }
}
