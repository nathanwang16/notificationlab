import Foundation
import SQLite3

@main enum ProbeTests {
    static func main() throws {
        if CommandLine.arguments.contains("--scan-worker") {
            let journal = try Journal(directory: URL(fileURLWithPath: argument("--journal")!))
            let store = try CaptureStore(url: URL(fileURLWithPath: argument("--state")!))
            let probe = DatabaseProbe(journal: journal, store: store)
            probe.scan()
            guard probe.lastSuccessfulScan != nil else { fputs("\(probe.state)\n", stderr); exit(1) }
            print(probe.eventCount); return
        }
        var passed = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ description: String) {
            do { guard try condition() else { fputs("FAIL: \(description)\n", stderr); exit(1) } }
            catch { fputs("FAIL: \(description): \(error)\n", stderr); exit(1) }
            passed += 1; print("PASS: \(description)")
        }
        let tracker = RevisionTracker()
        check(tracker.classify(id: "a", fingerprint: "same") == "posted", "first notification is posted")
        check(tracker.classify(id: "b", fingerprint: "same") == "posted", "identical text with different identity is preserved")
        check(tracker.classify(id: "a", fingerprint: "same") == nil, "unchanged observation is not emitted twice")
        check(tracker.classify(id: "a", fingerprint: "changed") == "updated", "changed payload is an update")
        check(tracker.classify(id: "old", fingerprint: "history", seed: true) == nil, "retained history is baseline only")
        check(tracker.classify(id: "old", fingerprint: "new") == "updated", "baseline notification can later update")
        let body = "LAB-ABCDEF12-0001 中文 🧪\n" + String(repeating: "long text ", count: 100)
        let plist: [String: Any] = ["req": ["titl": "Title", "subt": "Channel", "body": body, "iden": "one"]]
        let binary = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let decoded = try decodePayload(binary)
        check(decoded.body == body && decoded.title == "Title" && decoded.subtitle == "Channel", "binary plist retains Unicode, multiline and long text")
        check(decoded.requestIdentifier == "one", "request identifier extracted separately")
        check(runToken(in: [body]) == "LAB-ABCDEF12-0001", "test marker detected")
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/smoke-banner.json")
        let capturedTree = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [String: Any]
        func axNode(_ object: [String: Any]) -> AXNode {
            AXNode(attributes: object["attributes"] as! [String: String], children: (object["children"] as! [[String: Any]]).map(axNode))
        }
        let banner = axNode(capturedTree)
        check(banner.sourceBundle(allowed: [generatorBundle]) == generatorBundle, "recorded live banner identifies sender by app label")
        check(banner.notificationCards(allowed: [generatorBundle]).count == 1, "recorded AX banner is extracted as one card")
        let persistentURL = fixtureURL.deletingLastPathComponent().appendingPathComponent("persistent-alert.json")
        let persistent = axNode(try JSONSerialization.jsonObject(with: Data(contentsOf: persistentURL)) as! [String: Any])
        check(persistent.attributes["AXSubrole"] == "AXNotificationCenterAlert", "recorded persistent alert has a distinct OS subrole")
        check(persistent.notificationCards(allowed: [generatorBundle]).count == 1, "recorded persistent alert is extracted independently of banner subrole")
        check(banner.notificationCards(allowed: ["com.hnc.Discord"]).isEmpty, "Discord-only allowlist excludes sender banner")
        check(banner.field("title") == "NotificationLab Test 1" && banner.field("subtitle") == "Capture test — smoke", "recorded AX title and subtitle fields decoded")
        check(banner.field("body")?.hasPrefix("LAB-AC2A8E22-0001") == true, "recorded AX body is separate from aggregate description")
        let discord = AXNode(attributes: ["AXSubrole": "AXNotificationCenterBanner", "AXDescription": "Discord, Test sender, Test message", "AXIdentifier": "CAFDD230-D5D9-4A7B-B55D-B8AD112EDC56"], children: banner.children)
        check(discord.sourceBundle(allowed: ["com.hnc.Discord"]) == discordBundle, "Discord app label prefix is recognized")
        check(discord.sourceBundle(allowed: [discordBundle]) == discordBundle, "AX source aliases normalize to one Discord identifier")
        let unrelated = AXNode(attributes: ["AXSubrole": "AXNotificationCenterBanner", "AXDescription": "Other app, Discord, Test message"], children: [])
        check(unrelated.notificationCards(allowed: ["com.hnc.Discord"]).isEmpty, "Discord mentioned in another app's message is not a source match")
        do { _ = try decodePayload(Data("invalid".utf8)); check(false, "invalid payload throws") }
        catch { passed += 1; print("PASS: invalid payload throws") }
        let root = URL(fileURLWithPath: CommandLine.arguments.last!)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("fixture.sqlite")
        var writer: OpaquePointer?
        check(sqlite3_open(databaseURL.path, &writer) == SQLITE_OK, "fixture database opens")
        let sql = "CREATE TABLE IF NOT EXISTS app(app_id INTEGER PRIMARY KEY, identifier TEXT); CREATE TABLE IF NOT EXISTS record(rec_id INTEGER PRIMARY KEY, app_id INTEGER, uuid BLOB, data BLOB, delivered_date REAL); INSERT OR IGNORE INTO app VALUES(1,'local.notificationlab.generator');"
        check(sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK, "fixture schema created")
        check(sqlite3_exec(writer, "PRAGMA journal_mode=WAL", nil, nil, nil) == SQLITE_OK, "source fixture uses WAL like a live SQLite writer")
        func insert(_ id: Int, _ payload: Data) throws {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(writer, "INSERT OR REPLACE INTO record VALUES(?,1,?, ?,?)", -1, &statement, nil) == SQLITE_OK else { throw NSError(domain: "test", code: 1) }
            sqlite3_bind_int(statement, 1, Int32(id)); sqlite3_bind_int(statement, 2, Int32(id))
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            _ = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(payload.count), transient) }
            sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970 - 978307200)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw NSError(domain: "test", code: 2) }
        }
        try insert(1, binary)
        let journal = try Journal(directory: root.appendingPathComponent("journal"))
        let store = try CaptureStore(url: root.appendingPathComponent("state/capture.sqlite"))
        let probe = DatabaseProbe(journal: journal, store: store)
        probe.scan()
        check(probe.eventCount == 0, "database probe seeds existing row without capture")
        let openedLog = try String(contentsOf: journal.directory.appendingPathComponent("diagnostics.jsonl"), encoding: .utf8)
        let opened = try openedLog.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }.first { $0["type"] as? String == "opened" }
        check(opened?["read_only"] as? Bool == true, "probe opens the database read-only")
        try insert(2, binary); probe.scan()
        check(probe.eventCount == 1, "database probe captures newly inserted identical-content row")
        probe.scan(); check(probe.eventCount == 1, "database scan does not duplicate unchanged row")
        let changed = try PropertyListSerialization.data(fromPropertyList: ["req": ["titl": "Title", "body": "changed"]], format: .binary, options: 0)
        try insert(2, changed); probe.scan()
        check(probe.eventCount == 2, "database detects revision of existing notification")
        check(sqlite3_exec(writer, "INSERT INTO app VALUES(2,'unrelated.source'); INSERT INTO record SELECT 3,2,uuid,data,delivered_date FROM record WHERE rec_id=2;", nil, nil, nil) == SQLITE_OK, "unrelated source fixture inserted")
        probe.scan(); check(probe.eventCount == 2, "source allowlist excludes unrelated notification content")
        check(sqlite3_exec(writer, "UPDATE app SET identifier='LOCAL.NOTIFICATIONLAB.GENERATOR' WHERE app_id=1", nil, nil, nil) == SQLITE_OK, "source case alias fixture applied")
        probe.scan(); check(probe.eventCount == 2, "SQL source matching and notification identity are case-insensitive")
        probe.close()
        try insert(4, binary)
        func workerEvents() throws -> Int {
            let process = Process(); let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--scan-worker", "--db", databaseURL.path, "--state", store.url.path, "--journal", root.appendingPathComponent("worker-" + UUID().uuidString).path]
            process.standardOutput = pipe; try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0, let count = Int(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { throw NSError(domain: "WorkerTest", code: 1) }
            return count
        }
        check(try workerEvents() == 1, "fresh process recovers a message delivered while the previous reader was stopped")
        check(try workerEvents() == 0, "second process restart does not replay captured messages")
        check(try store.counts()["retained_events"] as? Int == 3, "messages survive process exit in a durable feed")
        probe.scan(); check(probe.eventCount == 2, "original process sees worker checkpoint and does not duplicate recovery")

        let replacementURL = root.appendingPathComponent("replacement.sqlite")
        var replacement: OpaquePointer?
        check(sqlite3_open(replacementURL.path, &replacement) == SQLITE_OK, "replacement fixture opens")
        let backup = sqlite3_backup_init(replacement, "main", writer, "main")!
        check(sqlite3_backup_step(backup, -1) == SQLITE_DONE && sqlite3_backup_finish(backup) == SQLITE_OK, "replacement database retains existing UUIDs and timestamps")
        sqlite3_close(replacement); sqlite3_close(writer); writer = nil
        check(rename(replacementURL.path, databaseURL.path) == 0, "source database is atomically replaced while reader has it open")
        probe.scan(); check(probe.eventCount == 2, "reader reconnects after file replacement without replaying retained UUIDs")
        check(sqlite3_open(databaseURL.path, &writer) == SQLITE_OK, "writer reconnects after replacement")
        try insert(5, changed); probe.scan()
        check(probe.eventCount == 3, "reader captures new content after database replacement")

        var stateWriter: OpaquePointer?
        check(sqlite3_open(store.url.path, &stateWriter) == SQLITE_OK, "fault-injection connection opens only the disposable capture state")
        check(sqlite3_exec(stateWriter, "CREATE TRIGGER fail_capture BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT,'fixture write failure'); END;", nil, nil, nil) == SQLITE_OK, "durable write failure injected")
        try insert(6, changed); probe.scan()
        check(probe.eventCount == 3 && probe.state.hasPrefix("Capture state write failed"), "failed commit is reported and does not emit a message")
        check(sqlite3_exec(stateWriter, "DROP TRIGGER fail_capture", nil, nil, nil) == SQLITE_OK, "durable write fault removed")
        probe.scan(); check(probe.eventCount == 4, "next scan recovers the message after a failed commit")
        probe.scan(); check(probe.eventCount == 4, "recovered commit is not duplicated")
        try insert(7, Data("malformed".utf8)); probe.scan()
        check(probe.malformedCount == 1 && probe.eventCount == 4, "malformed source records report degraded capture without advancing identity")
        try insert(7, binary); probe.scan()
        check(probe.malformedCount == 0 && probe.eventCount == 5, "repaired malformed notification remains retrievable")
        sqlite3_close(stateWriter); probe.close(); sqlite3_close(writer)

        let limitedStore = try CaptureStore(url: root.appendingPathComponent("limited.sqlite"), eventLimit: 2)
        _ = try limitedStore.capture([], sources: [generatorBundle])
        let samples = (1...5).map { DatabaseRecord(recordID: Int64($0), source: generatorBundle, uuid: String($0), data: binary, delivered: nil, databaseIdentity: "fixture") }
        check(try limitedStore.capture(samples, sources: [generatorBundle]).events.count == 5, "retention does not suppress newly retrieved messages")
        check(try limitedStore.counts()["retained_events"] as? Int == 2, "durable payload retention is bounded")
        check(try limitedStore.capture(samples, sources: [generatorBundle]).events.isEmpty, "deduplication survives payload retention cleanup")
        check(try limitedStore.counts()["last_sequence"] as? Int64 == 5, "feed sequence stays monotonic when old payloads expire")
        let configURL = root.appendingPathComponent("configuration.json")
        var config = CaptureConfiguration(); config.sources = [discordBundle]; config.active = false; config.lastCommandID = "already-consumed"
        try config.save(configURL)
        let loaded = try CaptureConfiguration.load(configURL, legacyCommand: root.appendingPathComponent("missing-command.json"))
        check(!loaded.active && loaded.sources == [discordBundle] && loaded.lastCommandID == "already-consumed", "stop state, source filter and consumed command survive relaunch")
        let rotating = try Journal(directory: root.appendingPathComponent("rotating"), maxBytes: 250, archives: 2)
        for n in 1...12 { rotating.append("events.jsonl", ["n": n, "body": String(repeating: "x", count: 80)]) }
        let files = try FileManager.default.contentsOfDirectory(at: rotating.directory, includingPropertiesForKeys: nil)
        check(files.count == 3 && rotating.lastWriteError == nil, "journal rotation retains only active file and configured archives")
        let rotatedRows = try files.flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] } }
        check(rotatedRows.contains { $0["n"] as? Int == 12 }, "rotation keeps the newest complete JSON record")
        let lockURL = root.appendingPathComponent("singleton.lock")
        let firstLock = try RunLock(url: lockURL)
        do { _ = try RunLock(url: lockURL); check(false, "second collector cannot own the same directory") }
        catch { check(true, "second collector cannot own the same directory") }
        withExtendedLifetime(firstLock) {}
        print("\(passed) checks passed")
    }
}
