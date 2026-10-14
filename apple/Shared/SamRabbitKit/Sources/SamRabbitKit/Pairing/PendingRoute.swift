import Foundation

/// A place in the app that an App Intent asked for: the Action Button, the "Ask SamRabbit"
/// controls (Control Center, the Lock Screen, the Action Button), the widgets' Ask buttons and Siri.
///
/// The intent runs just before or just after the app comes to the front, so it leaves a
/// `samrabbit://` link in the App Group and posts `didChange`. The app picks the link up with
/// `take(from:)` when it becomes active, or right away if it is already in front. Only the app's
/// own intents leave links here, so the app trusts them more than a link from outside (see
/// `AppLink(url:fromApp:)`).
public enum PendingRoute {
    public static let key = "pendingRoute"

    /// Posted in the process that left the link (the app, when the intent runs inside it).
    public static let didChange = Notification.Name("samrabbit.pendingRouteChanged")

    /// A link the app hasn't taken after this many seconds is dropped. If the intent ran but the
    /// app never came up, the Ask sheet must not open with the mic on hours later.
    public static let lifetime: TimeInterval = 120

    /// Ask, with dictation already listening (the Action Button, the Ask controls and buttons).
    public static let askListening = "samrabbit://ask?listen=1"

    /// Talk: the live conversation with SamRabbit (the "Talk to SamRabbit" intent: Siri, Shortcuts, the Action
    /// Button, the Talk control).
    public static let talk = "samrabbit://talk"

    /// Leaves `url` for the app and tells it.
    public static func set(_ url: String, in defaults: UserDefaults, now: Date = .now) {
        defaults.set(["url": url, "at": now.timeIntervalSince1970], forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// The link left for the app, removed as it is read. Returns nil when there is none, or when it is
    /// older than `lifetime`. A plain string from an older build has no time and is accepted.
    public static func take(from defaults: UserDefaults, now: Date = .now) -> URL? {
        guard let stored = defaults.object(forKey: key) else { return nil }
        defaults.removeObject(forKey: key)
        let raw: String?
        if let entry = stored as? [String: Any] {
            raw = entry["url"] as? String
            guard let at = entry["at"] as? Double else { return nil }
            let age = now.timeIntervalSince1970 - at
            guard age >= -5, age <= lifetime else { return nil }
        } else {
            raw = stored as? String
        }
        guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == SamRabbit.urlScheme else { return nil }
        return url
    }
}
