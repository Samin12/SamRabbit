import AppKit
@preconcurrency import UserNotifications

/// Native notifications for "a new conversation started on the R1" and "a generated UI is ready".
/// Asks once; when permission is not granted it silently does nothing. Shown only while SamRabbit
/// is not the frontmost app (macOS default), silent (no sound). Clicking one opens the conversation.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String?) -> Void)?
    /// A click on an Agent Dock notification (an inbox item that needs Samin).
    var onOpenInboxItem: ((String) -> Void)?
    var onAuthorization: ((Bool) -> Void)?
    private var authorized = false {
        didSet { onAuthorization?(authorized) }
    }
    private var announced = Set<String>()
    private var announcedArtifacts = Set<String>()
    private var waiting: [String: DispatchWorkItem] = [:]
    /// Conversations that existed before this launch (never announced as new).
    var known = Set<String>()

    func setUp() {
        // Dev runs of a second copy (another bundle id) stay quiet: no permission prompt, no banners.
        if ProcessInfo.processInfo.environment["SAMRABBIT_NO_NOTIFICATIONS"] == "1" {
            Log.write("notifications off for this run")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task { @MainActor in
            let status = await center.notificationSettings().authorizationStatus
            if status == .notDetermined {
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                Log.write("notifications \(authorized ? "allowed" : "not allowed")")
            } else {
                authorized = status == .authorized || status == .provisional
                let name = status == .denied ? "denied (System Settings > Notifications > SamRabbit)" : "status \(status.rawValue)"
                Log.write("notifications \(authorized ? "allowed" : name)")
            }
        }
    }

    func consider(_ event: [String: Any]) {
        guard let type = event["type"] as? String,
              let conversationId = (event["conversationId"] as? String) ?? conversationPrefix(event["id"]) else { return }
        switch type {
        case "conversation.started":
            guard !announced.contains(conversationId), waiting[conversationId] == nil else { return }
            // Wait briefly for the first words so the banner can show them.
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.announceConversation(conversationId, text: nil) }
            }
            waiting[conversationId] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
        case "message.user":
            let isNew = waiting[conversationId] != nil || (!known.contains(conversationId) && !announced.contains(conversationId))
            guard isNew else { return }
            announceConversation(conversationId, text: event["text"] as? String)
        case "ui.generated":
            let artifactId = event["artifactId"] as? String ?? UUID().uuidString
            guard !announcedArtifacts.contains(artifactId) else { return }
            announcedArtifacts.insert(artifactId)
            let title = (event["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "A new UI"
            post(id: "ui-\(artifactId)", title: "Generated UI ready", subtitle: clip(title, 80),
                 body: clip(event["summary"] as? String ?? "Open SamRabbit to see it.", 160), conversationId: conversationId,
                 kind: "ui_generated")
        default:
            break
        }
    }

    /// A voice note that waited for the bridge has gone, and what the bridge did with it (a note recorded just now says
    /// so on the dock's bar instead).
    func voiceNote(title: String, body: String) {
        post(id: "note-\(UUID().uuidString)", title: title.isEmpty ? "Voice note sent" : title, subtitle: "Voice note",
             body: body.isEmpty ? "It went to your Mac’s bridge." : clip(body, 160), conversationId: "", kind: "voice_note")
    }

    /// An Agent Dock item started needing Samin (DockAttention decides: once per need, never repeated).
    func inboxItem(id: String, title: String, subtitle: String, body: String) {
        post(id: "inbox-\(id)", title: title, subtitle: clip(subtitle, 80), body: clip(body, 160), conversationId: "",
             kind: "inbox", extra: ["inboxItemId": id])
    }

    private func announceConversation(_ conversationId: String, text: String?) {
        waiting.removeValue(forKey: conversationId)?.cancel()
        guard !announced.contains(conversationId) else { return }
        announced.insert(conversationId)
        known.insert(conversationId)
        let words = text.map { clip($0, 160) }.flatMap { $0.isEmpty ? nil : "“\($0)”" }
        post(id: "conv-\(conversationId)", title: "New conversation on your R1", subtitle: nil,
             body: words ?? "Follow it live in SamRabbit.", conversationId: conversationId, kind: "new_conversation")
    }

    private func post(id: String, title: String, subtitle: String?, body: String, conversationId: String, kind: String,
                      extra: [String: String] = [:]) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        content.body = body
        content.userInfo = extra.merging(["conversationId": conversationId]) { first, _ in first }
        content.threadIdentifier = conversationId.isEmpty ? kind : conversationId
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            Log.write(error == nil ? "notification posted (\(kind))" : "notification failed (\(kind))")
        }
    }

    private func clip(_ text: String, _ max: Int) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }

    private func conversationPrefix(_ id: Any?) -> String? {
        guard let id = id as? String, id.hasPrefix("c_"), let colon = id.firstIndex(of: ":") else { return nil }
        return String(id[id.startIndex..<colon])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let conversationId = response.notification.request.content.userInfo["conversationId"] as? String
        let inboxItemId = response.notification.request.content.userInfo["inboxItemId"] as? String
        Task { @MainActor in
            if let inboxItemId {
                self.onOpenInboxItem?(inboxItemId)
            } else {
                self.onOpen?(conversationId)
            }
            completionHandler()
        }
    }
}
