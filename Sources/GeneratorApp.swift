import AppKit
import UserNotifications
import Foundation

final class GeneratorDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: NSWindow!
    var statusLabel: NSTextField!
    var journal: Journal!
    var pollTimer: Timer?
    var sendTimer: Timer?
    var lastCommandID = ""
    var authorized = false
    var running = false
    var remaining = 0
    var index = 0
    var prefix = ""
    var mode = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { journal = try Journal(directory: labRoot().appendingPathComponent("generator")) }
        catch { fputs("Generator journal error: \(error)\n", stderr); NSApp.terminate(nil); return }
        UNUserNotificationCenter.current().delegate = self
        makeWindow()
        requestPermission(nil)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.consumeCommand() }
        RunLoop.main.add(pollTimer!, forMode: .common)
        NSApp.activate(ignoringOtherApps: true)
    }
    func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded; return button
    }
    func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 310), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "NotificationLab Sender"
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "NotificationLab — synthetic sender"); title.font = .boldSystemFont(ofSize: 21); stack.addArrangedSubview(title)
        let detail = NSTextField(wrappingLabelWithString: "Posts local test notifications only. Every request has a unique ID and expected text logged on disk. Start the capture app first. The permission prompt must be allowed before tests can run.")
        detail.preferredMaxLayoutWidth = 720; stack.addArrangedSubview(detail)
        stack.addArrangedSubview(NSStackView(views: [button("Request permission", #selector(requestPermission(_:))), button("Smoke: 5 at 1/s", #selector(smoke(_:))), button("Baseline: 20 at 1/s", #selector(baseline(_:)))]))
        stack.addArrangedSubview(NSStackView(views: [button("Burst: 20 at 5/s", #selector(burst(_:))), button("Identical pair", #selector(repeated(_:))), button("Long / Unicode", #selector(longText(_:))), button("Stop", #selector(stop(_:)))]))
        statusLabel = NSTextField(wrappingLabelWithString: "Checking notification permission…"); statusLabel.preferredMaxLayoutWidth = 720; stack.addArrangedSubview(statusLabel)
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        window.center(); window.makeKeyAndOrderFront(nil)
    }
    @objc func requestPermission(_ sender: Any?) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.authorized = granted
                self?.journal.append("generator.jsonl", ["type": "authorization", "granted": granted, "error": error.map { String(describing: $0) } ?? ""])
                self?.updateStatus(granted ? "Ready — notification permission granted" : "Notification permission is not granted")
            }
        }
    }
    @objc func smoke(_ sender: Any?) { begin(mode: "smoke", count: 5, interval: 1) }
    @objc func baseline(_ sender: Any?) { begin(mode: "baseline", count: 20, interval: 1) }
    @objc func burst(_ sender: Any?) { begin(mode: "burst", count: 20, interval: 0.2) }
    @objc func repeated(_ sender: Any?) { begin(mode: "identical", count: 2, interval: 1.5) }
    @objc func longText(_ sender: Any?) { begin(mode: "long", count: 1, interval: 1) }
    @objc func stop(_ sender: Any?) { sendTimer?.invalidate(); sendTimer = nil; running = false; updateStatus("Stopped") }
    func begin(mode: String, count: Int, interval: Double) {
        guard authorized else { updateStatus("Grant notification permission first"); return }
        guard !running else { updateStatus("A test is already running"); return }
        self.mode = mode; remaining = count; index = 0; running = true
        prefix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).uppercased()
        journal.append("generator.jsonl", ["type": "run_started", "run": prefix, "mode": mode, "count": count, "interval_seconds": interval])
        sendTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.sendOne() }
        RunLoop.main.add(sendTimer!, forMode: .common)
        sendOne()
    }
    func sendOne() {
        guard remaining > 0 else { finish(); return }
        index += 1; remaining -= 1
        let token = String(format: "LAB-%@-%04d", prefix, index)
        let content = UNMutableNotificationContent()
        content.title = mode == "identical" ? "NotificationLab identical pair" : "NotificationLab Test \(index)"
        content.subtitle = "Capture test — \(mode)"
        if mode == "identical" {
            content.body = "LAB-\(prefix)-0001 — two distinct notifications with identical visible text."
        } else if mode == "long" {
            content.body = token + " — Unicode: 中文 🧪 café\nSecond line\n" + String(repeating: "Long notification body. ", count: 90)
        } else {
            content.body = "\(token) — synthetic notification \(index); no external message was sent."
        }
        content.userInfo = ["lab_run": prefix, "lab_token": token, "lab_sequence": index]
        let expected: [String: Any] = ["type": "request", "run": prefix, "mode": mode, "request_identifier": token, "visible_token": mode == "identical" ? "LAB-\(prefix)-0001" : token, "title": content.title, "subtitle": content.subtitle, "body": content.body, "requested_at": timestamp()]
        journal.append("expected.jsonl", expected)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: token, content: content, trigger: nil)) { [weak self] error in
            self?.journal.append("generator.jsonl", ["type": "request_result", "request_identifier": token, "accepted": error == nil, "error": error.map { String(describing: $0) } ?? ""])
        }
        updateStatus("\(mode): sent \(index), remaining \(remaining), run \(prefix)")
        if remaining == 0 { finish() }
    }
    func finish() {
        sendTimer?.invalidate(); sendTimer = nil; running = false
        let run = prefix
        journal.append("generator.jsonl", ["type": "run_finished", "run": run, "sent": index])
        for delay in [1.0, 3.0, 8.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.snapshot(run: run) }
        }
        updateStatus("Finished \(mode), run \(run). Retained-delivery snapshots will be recorded.")
    }
    func snapshot(run: String) {
        UNUserNotificationCenter.current().getDeliveredNotifications { [weak self] notifications in
            for notification in notifications where notification.request.identifier.contains(run) {
                self?.journal.append("delivered.jsonl", ["type": "delivered_snapshot", "run": run, "request_identifier": notification.request.identifier, "delivered_at": timestamp(notification.date), "title": notification.request.content.title, "subtitle": notification.request.content.subtitle, "body": notification.request.content.body])
            }
            self?.journal.append("generator.jsonl", ["type": "snapshot", "run": run, "retained_count": notifications.filter { $0.request.identifier.contains(run) }.count, "note": "Retained notifications only; not a complete delivery history"])
        }
    }
    func updateStatus(_ text: String) {
        statusLabel.stringValue = text
        journal.status("generator-status.json", ["updated_at": timestamp(), "authorized": authorized, "running": running, "run": prefix, "mode": mode, "sent": index, "remaining": remaining, "message": text])
    }
    func consumeCommand() {
        guard let data = try? Data(contentsOf: labRoot().appendingPathComponent("generator-command.json")), let command = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let id = command["id"] as? String, id != lastCommandID else { return }
        lastCommandID = id
        switch command["action"] as? String {
        case "smoke": smoke(nil)
        case "baseline": baseline(nil)
        case "burst": burst(nil)
        case "identical": repeated(nil)
        case "long": longText(nil)
        case "stop": stop(nil)
        case "snapshot": snapshot(run: prefix)
        case "request_permission": requestPermission(nil)
        default: updateStatus("Unknown command")
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { pollTimer?.invalidate(); sendTimer?.invalidate() }
}

@main enum GeneratorMain {
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate = GeneratorDelegate(); app.delegate = delegate
        let menu = NSMenu(); let item = NSMenuItem(); let submenu = NSMenu()
        submenu.addItem(withTitle: "Quit NotificationLab Sender", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu; menu.addItem(item); app.mainMenu = menu
        withExtendedLifetime(delegate) { app.run() }
    }
}
