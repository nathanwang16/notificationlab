import Foundation
import CryptoKit
import Darwin

let generatorBundle = "local.notificationlab.generator"
let captureBundle = "local.notificationlab.capture"
let discordBundle = "com.hnc.discord"

func normalizedSources(_ sources: [String]) -> [String] {
    Array(Set(sources.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })).sorted()
}

final class RunLock {
    private var descriptor: Int32 = -1
    init(url: URL) throws {
        descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { Darwin.close(descriptor) }; descriptor = -1
            throw NSError(domain: "CaptureLock", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Another collector already owns this data directory, or its lock cannot be opened"])
        }
    }
    deinit { if descriptor >= 0 { flock(descriptor, LOCK_UN); Darwin.close(descriptor) } }
}

func timestamp(_ date: Date = Date()) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}
func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
func labRoot() -> URL {
    if let path = ProcessInfo.processInfo.environment["NOTIFICATION_LAB_ROOT"] {
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    return Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
}
func jsonData(_ value: Any, pretty: Bool = false) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys])
}
func safeJSON(_ value: Any) -> Any {
    if let data = value as? Data { return ["binary_bytes": data.count, "sha256": digest(data)] }
    if let date = value as? Date { return timestamp(date) }
    if let dict = value as? [String: Any] { return dict.mapValues { safeJSON($0) } }
    if let array = value as? [Any] { return array.map { safeJSON($0) } }
    if value is String || value is NSNumber || value is NSNull { return value }
    return String(describing: value)
}

final class Journal {
    let directory: URL
    private let lock = NSLock()
    private let maxBytes: Int
    private let archives: Int
    private(set) var lastWriteError: String?
    init(directory: URL, maxBytes: Int = 2 * 1024 * 1024, archives: Int = 3) throws {
        self.directory = directory
        self.maxBytes = maxBytes; self.archives = archives
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func append(_ file: String, _ fields: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        var event = fields
        if event["observed_at"] == nil { event["observed_at"] = timestamp() }
        do {
            var data = try jsonData(safeJSON(event))
            data.append(0x0a)
            let path = directory.appendingPathComponent(file)
            let size = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > 0 && size + data.count > maxBytes {
                if archives > 0 {
                    for index in stride(from: archives, through: 1, by: -1) {
                        let destination = directory.appendingPathComponent(file + ".\(index)")
                        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                        let source = index == 1 ? path : directory.appendingPathComponent(file + ".\(index - 1)")
                        if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.moveItem(at: source, to: destination) }
                    }
                } else { try FileManager.default.removeItem(at: path) }
            }
            if !FileManager.default.fileExists(atPath: path.path) {
                guard FileManager.default.createFile(atPath: path.path, contents: nil) else {
                    throw NSError(domain: "Journal", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create journal"])
                }
            }
            let handle = try FileHandle(forWritingTo: path)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            lastWriteError = String(describing: error)
            fputs("Journal error: \(error)\n", stderr)
        }
    }
    func status(_ name: String, _ fields: [String: Any]) {
        do { try jsonData(safeJSON(fields), pretty: true).write(to: directory.appendingPathComponent(name), options: .atomic) }
        catch { lastWriteError = String(describing: error); fputs("Status error: \(error)\n", stderr) }
    }
}

struct DecodedPayload {
    let title: String
    let subtitle: String
    let body: String
    let requestIdentifier: String?
    let raw: [String: Any]
}
func decodePayload(_ data: Data) throws -> DecodedPayload {
    let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    guard let raw = object as? [String: Any], let request = raw["req"] as? [String: Any] else {
        throw NSError(domain: "NotificationPayload", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported notification payload shape: missing req dictionary"])
    }
    func string(_ key: String) -> String { request[key] as? String ?? "" }
    return DecodedPayload(title: string("titl"), subtitle: string("subt"), body: string("body"), requestIdentifier: request["iden"] as? String, raw: raw)
}

// Track identity plus revision. Identical text in different notifications stays distinct.
final class RevisionTracker {
    private var states: [String: String] = [:]
    func classify(id: String, fingerprint: String, seed: Bool = false) -> String? {
        let old = states.updateValue(fingerprint, forKey: id)
        if seed || old == fingerprint { return nil }
        return old == nil ? "posted" : "updated"
    }
    func forget(_ ids: Set<String>) { for id in ids { states.removeValue(forKey: id) } }
}

func runToken(in texts: [String]) -> String? {
    for text in texts {
        if let range = text.range(of: "LAB-[A-Fa-f0-9]{8}-[0-9]{4}", options: .regularExpression) { return String(text[range]) }
    }
    return nil
}

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}
