import Darwin
import Foundation
import SQLite3

/// One writer per state directory. State lives in a local SQLite database with one row per record,
/// so a commit writes only the rows that changed instead of rewriting the whole journal.
nonisolated final class ArchivePersistence: @unchecked Sendable {
    let directory: URL
    private let directoryFD: Int32
    private let lockFD: Int32
    private var db: OpaquePointer?
    /// Encoded rows as they are on disk, keyed by collection then record key; `save` diffs against it.
    private var rows: [String: [String: Row]] = [:]
    private var meta: [String: Data] = [:]

    private struct Row: Equatable {
        var position: Int
        var data: Data
    }

    private enum Collection {
        static let rules = "rules"
        static let suggestions = "suggestions"
        static let operations = "operations"
        static let observations = "observations"
        static let cache = "cache"
        static let plans = "plans"
        static let settled = "settled"
        static let all = [rules, suggestions, operations, observations, cache, plans, settled]
    }

    private enum Meta {
        static let configuration = "configuration"
        static let version = "version"
        static let report = "report"
        static let aiPresent = "ai.present"
        static let settledPresent = "settled.present"
    }

    static let databaseName = "archive.sqlite"
    static let legacyName = "archive.json"

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("inchspace/AutoArchive", isDirectory: true)
            .resolvingSymlinksInPath()
    }

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let fd = try ArchiveFileSystem.openDirectory(self.directory)
        let lock = openat(fd, "archive.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else {
            close(fd)
            throw ArchiveError("无法打开归档记录锁。")
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            close(fd)
            throw ArchiveError("另一应用实例正在使用自动归档，请先关闭该实例。")
        }
        directoryFD = fd
        lockFD = lock
        _ = fchmod(fd, 0o700)
        _ = fchmod(lock, 0o600)
        do {
            try open()
            try migrateLegacyJournalIfNeeded()
        } catch {
            closeAll()
            throw error
        }
    }

    deinit { closeAll() }

    private func closeAll() {
        if let db { sqlite3_close_v2(db) }
        db = nil
        _ = flock(lockFD, LOCK_UN)
        close(lockFD)
        close(directoryFD)
    }

    // MARK: Public API

    func load() throws -> ArchiveState {
        let decoder = JSONDecoder()
        var state = ArchiveState()
        do {
            if let data = meta[Meta.configuration] { state.configuration = try decoder.decode(ArchiveConfiguration.self, from: data) }
            if let data = meta[Meta.version] { state.version = try decoder.decode(Int.self, from: data) }
            if let data = meta[Meta.report] { state.report = try decoder.decode(ArchiveLearningReport.self, from: data) }
            state.rules = try ordered(Collection.rules).map { try decoder.decode(ArchiveRule.self, from: $0) }
            state.suggestions = try ordered(Collection.suggestions).map { try decoder.decode(ArchiveSuggestion.self, from: $0) }
            state.operations = try ordered(Collection.operations).map { try decoder.decode(ArchiveOperation.self, from: $0) }
            state.observations = try (rows[Collection.observations] ?? [:]).mapValues { try decoder.decode(ArchiveObservation.self, from: $0.data) }
            state.cache = try (rows[Collection.cache] ?? [:]).mapValues { try decoder.decode(ArchiveEvidence.self, from: $0.data) }
            if meta[Meta.aiPresent] != nil {
                state.ai = ArchiveAIState(plans: try ordered(Collection.plans).map { try decoder.decode(ArchiveAIPlan.self, from: $0) })
            }
            if meta[Meta.settledPresent] != nil {
                state.settled = try (rows[Collection.settled] ?? [:]).mapValues { try decoder.decode(ArchiveFingerprint.self, from: $0.data) }
            }
        } catch {
            throw ArchiveError("归档记录无法解析，请检查 \(directory.appendingPathComponent(Self.databaseName).path)。原文件已保留。")
        }
        return state
    }

    func save(_ state: ArchiveState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var nextMeta: [String: Data] = [
            Meta.configuration: try encoder.encode(state.configuration),
            Meta.version: try encoder.encode(state.version),
        ]
        if let report = state.report { nextMeta[Meta.report] = try encoder.encode(report) }
        if state.ai != nil { nextMeta[Meta.aiPresent] = Data([1]) }
        if state.settled != nil { nextMeta[Meta.settledPresent] = Data([1]) }

        var nextRows: [String: [String: Row]] = [:]
        nextRows[Collection.rules] = try indexed(state.rules, key: { $0.directory.path }, encoder: encoder)
        nextRows[Collection.suggestions] = try indexed(state.suggestions, key: { $0.id.uuidString }, encoder: encoder)
        nextRows[Collection.operations] = try indexed(state.operations, key: { $0.id.uuidString }, encoder: encoder)
        nextRows[Collection.plans] = try indexed(state.ai?.plans ?? [], key: { $0.id.uuidString }, encoder: encoder)
        nextRows[Collection.observations] = try state.observations.mapValues { Row(position: 0, data: try encoder.encode($0)) }
        nextRows[Collection.cache] = try state.cache.mapValues { Row(position: 0, data: try encoder.encode($0)) }
        nextRows[Collection.settled] = try (state.settled ?? [:]).mapValues { Row(position: 0, data: try encoder.encode($0)) }

        try transaction {
            for (key, data) in nextMeta where meta[key] != data { try upsertMeta(key, data) }
            for key in meta.keys where nextMeta[key] == nil { try deleteMeta(key) }
            for collection in Collection.all {
                let current = rows[collection] ?? [:]
                let next = nextRows[collection] ?? [:]
                for (key, row) in next where current[key] != row { try upsertRow(collection, key: key, row: row) }
                for key in current.keys where next[key] == nil { try deleteRow(collection, key: key) }
            }
        }
        meta = nextMeta
        rows = nextRows
    }

    // MARK: Encoding helpers

    private func indexed<T: Encodable>(_ items: [T], key: (T) -> String, encoder: JSONEncoder) throws -> [String: Row] {
        var result: [String: Row] = [:]
        for (position, item) in items.enumerated() {
            // A duplicate key keeps its first occurrence so the row count matches a set of records.
            if result[key(item)] == nil { result[key(item)] = Row(position: position, data: try encoder.encode(item)) }
        }
        return result
    }

    private func ordered(_ collection: String) -> [Data] {
        (rows[collection] ?? [:]).values.sorted { $0.position < $1.position }.map(\.data)
    }

    // MARK: SQLite

    private func open() throws {
        let path = directory.appendingPathComponent(Self.databaseName).path
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw ArchiveError("无法打开归档记录数据库。")
        }
        db = handle
        _ = chmod(path, 0o600)
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        try execute("""
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL)
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS records (
            collection TEXT NOT NULL, key TEXT NOT NULL, position INTEGER NOT NULL DEFAULT 0, value BLOB NOT NULL,
            PRIMARY KEY (collection, key)
        )
        """)
        try readAll()
    }

    private func readAll() throws {
        meta = [:]
        rows = [:]
        let metaStatement = try prepare("SELECT key, value FROM meta")
        defer { sqlite3_finalize(metaStatement) }
        while sqlite3_step(metaStatement) == SQLITE_ROW {
            guard let key = sqlite3_column_text(metaStatement, 0) else { continue }
            meta[String(cString: key)] = blob(metaStatement, column: 1)
        }
        let rowStatement = try prepare("SELECT collection, key, position, value FROM records")
        defer { sqlite3_finalize(rowStatement) }
        while sqlite3_step(rowStatement) == SQLITE_ROW {
            guard let collection = sqlite3_column_text(rowStatement, 0), let key = sqlite3_column_text(rowStatement, 1) else { continue }
            rows[String(cString: collection), default: [:]][String(cString: key)] =
                Row(position: Int(sqlite3_column_int64(rowStatement, 2)), data: blob(rowStatement, column: 3))
        }
    }

    private func blob(_ statement: OpaquePointer?, column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw ArchiveError("无法提交归档记录，已停止操作。\(error.localizedDescription)")
        }
    }

    private func upsertMeta(_ key: String, _ value: Data) throws {
        let statement = try prepare("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, key)
        try bind(statement, 2, value)
        try step(statement)
    }

    private func deleteMeta(_ key: String) throws {
        let statement = try prepare("DELETE FROM meta WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, key)
        try step(statement)
    }

    private func upsertRow(_ collection: String, key: String, row: Row) throws {
        let statement = try prepare("""
        INSERT INTO records (collection, key, position, value) VALUES (?, ?, ?, ?)
        ON CONFLICT(collection, key) DO UPDATE SET position = excluded.position, value = excluded.value
        """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, collection)
        try bind(statement, 2, key)
        guard sqlite3_bind_int64(statement, 3, Int64(row.position)) == SQLITE_OK else { throw ArchiveError("写入归档记录失败。") }
        try bind(statement, 4, row.data)
        try step(statement)
    }

    private func deleteRow(_ collection: String, key: String) throws {
        let statement = try prepare("DELETE FROM records WHERE collection = ? AND key = ?")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, collection)
        try bind(statement, 2, key)
        try step(statement)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ArchiveError("归档记录数据库出错：\(String(cString: sqlite3_errmsg(db)))")
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw ArchiveError("归档记录数据库出错：\(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func step(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ArchiveError("写入归档记录失败，已停止操作。") }
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ text: String) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, index, text, -1, transient) == SQLITE_OK else { throw ArchiveError("写入归档记录失败。") }
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ data: Data) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
        }
        guard result == SQLITE_OK else { throw ArchiveError("写入归档记录失败。") }
    }

    // MARK: Legacy journal

    /// Earlier versions kept the whole state in `archive.json`. It is imported once and kept aside, never deleted.
    private func migrateLegacyJournalIfNeeded() throws {
        guard meta.isEmpty, rows.isEmpty else { return }
        let fd = openat(directoryFD, Self.legacyName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size < 100_000_000 else {
            close(fd)
            throw ArchiveError("旧归档记录不是有效文件或过大，需手动检查。")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data = try handle.readToEnd() ?? Data()
        let state: ArchiveState
        do { state = try JSONDecoder().decode(ArchiveState.self, from: data) }
        catch { throw ArchiveError("旧归档记录无法解析，请检查 \(directory.appendingPathComponent(Self.legacyName).path)。原文件已保留。") }
        try save(state)
        _ = renameat(directoryFD, Self.legacyName, directoryFD, Self.legacyName + ".migrated")
    }
}
