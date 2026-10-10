import AppKit
import ApplicationServices
import Foundation

final class CaptureDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var sources: NSTextField!
    var statusLabel: NSTextField!
    var journal: Journal!
    var store: CaptureStore!
    var runLock: RunLock?
    var configuration = CaptureConfiguration()
    var configurationError: String?
    var statusItem: NSStatusItem?
    var ax: AccessibilityProbe!
    var db: DatabaseProbe!
    var timer: Timer?
    var active = false
    var ticks = 0
    var sourceBundles: [String] = [discordBundle]
    var configurationURL: URL { labRoot().appendingPathComponent("state/configuration.json") }
    var background: Bool { CommandLine.arguments.contains("--background") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let stateDirectory = labRoot().appendingPathComponent("state")
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
            do { runLock = try RunLock(url: stateDirectory.appendingPathComponent("capture.lock")) }
            catch { if (error as NSError).code == EWOULDBLOCK { fputs("\(error.localizedDescription)\n", stderr); exit(0) }; throw error }
            configuration = try CaptureConfiguration.load(configurationURL, legacyCommand: labRoot().appendingPathComponent("capture-command.json"))
            if let supplied = argument("--sources") { configuration.sources = normalizedSources(supplied.components(separatedBy: ",")) }
            if CommandLine.arguments.contains("--no-ax") { configuration.accessibilityEnabled = false }
            if CommandLine.arguments.contains("--enable-ax") { configuration.accessibilityEnabled = true }
            guard !configuration.sources.isEmpty else { throw NSError(domain: "CaptureConfiguration", code: 1, userInfo: [NSLocalizedDescriptionKey: "At least one notification source is required"]) }
            try configuration.save(configurationURL)
            store = try CaptureStore(url: stateDirectory.appendingPathComponent("capture.sqlite"))
            let session = timestamp().replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(8)
            journal = try Journal(directory: labRoot().appendingPathComponent("runs/" + session))
            try jsonData(["run_directory": journal.directory.path, "capture_app": Bundle.main.bundleURL.path], pretty: true).write(to: labRoot().appendingPathComponent("capture-latest.json"), options: .atomic)
            pruneSessions()
        } catch {
            try? jsonData(["updated_at": timestamp(), "message": String(describing: error)], pretty: true).write(to: labRoot().appendingPathComponent("startup-error.json"), options: .atomic)
            fputs("Cannot start capture: \(error)\n", stderr); exit(1)
        }
        makeWindow()
        journal.append("diagnostics.jsonl", ["type": "environment", "os": ProcessInfo.processInfo.operatingSystemVersionString, "pid": ProcessInfo.processInfo.processIdentifier, "bundle": Bundle.main.bundleIdentifier ?? "", "app_path": Bundle.main.bundleURL.path, "accessibility_trusted": AXIsProcessTrusted()])
        configureProbes()
        active = configuration.active
        if active { db.scan(); if configuration.accessibilityEnabled { ax.scan() } }
        updateStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        if background {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem?.button?.title = "NL"
            let menu = NSMenu()
            let show = NSMenuItem(title: "NotificationLab status", action: #selector(showWindow(_:)), keyEquivalent: ""); show.target = self; menu.addItem(show)
            menu.addItem(withTitle: "Quit NotificationLab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem?.menu = menu
        } else { NSApp.activate(ignoringOtherApps: true) }
    }
    func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded; return button
    }
    func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 450), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "NotificationLab Capture"
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "NotificationLab — capture probes")
        title.font = .boldSystemFont(ofSize: 21)
        stack.addArrangedSubview(title)
        let detail = NSTextField(wrappingLabelWithString: "Discord notifications are saved to a durable database feed. The first successful scan of each new source seeds existing history; subsequent starts resume retained messages. Accessibility provides separate faster observations.")
        detail.preferredMaxLayoutWidth = 790; stack.addArrangedSubview(detail)
        stack.addArrangedSubview(NSTextField(labelWithString: "Source bundle IDs (comma-separated; change and click Start):"))
        sources = NSTextField(string: configuration.sources.joined(separator: ","))
        sources.widthAnchor.constraint(equalToConstant: 790).isActive = true
        stack.addArrangedSubview(sources)
        let controls = NSStackView(views: [button("Start / resume", #selector(start(_:))), button("Stop", #selector(stop(_:))), button("Request Accessibility", #selector(requestAccessibility(_:))), button("Open logs", #selector(openLogs(_:)))])
        controls.spacing = 8; stack.addArrangedSubview(controls)
        let settings = NSStackView(views: [button("Accessibility settings", #selector(accessibilitySettings(_:))), button("Full Disk Access settings", #selector(diskSettings(_:))), button("List database app IDs", #selector(inventory(_:)))])
        settings.spacing = 8; stack.addArrangedSubview(settings)
        statusLabel = NSTextField(wrappingLabelWithString: "Starting…")
        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.preferredMaxLayoutWidth = 790; stack.addArrangedSubview(statusLabel)
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24), stack.trailingAnchor.constraint(lessThanOrEqualTo: window.contentView!.trailingAnchor, constant: -24)])
        window.center(); if !background { window.makeKeyAndOrderFront(nil) }
    }
    func saveConfiguration() {
        do { try configuration.save(configurationURL); configurationError = nil }
        catch { configurationError = String(describing: error); journal.append("diagnostics.jsonl", ["type": "configuration_write_error", "message": configurationError!]) }
    }
    func configureProbes() {
        ax?.stop(); db?.close()
        sourceBundles = normalizedSources(sources.stringValue.components(separatedBy: ","))
        ax = AccessibilityProbe(journal: journal); ax.sourceBundles = sourceBundles
        db = DatabaseProbe(journal: journal, store: store); db.sourceBundles = sourceBundles
    }
    @objc func showWindow(_ sender: Any?) { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func start(_ sender: Any?) {
        let selected = normalizedSources(sources.stringValue.components(separatedBy: ","))
        guard !selected.isEmpty else { journal.append("diagnostics.jsonl", ["type": "invalid_sources", "message": "At least one source is required"]); return }
        configureProbes()
        active = true
        configuration.active = true; configuration.sources = sourceBundles; saveConfiguration()
        journal.append("diagnostics.jsonl", ["type": "started", "source_bundles": sourceBundles, "poll_interval_seconds": 0.5, "resume": true])
        db.scan(); if configuration.accessibilityEnabled { ax.scan() }; updateStatus()
    }
    @objc func stop(_ sender: Any?) {
        active = false; configuration.active = false; saveConfiguration(); ax.stop(); db.close()
        journal.append("diagnostics.jsonl", ["type": "stopped"]); updateStatus()
    }
    @objc func requestAccessibility(_ sender: Any?) {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    @objc func accessibilitySettings(_ sender: Any?) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    @objc func diskSettings(_ sender: Any?) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
    @objc func openLogs(_ sender: Any?) { NSWorkspace.shared.open(journal.directory) }
    @objc func inventory(_ sender: Any?) {
        journal.status("database-apps.json", ["apps": db.sourceInventory(), "note": "Bundle IDs only; no notification content"])
    }
    func tick() {
        consumeCommand()
        if active { db.scan(); if configuration.accessibilityEnabled { ax.scan() } }
        ticks += 1
        if ticks % 4 == 0 { updateStatus() }
    }
    func consumeCommand() {
        let url = labRoot().appendingPathComponent("capture-command.json")
        guard let data = try? Data(contentsOf: url), let command = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let id = command["id"] as? String, id != configuration.lastCommandID else { return }
        configuration.lastCommandID = id
        var accepted = true
        switch command["action"] as? String {
        case "start":
            if let value = command["sources"] as? String { sources.stringValue = value }
            if normalizedSources(sources.stringValue.components(separatedBy: ",")).isEmpty { accepted = false }
            else { start(nil) }
        case "stop": stop(nil)
        case "inventory": inventory(nil)
        case "request_accessibility": requestAccessibility(nil)
        case "diagnose": updateStatus()
        case "enable_ax": configuration.accessibilityEnabled = true
        case "disable_ax": configuration.accessibilityEnabled = false; ax.stop()
        default: accepted = false; journal.append("diagnostics.jsonl", ["type": "invalid_command", "id": id])
        }
        saveConfiguration()
        do { try jsonData(["id": id, "accepted": accepted && configurationError == nil, "action": command["action"] ?? "", "acknowledged_at": timestamp()], pretty: true).write(to: labRoot().appendingPathComponent("capture-command-ack.json"), options: .atomic) }
        catch { configurationError = "Command acknowledgement write failed: \(error)" }
    }
    func updateStatus() {
        let apps = NSWorkspace.shared.runningApplications.filter {
            let name = $0.localizedName ?? ""
            return name.contains("NotificationCenter") || name.contains("Discord") || name.contains("Chrome") || name.contains("Safari")
        }.map { ["name": $0.localizedName ?? "", "bundle": $0.bundleIdentifier ?? "", "pid": String($0.processIdentifier)] }
        let scanAge = db.lastSuccessfulScan.map { Date().timeIntervalSince($0) }
        var status: [String: Any] = ["updated_at": timestamp(), "active": active, "healthy": active && db.state.hasPrefix("connected read-only") && (scanAge ?? 999) < 5 && db.malformedCount == 0 && journal.lastWriteError == nil && configurationError == nil, "primary_backend": "database", "accessibility_enabled": configuration.accessibilityEnabled, "accessibility_trusted": AXIsProcessTrusted(), "accessibility": configuration.accessibilityEnabled ? ax.state : "disabled (optional)", "database": db.state, "accessibility_observations": ax.eventCount, "database_events": db.eventCount, "sources": sourceBundles, "relevant_running_apps": apps, "run_directory": journal.directory.path, "pid": ProcessInfo.processInfo.processIdentifier]
        if let date = db.lastSuccessfulScan { status["last_successful_scan_at"] = timestamp(date) }
        if let error = journal.lastWriteError ?? configurationError { status["write_error"] = error }
        do { status["durable_feed"] = try store.counts() }
        catch { status["healthy"] = false; status["write_error"] = String(describing: error) }
        journal.status("capture-status.json", status)
        do { try jsonData(status, pretty: true).write(to: labRoot().appendingPathComponent("capture-health.json"), options: .atomic) }
        catch { configurationError = "Heartbeat write failed: \(error)" }
        statusLabel.stringValue = "Running: \(active)\nAccessibility: \(ax.state)\nDatabase: \(db.state)\nLog directory: \(journal.directory.path)"
    }
    func pruneSessions() {
        let parent = journal.directory.deletingLastPathComponent()
        guard let urls = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        let sessions = urls.filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true && url.lastPathComponent.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}\\.[0-9]{3}Z-[A-F0-9]{8}$", options: .regularExpression) != nil
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in sessions.prefix(max(0, sessions.count - 10)) where url != journal.directory {
            do { try FileManager.default.removeItem(at: url) }
            catch { journal.append("diagnostics.jsonl", ["type": "retention_error", "path": url.path, "message": String(describing: error)]) }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate(); ax?.stop(); db?.close(); journal?.append("diagnostics.jsonl", ["type": "terminated"]) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main enum CaptureMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(CommandLine.arguments.contains("--background") ? .accessory : .regular)
        let delegate = CaptureDelegate(); app.delegate = delegate
        let menu = NSMenu(); let item = NSMenuItem(); let submenu = NSMenu()
        submenu.addItem(withTitle: "Quit NotificationLab Capture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu; menu.addItem(item); app.mainMenu = menu
        withExtendedLifetime(delegate) { app.run() }
    }
}
