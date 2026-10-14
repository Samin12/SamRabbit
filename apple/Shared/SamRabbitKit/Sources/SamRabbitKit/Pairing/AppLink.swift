import Foundation

/// Something a `samrabbit://` link asks for that would change something: on the calendar, in the
/// journal, in T3 Code or on the Mac. Links come from anywhere (a web page, a message, a QR code,
/// another app), so the app never performs one on its own: it shows what will happen and waits
/// for Confirm. (Siri, Shortcuts and the widgets' buttons run App Intents instead, which the
/// person started themselves.)
public enum LinkAction: Sendable, Equatable {
    /// `samrabbit://block?minutes=N[&title=…]`: a calendar block from now.
    case block(minutes: Int, title: String?)
    /// `samrabbit://ask?text=…` (also `task?text=`, `new?text=`): a new T3 Code task.
    case ask(text: String)
    /// `samrabbit://note?text=…` (also `journal?text=`): words for today's journal.
    case note(text: String)
    /// `samrabbit://mac/open?app=…` or `?url=…`: open an app or a link on the Mac.
    case openOnMac(app: String?, url: String?)
    /// `samrabbit://generate?text=…`: a generated UI made on the Mac.
    case generate(prompt: String)

    /// The default and the limits of a block (the bridge refuses outside 5 minutes to 12 hours).
    public static let blockMinutes = 5...720
    public static let defaultBlockMinutes = 30
    static let maxText = 4000

    /// "Block 45 minutes", "Start a T3 Code task", ...
    public var headline: String {
        switch self {
        case .block(let minutes, _): "Block \(Formatting.minutes(minutes)) on your calendar"
        case .ask: "Start a T3 Code task"
        case .note: "Add to today's journal"
        case .openOnMac(let app, let url): "Open \(app ?? url.map(Self.hostOf) ?? "it") on your Mac"
        case .generate: "Generate a UI on your Mac"
        }
    }

    /// The text the action carries (shown in full, quoted), if any.
    public var payload: String? {
        switch self {
        case .block: nil
        case .ask(let text), .note(let text), .generate(let text): text
        case .openOnMac(_, let url): url
        }
    }

    /// The button that performs it.
    public var confirmTitle: String {
        switch self {
        case .block: "Block"
        case .ask: "Start task"
        case .note: "Add note"
        case .openOnMac: "Open"
        case .generate: "Generate"
        }
    }

    private static func hostOf(_ url: String) -> String {
        URLComponents(string: url)?.host ?? Formatting.clip(url, 40)
    }
}

/// A parsed `samrabbit://` link: where to go in the app, or an action to confirm.
public enum AppLink: Sendable, Equatable {
    /// `samrabbit://pair?h=…&c=…`: the pairing confirmation sheet.
    case pair(PairLink)
    /// `samrabbit://pair` without a code: Settings with the manual pairing form.
    case manualPair
    /// An empty composer (`ask`, `note`, `generate` without text, `mac/open` without a target):
    /// nothing happens until the person writes something and taps the button. `listen`: start
    /// dictation at once (`?listen=1`), kept only for the app's own intents (`fromApp`), such as the
    /// Action Button. A link from outside never turns the microphone on.
    case compose(Composer, listen: Bool = false)
    /// Something that writes: shown on a confirmation sheet, performed only by its Confirm button.
    case confirm(LinkAction)
    /// `thread/<id>` (or `task/<id>`): the Tasks tab, with the thread when there is an id.
    case thread(String?)
    /// `conversation/<id>` (or `chat/<id>`): the Chats tab, with the conversation.
    case conversation(String?)
    /// `tab/<name>`
    case tab(String)
    /// `mac`, `mac/screenshot`: the Mac tab (a screenshot is a read, shown only on this phone).
    case mac(screenshot: Bool)
    /// `talk` (also `voice`, `assistant`): the live conversation with SamRabbit, started at once, like the watch's
    /// complications. The link itself writes nothing: what is said does, and the assistant asks before it approves,
    /// denies, stops or deletes anything.
    case talk

    public enum Composer: String, Sendable {
        case ask, note, generate, openOnMac
    }

    /// `fromApp`: the link came from one of the app's own intents (`PendingRoute`), not from a web
    /// page, a message or another app.
    public init?(url: URL, fromApp: Bool = false) {
        guard url.scheme?.lowercased() == SamRabbit.urlScheme else { return nil }
        if let link = PairLink(url: url) {
            self = .pair(link)
            return
        }
        let target = (url.host ?? "").lowercased()
        let parts = url.path.split(separator: "/").map(String.init)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ names: String...) -> String? {
            for name in names {
                if let raw = query.first(where: { $0.name == name })?.value {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return String(trimmed.prefix(LinkAction.maxText)) }
                }
            }
            return nil
        }
        let listen = fromApp && ["1", "true", "yes"].contains(value("listen")?.lowercased() ?? "")
        switch target {
        case "pair":
            self = .manualPair
        case "ask", "new", "newtask":
            self = value("text", "q").map { .confirm(.ask(text: $0)) } ?? .compose(.ask, listen: listen)
        case "note", "journal":
            self = value("text").map { .confirm(.note(text: $0)) } ?? .compose(.note, listen: listen)
        case "generate":
            self = value("text", "prompt").map { .confirm(.generate(prompt: $0)) } ?? .compose(.generate, listen: listen)
        case "block":
            let asked = value("minutes", "m").flatMap { Int($0) } ?? LinkAction.defaultBlockMinutes
            let minutes = min(max(asked, LinkAction.blockMinutes.lowerBound), LinkAction.blockMinutes.upperBound)
            self = .confirm(.block(minutes: minutes, title: value("title").map { String($0.prefix(120)) }))
        case "thread", "task":
            if target == "task", parts.isEmpty, let text = value("text") {
                self = .confirm(.ask(text: text))
            } else {
                self = .thread(parts.first)
            }
        case "conversation", "chat":
            self = .conversation(parts.first)
        case "tab":
            guard let name = parts.first?.lowercased() else { return nil }
            self = .tab(name)
        case "talk", "voice", "assistant":
            self = .talk
        case "mac":
            switch parts.first?.lowercased() {
            case "open":
                let app = value("app")
                let url = value("url").flatMap(Self.webLink)
                if app == nil, url == nil {
                    self = .compose(.openOnMac)
                } else {
                    self = .confirm(.openOnMac(app: url == nil ? app : nil, url: url))
                }
            case "screenshot":
                self = .mac(screenshot: true)
            default:
                self = .mac(screenshot: false)
            }
        default:
            return nil
        }
    }

    /// Only http(s) links may be opened on the Mac from a link.
    static func webLink(_ raw: String) -> String? {
        guard let components = URLComponents(string: raw), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", components.host?.isEmpty == false else { return nil }
        return raw
    }
}
