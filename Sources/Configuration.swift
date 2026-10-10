import Foundation

struct CaptureConfiguration: Codable {
    var sources: [String] = [discordBundle]
    var active = true
    var accessibilityEnabled = true
    var lastCommandID = ""
    static func load(_ url: URL, legacyCommand: URL) throws -> CaptureConfiguration {
        if FileManager.default.fileExists(atPath: url.path) {
            var value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            value.sources = normalizedSources(value.sources)
            return value
        }
        var value = Self()
        // An old command file is not a new request when migrating from the lab build.
        if let data = try? Data(contentsOf: legacyCommand), let command = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { value.lastCommandID = command["id"] as? String ?? "" }
        return value
    }
    func save(_ url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
