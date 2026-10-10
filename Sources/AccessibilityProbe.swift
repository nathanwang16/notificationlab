import AppKit
import ApplicationServices
import Foundation

struct AXNode {
    let attributes: [String: String]
    let children: [AXNode]
    var texts: [String] {
        var all = ["AXValue", "AXTitle", "AXDescription"].compactMap { attributes[$0] }
        all.append(contentsOf: children.flatMap { $0.texts })
        var seen: Set<String> = []
        return all.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    var json: [String: Any] { ["attributes": attributes, "children": children.map { $0.json }] }
    func field(_ identifier: String) -> String? {
        if attributes["AXIdentifier"] == identifier { return attributes["AXValue"] }
        return children.lazy.compactMap { $0.field(identifier) }.first
    }
    func sourceBundle(allowed: [String]) -> String? {
        let label = attributes["AXDescription"]?.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = normalizedSources(allowed)
        if selected.contains(generatorBundle), label == "NotificationLab Sender" { return generatorBundle }
        if selected.contains(discordBundle), label == "Discord" { return discordBundle }
        return nil
    }
    func notificationCards(allowed: [String]) -> [(AXNode, String)] {
        // Persistent alerts can expose a different subrole from temporary banners.
        if let source = sourceBundle(allowed: allowed), field("title") != nil || field("body") != nil { return [(self, source)] }
        return children.flatMap { $0.notificationCards(allowed: allowed) }
    }
    var structuralMetadata: [String: Any] {
        var metadata = attributes.filter { ["AXRole", "AXSubrole"].contains($0.key) }
        if let identifier = attributes["AXIdentifier"] { metadata["AXIdentifier"] = ["title", "subtitle", "body"].contains(identifier) ? identifier : "other" }
        metadata["attribute_keys"] = attributes.keys.sorted().joined(separator: ",")
        metadata["synthetic_marker_here"] = runToken(in: ["AXValue", "AXTitle", "AXDescription"].compactMap { attributes[$0] }) == nil ? "false" : "true"
        metadata["test_app_label_here"] = ["AXValue", "AXTitle", "AXDescription"].compactMap { attributes[$0] }.contains { $0.hasPrefix("NotificationLab Sender") } ? "true" : "false"
        return ["attributes": metadata, "children": children.map { $0.structuralMetadata }]
    }
}

final class AccessibilityProbe {
    let journal: Journal
    var sourceBundles: [String] = [generatorBundle]
    private var observers: [pid_t: AXObserver] = [:]
    private var trackers: [String: (fingerprint: String, instance: String)] = [:]
    private var lastStatus = ""
    private var primed = false
    private var lastUnknownLayout = ""
    private(set) var state = "not started"
    private(set) var eventCount = 0
    init(journal: Journal) { self.journal = journal }
    deinit { stop() }
    func stop() {
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observers.removeAll()
    }
    private func setState(_ value: String) {
        state = value
        if value != lastStatus {
            journal.append("diagnostics.jsonl", ["backend": "accessibility", "type": "status", "message": value])
            lastStatus = value
        }
    }
    private func targets() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            let name = $0.localizedName ?? ""
            let bundle = ($0.bundleIdentifier ?? "").lowercased()
            return name.contains("NotificationCenter") || name.contains("UserNotificationCenter") || bundle.contains("notificationcenterui") || bundle.contains("usernotificationcenter")
        }
    }
    private func attach(_ apps: [NSRunningApplication]) {
        let pids = Set(apps.map { $0.processIdentifier })
        for pid in observers.keys.filter({ !pids.contains($0) }) {
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
        for app in apps where observers[app.processIdentifier] == nil {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.25)
            var observer: AXObserver?
            let callback: AXObserverCallback = { _, _, event, context in
                guard let context else { return }
                let probe = Unmanaged<AccessibilityProbe>.fromOpaque(context).takeUnretainedValue()
                probe.journal.append("diagnostics.jsonl", ["backend": "accessibility", "type": "callback", "event": event as String])
                for delay in [0.05, 0.15, 0.5] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak probe] in probe?.scan(trigger: "callback") }
                }
            }
            let result = AXObserverCreate(app.processIdentifier, callback, &observer)
            guard result == .success, let observer else {
                journal.append("diagnostics.jsonl", ["backend": "accessibility", "type": "observer_error", "pid": app.processIdentifier, "code": result.rawValue]); continue
            }
            let ref = Unmanaged.passUnretained(self).toOpaque()
            var subscriptions: [String: Int] = [:]
            for name in [kAXWindowCreatedNotification, kAXLayoutChangedNotification, kAXFocusedUIElementChangedNotification, kAXMainWindowChangedNotification] {
                subscriptions[name] = Int(AXObserverAddNotification(observer, element, name as CFString, ref).rawValue)
            }
            observers[app.processIdentifier] = observer
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            journal.append("diagnostics.jsonl", ["backend": "accessibility", "type": "attached", "pid": app.processIdentifier, "bundle": app.bundleIdentifier ?? "", "name": app.localizedName ?? "", "subscriptions": subscriptions])
        }
    }
    private func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }
    private func node(_ element: AXUIElement, depth: Int, remaining: inout Int) -> AXNode {
        remaining -= 1
        var attrs: [String: String] = [:]
        for name in ["AXRole", "AXSubrole", "AXIdentifier", "AXValue", "AXTitle", "AXDescription"] {
            if let text = value(element, name) as? String, !text.isEmpty { attrs[name] = text }
        }
        var children: [AXNode] = []
        if depth < 16, remaining > 0, let elements = value(element, "AXChildren") as? [AXUIElement] {
            for child in elements {
                guard remaining > 0 else { break }
                children.append(node(child, depth: depth + 1, remaining: &remaining))
            }
        }
        return AXNode(attributes: attrs, children: children)
    }
    func scan(trigger: String = "timer") {
        guard AXIsProcessTrusted() else { setState("Accessibility permission required"); return }
        let apps = targets()
        guard !apps.isEmpty else { setState("No notification UI process found; send a notification"); return }
        attach(apps)
        var active: Set<String> = []
        var windowCount = 0
        for app in apps {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.25)
            let windows = value(element, "AXWindows") as? [AXUIElement] ?? []
            let candidates = windows.isEmpty ? (value(element, "AXChildren") as? [AXUIElement] ?? []) : windows
            windowCount += candidates.count
            for window in candidates {
                var remaining = 600
                let tree = node(window, depth: 0, remaining: &remaining)
                let candidates = tree.notificationCards(allowed: sourceBundles)
                if candidates.isEmpty, sourceBundles.contains(generatorBundle), runToken(in: tree.texts) != nil {
                    let layout = tree.structuralMetadata
                    let fingerprint = digest((try? jsonData(layout)) ?? Data())
                    if fingerprint != lastUnknownLayout {
                        journal.append("diagnostics.jsonl", ["backend": "accessibility", "type": "unrecognized_synthetic_layout", "structure": layout, "note": "Role/key metadata only; all notification text omitted"])
                        lastUnknownLayout = fingerprint
                    }
                }
                for (index, candidate) in candidates.enumerated() {
                    let (card, source) = candidate
                    let uuid = card.attributes["AXIdentifier"].flatMap { UUID(uuidString: $0) }
                    let notificationID = uuid.map { source + ":" + $0.uuidString.replacingOccurrences(of: "-", with: "") }
                    let key = notificationID ?? "\(app.processIdentifier):\(CFHash(window)):\(index)"
                    active.insert(key)
                    let usefulTexts = card.texts.filter { !["Close", "Options", "Reply", "View", "now"].contains($0) }
                    let fields = ["title", "subtitle", "body"].reduce(into: [String: String]()) { if let value = card.field($1) { $0[$1] = value } }
                    let fingerprint = digest((try? jsonData(fields.isEmpty ? usefulTexts as Any : fields as Any)) ?? Data())
                    let previous = trackers[key]
                    let instance = previous?.instance ?? UUID().uuidString
                    trackers[key] = (fingerprint, instance)
                    guard primed, previous?.fingerprint != fingerprint else { continue }
                    var event: [String: Any] = ["backend": "accessibility", "kind": previous == nil ? "appeared" : "updated", "source_bundle": source, "notification_instance": instance, "trigger": trigger, "texts": usefulTexts, "raw_tree": card.json, "extraction": "AX title/subtitle/body fields; completeness measured against sender expectations", "tree_limit_reached": remaining <= 0, "identity_basis": notificationID == nil ? "window position; provisional" : "AXIdentifier UUID"]
                    for (name, value) in fields { event[name] = value }
                    if let notificationID { event["notification_id"] = notificationID }
                    if let token = runToken(in: usefulTexts) { event["test_token"] = token }
                    journal.append("accessibility.jsonl", event); eventCount += 1
                }
            }
        }
        for key in trackers.keys.filter({ !active.contains($0) }) { trackers.removeValue(forKey: key) }
        if !primed {
            journal.append("diagnostics.jsonl", ["backend": "accessibility", "type": "baseline", "windows": windowCount]); primed = true
        }
        setState("connected; \(eventCount) observations; \(windowCount) windows")
    }
}
