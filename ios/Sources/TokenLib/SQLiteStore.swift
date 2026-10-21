//
//  SQLiteStore.swift
//  TokenLib
//
//  The SQLite implementation of the repositories, on the sqlite3 C API so it
//  runs on Apple platforms and Linux alike. One file, three tables.
//

import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

public enum SQLiteError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String)
    case step(String)
    public var description: String {
        switch self {
        case .open(let m): return "sqlite open: \(m)"
        case .prepare(let m): return "sqlite prepare: \(m)"
        case .step(let m): return "sqlite step: \(m)"
        }
    }
}

public final class SQLiteStore: TokenStore {
    private var db: OpaquePointer?
    private let lock = NSLock()
    public static let schemaVersion = 1
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens (and creates) the database at `path`; `":memory:"` for a private in-memory database.
    public init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let h = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let h = handle { sqlite3_close(h) }
            throw SQLiteError.open(message)
        }
        db = h
        try exec("PRAGMA journal_mode=WAL")
        try exec("""
        CREATE TABLE IF NOT EXISTS keys (provider TEXT PRIMARY KEY, data BLOB NOT NULL, updated_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS usage (
            id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, consumer TEXT NOT NULL, profile TEXT NOT NULL,
            provider TEXT NOT NULL, model TEXT NOT NULL, prompt_tokens INTEGER NOT NULL, reply_tokens INTEGER NOT NULL,
            cost_micros INTEGER NOT NULL, stop TEXT NOT NULL, prompt TEXT, reply TEXT);
        CREATE INDEX IF NOT EXISTS usage_at ON usage(at);
        CREATE INDEX IF NOT EXISTS usage_consumer ON usage(consumer, at);
        """)
    }

    deinit { if let db = db { sqlite3_close(db) } }

    /// Moves a database and its WAL, shared-memory and journal files to a new path, for a rename of the file.
    /// Returns false, and moves nothing, when there is no file at `from` or one already exists at `to`.
    /// Call it before either path is opened.
    @discardableResult
    public static func moveDatabase(from: String, to: String) throws -> Bool {
        let files = FileManager.default
        guard files.fileExists(atPath: from), !files.fileExists(atPath: to) else { return false }
        for suffix in ["", "-wal", "-shm", "-journal"] where files.fileExists(atPath: from + suffix) {
            try files.moveItem(atPath: from + suffix, toPath: to + suffix)
        }
        return true
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw SQLiteError.step(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let s = statement else { throw SQLiteError.prepare(String(cString: sqlite3_errmsg(db))) }
        return s
    }

    private func bind(_ s: OpaquePointer, _ values: [Any?]) {
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case nil: sqlite3_bind_null(s, index)
            case let v as String: sqlite3_bind_text(s, index, v, -1, SQLiteStore.transient)
            case let v as Int: sqlite3_bind_int64(s, index, Int64(v))
            case let v as Int64: sqlite3_bind_int64(s, index, v)
            case let v as Double: sqlite3_bind_double(s, index, v)
            case let v as Data: v.withUnsafeBytes { sqlite3_bind_blob(s, index, $0.baseAddress, Int32(v.count), SQLiteStore.transient) }
            default: sqlite3_bind_text(s, index, "\(value!)", -1, SQLiteStore.transient)
            }
        }
    }

    private func run(_ sql: String, _ values: [Any?] = []) throws {
        lock.lock(); defer { lock.unlock() }
        let s = try prepare(sql)
        defer { sqlite3_finalize(s) }
        bind(s, values)
        guard sqlite3_step(s) == SQLITE_DONE else { throw SQLiteError.step(String(cString: sqlite3_errmsg(db))) }
    }

    private func query<T>(_ sql: String, _ values: [Any?] = [], row: (OpaquePointer) -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        let s = try prepare(sql)
        defer { sqlite3_finalize(s) }
        bind(s, values)
        var out: [T] = []
        while true {
            let code = sqlite3_step(s)
            if code == SQLITE_ROW { out.append(row(s)) } else if code == SQLITE_DONE { break } else { throw SQLiteError.step(String(cString: sqlite3_errmsg(db))) }
        }
        return out
    }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String? { sqlite3_column_text(s, i).map { String(cString: $0) } }
    private static func blob(_ s: OpaquePointer, _ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(s, i) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(s, i)))
    }

    // MARK: KeyRepository

    public func keyData(for provider: ProviderKind) throws -> Data? {
        try query("SELECT data FROM keys WHERE provider = ?", [provider.rawValue]) { SQLiteStore.blob($0, 0) }.first ?? nil
    }

    public func setKeyData(_ data: Data?, for provider: ProviderKind) throws {
        if let data = data {
            try run("INSERT INTO keys(provider, data, updated_at) VALUES(?, ?, ?) ON CONFLICT(provider) DO UPDATE SET data = excluded.data, updated_at = excluded.updated_at", [provider.rawValue, data, Date().timeIntervalSince1970])
        } else {
            try run("DELETE FROM keys WHERE provider = ?", [provider.rawValue])
        }
    }

    public func providersWithKeys() throws -> [ProviderKind] {
        try query("SELECT provider FROM keys ORDER BY provider") { SQLiteStore.text($0, 0) }.compactMap { $0.flatMap(ProviderKind.init) }
    }

    // MARK: SettingsRepository

    public func settings() throws -> Settings {
        let rows = try query("SELECT key, value FROM settings") { (SQLiteStore.text($0, 0) ?? "", SQLiteStore.text($0, 1)) }
        var s = Settings()
        for (key, value) in rows {
            switch key {
            case "enabled": s.enabled = value != "0"
            case "activeProvider": s.activeProvider = value.flatMap(ProviderKind.init)
            case "localBaseURL": s.localBaseURL = value
            case "localModel": s.localModel = value
            case "dailyTokenCap": s.dailyTokenCap = value.flatMap(Int.init)
            case "logPrompts": s.logPrompts = value == "1"
            default:
                // credit.<provider> = "<micros> <spentMicros>"
                guard key.hasPrefix("credit."), let provider = ProviderKind(rawValue: String(key.dropFirst(7))) else { break }
                let parts = (value ?? "").split(separator: " ").compactMap { Int64($0) }
                if parts.count == 2 { s.credits[provider] = Credit(micros: parts[0], spentMicros: parts[1]) }
            }
        }
        return s
    }

    public func save(_ settings: Settings) throws {
        let pairs: [(String, String?)] = [
            ("enabled", settings.enabled ? "1" : "0"), ("activeProvider", settings.activeProvider?.rawValue), ("localBaseURL", settings.localBaseURL), ("localModel", settings.localModel),
            ("dailyTokenCap", settings.dailyTokenCap.map(String.init)), ("logPrompts", settings.logPrompts ? "1" : "0"),
        ] + ProviderKind.allCases.map { ("credit." + $0.rawValue, settings.credits[$0].map { "\($0.micros) \($0.spentMicros)" }) }
        for (key, value) in pairs {
            try run("INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value])
        }
    }

    // MARK: UsageRepository

    public func record(_ usage: UsageRecord) throws -> UsageRecord {
        try run("INSERT INTO usage(at, consumer, profile, provider, model, prompt_tokens, reply_tokens, cost_micros, stop, prompt, reply) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                [usage.at.timeIntervalSince1970, usage.consumer, usage.profile.rawValue, usage.provider.rawValue, usage.model, usage.promptTokens, usage.replyTokens, usage.costMicros, usage.stop.rawValue, usage.prompt, usage.reply])
        var r = usage
        lock.lock(); r.id = sqlite3_last_insert_rowid(db); lock.unlock()
        return r
    }

    public func totals(since date: Date, consumer: String?) throws -> UsageTotals {
        let sql = "SELECT COUNT(*), COALESCE(SUM(prompt_tokens),0), COALESCE(SUM(reply_tokens),0), COALESCE(SUM(cost_micros),0) FROM usage WHERE at >= ?" + (consumer == nil ? "" : " AND consumer = ?")
        let values: [Any?] = consumer == nil ? [date.timeIntervalSince1970] : [date.timeIntervalSince1970, consumer]
        return try query(sql, values) { UsageTotals(requests: Int(sqlite3_column_int64($0, 0)), promptTokens: Int(sqlite3_column_int64($0, 1)), replyTokens: Int(sqlite3_column_int64($0, 2)), costMicros: sqlite3_column_int64($0, 3)) }.first ?? UsageTotals()
    }

    public func recent(limit: Int, consumer: String?) throws -> [UsageRecord] {
        let sql = "SELECT id, at, consumer, profile, provider, model, prompt_tokens, reply_tokens, cost_micros, stop, prompt, reply FROM usage" + (consumer == nil ? "" : " WHERE consumer = ?") + " ORDER BY id DESC LIMIT ?"
        let values: [Any?] = consumer == nil ? [limit] : [consumer, limit]
        return try query(sql, values) { s in
            UsageRecord(id: sqlite3_column_int64(s, 0), at: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)), consumer: SQLiteStore.text(s, 2) ?? "",
                        profile: Profile(rawValue: SQLiteStore.text(s, 3) ?? "") ?? .assistant, provider: ProviderKind(rawValue: SQLiteStore.text(s, 4) ?? "") ?? .anthropic,
                        model: SQLiteStore.text(s, 5) ?? "", promptTokens: Int(sqlite3_column_int64(s, 6)), replyTokens: Int(sqlite3_column_int64(s, 7)),
                        costMicros: sqlite3_column_int64(s, 8), stop: StopReason(rawValue: SQLiteStore.text(s, 9) ?? "") ?? .other, prompt: SQLiteStore.text(s, 10), reply: SQLiteStore.text(s, 11))
        }
    }

    public func deleteAll() throws { try run("DELETE FROM usage") }
}
