import Foundation
import SQLite3

struct DatabaseRecord {
    let recordID: Int64
    let source: String
    let uuid: String
    let data: Data
    let delivered: Double?
    let databaseIdentity: String
    var fingerprint: String { digest(data) + ":" + String(delivered ?? 0) }
}

struct CaptureBatch {
    var events: [[String: Any]] = []
    var seededSources: [String] = []
    var malformed: [[String: Any]] = []
}

// This is our own database. The macOS source database is always opened read-only.
// A single commit records both the observed revision and the retrievable event.
final class CaptureStore {
    let url: URL
    private var database: OpaquePointer?
    private let eventLimit: Int
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL, eventLimit: Int = 10_000) throws {
        self.url = url; self.eventLimit = max(1, eventLimit)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let failure = sqliteError(); if let database { sqlite3_close(database) }; database = nil; throw failure
        }
        do {
            sqlite3_busy_timeout(database, 1_000)
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA wal_autocheckpoint=100; PRAGMA journal_size_limit=1048576;")
            let version = try scalar("PRAGMA user_version") ?? "0"
            guard ["0", "1"].contains(version) else { throw NSError(domain: "CaptureStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsupported capture state version: \(version)"]) }
            try execute("CREATE TABLE IF NOT EXISTS baselines(source TEXT PRIMARY KEY, initialized_at TEXT NOT NULL); CREATE TABLE IF NOT EXISTS seen(notification_id TEXT PRIMARY KEY, source TEXT NOT NULL, fingerprint TEXT NOT NULL); CREATE TABLE IF NOT EXISTS events(sequence INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT UNIQUE NOT NULL, payload TEXT NOT NULL); PRAGMA user_version=1;")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { sqlite3_close(database); database = nil; throw error }
    }
    deinit { if let database { sqlite3_close(database) } }
    private func sqliteError() -> NSError {
        NSError(domain: "CaptureStore", code: Int(sqlite3_errcode(database)), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw sqliteError() }
    }
    private func prepared(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError() }
        for (index, value) in values.enumerated() {
            let result = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, transient) }
            if result != SQLITE_OK { sqlite3_finalize(statement); throw sqliteError() }
        }
        return statement
    }
    private func scalar(_ sql: String, _ values: [String] = []) throws -> String? {
        let statement = try prepared(sql, values); defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw sqliteError() }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }
    private func write(_ sql: String, _ values: [String]) throws {
        let statement = try prepared(sql, values); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
    }
    func capture(_ records: [DatabaseRecord], sources: [String]) throws -> CaptureBatch {
        try execute("BEGIN IMMEDIATE")
        do {
            var batch = CaptureBatch()
            let selected = normalizedSources(sources)
            var newSources: Set<String> = []
            for source in selected where try scalar("SELECT source FROM baselines WHERE source=?", [source]) == nil { newSources.insert(source) }
            for record in records {
                let source = record.source.lowercased()
                guard selected.contains(source) else { continue }
                // UUIDs are preferred. Older schemas may offer only request ID/row position.
                let provisionalID = source + ":row:" + record.databaseIdentity + ":" + String(record.recordID)
                let initialID = record.uuid.isEmpty ? provisionalID : source + ":" + record.uuid.uppercased()
                if !record.uuid.isEmpty, try scalar("SELECT fingerprint FROM seen WHERE notification_id=?", [initialID]) == record.fingerprint { continue }
                let payload: DecodedPayload
                do { payload = try decodePayload(record.data) }
                catch {
                    batch.malformed.append(["record_id": record.recordID, "fingerprint": record.fingerprint, "bytes": record.data.count, "message": String(describing: error)])
                    continue
                }
                let id = record.uuid.isEmpty ? payload.requestIdentifier.map { source + ":request:" + $0 } ?? provisionalID : initialID
                let previous = try scalar("SELECT fingerprint FROM seen WHERE notification_id=?", [id])
                guard previous != record.fingerprint else { continue }
                if !newSources.contains(source) {
                    let eventID = UUID().uuidString
                    var fields: [String: Any] = ["event_id": eventID, "backend": "database", "kind": previous == nil ? "posted" : "updated", "observed_at": timestamp(), "source_bundle": source, "source_bundle_observed": record.source, "record_id": record.recordID, "notification_id": id, "identity_basis": record.uuid.isEmpty ? (payload.requestIdentifier == nil ? "database row; provisional" : "request identifier") : "database UUID", "title": payload.title, "subtitle": payload.subtitle, "body": payload.body, "raw": safeJSON(payload.raw)]
                    if let requestID = payload.requestIdentifier { fields["request_identifier"] = requestID }
                    if let delivered = record.delivered { fields["delivered_at"] = timestamp(Date(timeIntervalSince1970: delivered + 978307200)) }
                    if let token = runToken(in: [payload.title, payload.subtitle, payload.body]) { fields["test_token"] = token }
                    try write("INSERT INTO events(event_id,payload) VALUES(?, '{}')", [eventID])
                    let sequence = sqlite3_last_insert_rowid(database)
                    fields["sequence"] = sequence
                    try write("UPDATE events SET payload=? WHERE sequence=?", [String(decoding: try jsonData(fields), as: UTF8.self), String(sequence)])
                    batch.events.append(fields)
                }
                try write("INSERT OR REPLACE INTO seen(notification_id,source,fingerprint) VALUES(?,?,?)", [id, source, record.fingerprint])
            }
            for source in newSources {
                try write("INSERT INTO baselines(source,initialized_at) VALUES(?,?)", [source, timestamp()])
            }
            if !batch.events.isEmpty { try execute("DELETE FROM events WHERE sequence NOT IN (SELECT sequence FROM events ORDER BY sequence DESC LIMIT \(eventLimit))") }
            try execute("COMMIT")
            batch.seededSources = newSources.sorted()
            return batch
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func counts() throws -> [String: Any] {
        ["retained_events": Int(try scalar("SELECT count(*) FROM events") ?? "0") ?? 0,
         "last_sequence": Int64(try scalar("SELECT seq FROM sqlite_sequence WHERE name='events'") ?? "0") ?? 0,
         "seen_identities": Int(try scalar("SELECT count(*) FROM seen") ?? "0") ?? 0,
         "event_retention_limit": eventLimit, "path": url.path]
    }
}
