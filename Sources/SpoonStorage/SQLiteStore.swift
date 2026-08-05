import Foundation
import SQLite3
import SpoonDomain

public actor SQLiteStore {
    nonisolated(unsafe) private var database: OpaquePointer?
    public let url: URL

    public init(url: URL? = nil) throws {
        let resolvedURL: URL
        if let url {
            resolvedURL = url
        } else {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Spoon", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            resolvedURL = support.appendingPathComponent("Spoon.sqlite")
        }
        self.url = resolvedURL

        var handle: OpaquePointer?
        let status = sqlite3_open_v2(
            resolvedURL.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, let handle else {
            let message = handle.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "Unable to open SQLite database"
            if let handle { sqlite3_close(handle) }
            throw SQLiteStoreError(message)
        }
        database = handle

        try Self.execute(handle, sql: "PRAGMA journal_mode=WAL;")
        try Self.execute(handle, sql: "PRAGMA foreign_keys=ON;")
        try Self.execute(handle, sql: "PRAGMA busy_timeout=5000;")
        try Self.migrate(handle)
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    public func loadProjects() throws -> [ProjectRecord] {
        try queryRecords(
            sql: "SELECT record FROM projects ORDER BY is_favorite DESC, last_opened_at DESC;",
            decode: ProjectRecord.self
        )
    }

    public func saveProject(_ project: ProjectRecord) throws {
        let data = try Self.encoder.encode(project)
        try execute(
            sql: """
            INSERT INTO projects (id, record, is_favorite, last_opened_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                record = excluded.record,
                is_favorite = excluded.is_favorite,
                last_opened_at = excluded.last_opened_at;
            """,
            bindings: [.text(project.id.uuidString), .blob(data), .integer(project.isFavorite ? 1 : 0), .double(project.lastOpenedAt.timeIntervalSince1970)]
        )
    }

    public func removeProject(id: UUID) throws {
        try execute(sql: "DELETE FROM projects WHERE id = ?;", bindings: [.text(id.uuidString)])
        try execute(sql: "DELETE FROM commit_drafts WHERE project_id = ?;", bindings: [.text(id.uuidString)])
    }

    public func loadGroups() throws -> [ProjectGroup] {
        try queryRecords(sql: "SELECT record FROM project_groups ORDER BY sort_index, name;", decode: ProjectGroup.self)
    }

    public func saveGroup(_ group: ProjectGroup) throws {
        let data = try Self.encoder.encode(group)
        try execute(
            sql: """
            INSERT INTO project_groups (id, record, sort_index)
            VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET record = excluded.record, sort_index = excluded.sort_index;
            """,
            bindings: [.text(group.id.uuidString), .blob(data), .integer(Int64(group.sortIndex))]
        )
    }

    public func loadDraft(projectID: UUID) throws -> CommitDraft? {
        try queryRecords(
            sql: "SELECT record FROM commit_drafts WHERE project_id = ? LIMIT 1;",
            bindings: [.text(projectID.uuidString)],
            decode: CommitDraft.self
        ).first
    }

    public func saveDraft(_ draft: CommitDraft) throws {
        let data = try Self.encoder.encode(draft)
        try execute(
            sql: """
            INSERT INTO commit_drafts (project_id, record, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(project_id) DO UPDATE SET record = excluded.record, updated_at = excluded.updated_at;
            """,
            bindings: [.text(draft.projectID.uuidString), .blob(data), .double(draft.updatedAt.timeIntervalSince1970)]
        )
    }

    public func loadTasks(limit: Int = 200) throws -> [TaskRecord] {
        try queryRecords(
            sql: "SELECT record FROM tasks ORDER BY created_at DESC LIMIT ?;",
            bindings: [.integer(Int64(limit))],
            decode: TaskRecord.self
        )
    }

    public func saveTask(_ task: TaskRecord) throws {
        let data = try Self.encoder.encode(task)
        try execute(
            sql: """
            INSERT INTO tasks (id, project_id, state, created_at, record)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET state = excluded.state, record = excluded.record;
            """,
            bindings: [
                .text(task.id.uuidString),
                task.projectID.map { .text($0.uuidString) } ?? .null,
                .text(task.state.rawValue),
                .double(task.createdAt.timeIntervalSince1970),
                .blob(data)
            ]
        )
    }

    public func pruneTasks(keeping maximum: Int = 500) throws {
        try execute(
            sql: """
            DELETE FROM tasks WHERE id NOT IN (
                SELECT id FROM tasks ORDER BY created_at DESC LIMIT ?
            );
            """,
            bindings: [.integer(Int64(maximum))]
        )
    }

    public func setUIState<Value: Encodable & Sendable>(_ value: Value, key: String) throws {
        let data = try Self.encoder.encode(value)
        try execute(
            sql: "INSERT INTO ui_state (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
            bindings: [.text(key), .blob(data)]
        )
    }

    public func uiState<Value: Decodable & Sendable>(_ type: Value.Type, key: String) throws -> Value? {
        try queryRecords(
            sql: "SELECT value FROM ui_state WHERE key = ? LIMIT 1;",
            bindings: [.text(key)],
            decode: type
        ).first
    }

    public func clearCache() throws {
        try execute(sql: "DELETE FROM repository_cache;")
        try execute(sql: "DELETE FROM history_cache;")
    }

    private func execute(sql: String, bindings: [SQLiteBinding] = []) throws {
        guard let database else { throw SQLiteStoreError("Database is closed") }
        try Self.execute(database, sql: sql, bindings: bindings)
    }

    private func queryRecords<Value: Decodable & Sendable>(
        sql: String,
        bindings: [SQLiteBinding] = [],
        decode: Value.Type
    ) throws -> [Value] {
        guard let database else { throw SQLiteStoreError("Database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteStoreError(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        try Self.bind(bindings, to: statement)

        var values: [Value] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw SQLiteStoreError(String(cString: sqlite3_errmsg(database))) }
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 0))
            let data = Data(bytes: bytes, count: count)
            values.append(try Self.decoder.decode(Value.self, from: data))
        }
        return values
    }

    private static func migrate(_ database: OpaquePointer) throws {
        try execute(database, sql: """
        CREATE TABLE IF NOT EXISTS schema_version (
            version INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS projects (
            id TEXT PRIMARY KEY,
            record BLOB NOT NULL,
            is_favorite INTEGER NOT NULL DEFAULT 0,
            last_opened_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS project_groups (
            id TEXT PRIMARY KEY,
            record BLOB NOT NULL,
            sort_index INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS commit_drafts (
            project_id TEXT PRIMARY KEY,
            record BLOB NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS tasks (
            id TEXT PRIMARY KEY,
            project_id TEXT,
            state TEXT NOT NULL,
            created_at REAL NOT NULL,
            record BLOB NOT NULL
        );
        CREATE TABLE IF NOT EXISTS ui_state (
            key TEXT PRIMARY KEY,
            value BLOB NOT NULL
        );
        CREATE TABLE IF NOT EXISTS repository_cache (
            cache_key TEXT PRIMARY KEY,
            value BLOB NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS history_cache (
            cache_key TEXT PRIMARY KEY,
            value BLOB NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS tasks_created_at ON tasks(created_at DESC);
        """)
    }

    private static func execute(_ database: OpaquePointer, sql: String, bindings: [SQLiteBinding] = []) throws {
        if bindings.isEmpty {
            var errorMessage: UnsafeMutablePointer<CChar>?
            let status = sqlite3_exec(database, sql, nil, nil, &errorMessage)
            if status != SQLITE_OK {
                let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
                sqlite3_free(errorMessage)
                throw SQLiteStoreError(message)
            }
            return
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteStoreError(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw SQLiteStoreError(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func bind(_ values: [SQLiteBinding], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .null:
                status = sqlite3_bind_null(statement, index)
            case .integer(let value):
                status = sqlite3_bind_int64(statement, index, value)
            case .double(let value):
                status = sqlite3_bind_double(statement, index, value)
            case .text(let value):
                status = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            case .blob(let value):
                status = value.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
                }
            }
            guard status == SQLITE_OK else { throw SQLiteStoreError("Unable to bind SQLite value at index \(index)") }
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

private enum SQLiteBinding: Sendable {
    case null
    case integer(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct SQLiteStoreError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
