import Foundation
import SQLite3

final class DatabaseProbe {
    let journal: Journal
    let store: CaptureStore
    var sourceBundles: [String] = [generatorBundle]
    private var database: OpaquePointer?
    private var fileIdentity: String?
    private var lastError = ""
    private var decodeErrors: Set<String> = []
    private(set) var state = "not started"
    private(set) var eventCount = 0
    private(set) var malformedCount = 0
    private(set) var lastSuccessfulScan: Date?
    private var rowID = "r.rec_id"
    private var hasUUID = true
    private var hasDate = true
    private var path: String {
        if let supplied = argument("--db") { return supplied }
        return NSHomeDirectory() + "/Library/Group Containers/group.com.apple.usernoted/db2/db"
    }
    init(journal: Journal, store: CaptureStore) { self.journal = journal; self.store = store }
    deinit { close() }
    func close() {
        if let database { sqlite3_close(database) }
        database = nil; fileIdentity = nil
    }
    private func error(_ message: String) {
        state = message
        if lastError != message {
            journal.append("diagnostics.jsonl", ["backend": "database", "type": "error", "message": message, "path": path])
            lastError = message
        }
    }
    private func columns(_ table: String) -> Set<String> {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return [] }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 1) { names.insert(String(cString: text)) }
        }
        return names
    }
    private func openIfNeeded() -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let identity = "\(attrs?[.systemNumber] ?? "?"):\(attrs?[.systemFileNumber] ?? "?")"
        if database != nil && fileIdentity == identity { return true }
        close()
        var db: OpaquePointer?
        let result = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite open failed"
            if let db { sqlite3_close(db) }
            error("Read-only open failed (\(result)): \(message)")
            return false
        }
        database = db; fileIdentity = identity
        sqlite3_busy_timeout(db, 200)
        let record = columns("record"), app = columns("app")
        guard record.isSuperset(of: ["app_id", "data"]), app.isSuperset(of: ["app_id", "identifier"]) else {
            error("Unsupported database schema")
            close(); return false
        }
        rowID = record.contains("rec_id") ? "r.rec_id" : "r.rowid"
        hasUUID = record.contains("uuid"); hasDate = record.contains("delivered_date")
        journal.append("diagnostics.jsonl", ["backend": "database", "type": "opened", "read_only": sqlite3_db_readonly(db, "main") == 1, "record_columns": record.sorted(), "app_columns": app.sorted(), "path": path])
        state = "connected read-only"; lastError = ""
        return true
    }
    func scan() {
        guard !sourceBundles.isEmpty, openIfNeeded() else { return }
        let selected = normalizedSources(sourceBundles)
        let placeholders = Array(repeating: "?", count: selected.count).joined(separator: ",")
        let uuid = hasUUID ? "hex(r.uuid)" : "''"
        let date = hasDate ? "r.delivered_date" : "NULL"
        let sql = "SELECT \(rowID), a.identifier, \(uuid), r.data, \(date) FROM record r JOIN app a ON r.app_id=a.app_id WHERE lower(a.identifier) IN (\(placeholders)) ORDER BY \(rowID)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            error(String(cString: sqlite3_errmsg(database))); return
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, bundle) in selected.enumerated() {
            _ = bundle.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, transient) }
        }
        var result = sqlite3_step(statement)
        var records: [DatabaseRecord] = []
        while result == SQLITE_ROW {
            let recordID = sqlite3_column_int64(statement, 0)
            let source = String(cString: sqlite3_column_text(statement, 1))
            let uuid = String(cString: sqlite3_column_text(statement, 2))
            let size = Int(sqlite3_column_bytes(statement, 3))
            let data = sqlite3_column_blob(statement, 3).map { Data(bytes: $0, count: size) } ?? Data()
            let delivered: Double? = sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 4)
            records.append(DatabaseRecord(recordID: recordID, source: source, uuid: uuid, data: data, delivered: delivered, databaseIdentity: fileIdentity ?? "unknown"))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { error("Query failed: " + String(cString: sqlite3_errmsg(database))); return }
        // Only a complete, successful source snapshot can advance durable state.
        do {
            let batch = try store.capture(records, sources: selected)
            if !batch.seededSources.isEmpty {
                journal.append("diagnostics.jsonl", ["backend": "database", "type": "baseline", "sources": batch.seededSources, "matching_retained_records": records.count])
            }
            for event in batch.events { journal.append("database.jsonl", event); eventCount += 1 }
            malformedCount = batch.malformed.count
            for issue in batch.malformed where decodeErrors.insert(issue["fingerprint"] as? String ?? "").inserted {
                journal.append("diagnostics.jsonl", issue.merging(["backend": "database", "type": "decode_error"]) { _, new in new })
            }
            lastSuccessfulScan = Date(); lastError = ""
            state = "connected read-only; \(eventCount) events" + (malformedCount == 0 ? "" : "; \(malformedCount) undecodable records")
        } catch {
            self.error("Capture state write failed: \(error)")
        }
    }
    func sourceInventory() -> [[String: Any]] {
        guard openIfNeeded() else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT identifier FROM app ORDER BY identifier", -1, &statement, nil) == SQLITE_OK else { return [] }
        var apps: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { apps.append(["bundle": String(cString: text)]) }
        }
        return apps
    }
}
