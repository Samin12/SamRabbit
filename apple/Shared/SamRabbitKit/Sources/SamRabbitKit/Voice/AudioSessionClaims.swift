import Foundation

/// Who holds the app's one audio session right now. `AVAudioSession` is shared by the whole app: the iPhone's live
/// conversation (Talk) and a composer's dictation run on the same session, and deactivating it stops every engine
/// that runs on it without telling them (no interruption, no configuration change: the conversation would stay on
/// "Listening…" hearing nothing). So each gives the session back only when it activated it itself and nobody else
/// still holds it; a mic button that never listened (it disappears with its screen) gives nothing back.
public struct AudioSessionClaims: Sendable, Equatable {
    public enum Holder: String, Sendable, Equatable {
        /// The live conversation (`AudioGraph`, the watch's and the iPhone's).
        case conversation
        /// The iPhone's dictation (a composer's mic button).
        case dictation
        /// A voice note's recorder (the iPhone's and the watch's).
        case capture
    }

    public private(set) var holders: Set<Holder> = []

    public init() {}

    /// `holder` activated the session.
    public mutating func claim(_ holder: Holder) {
        holders.insert(holder)
    }

    /// `holder` is done with the session. Returns whether to deactivate it now: only when `holder` held it and
    /// nobody else still does.
    public mutating func release(_ holder: Holder) -> Bool {
        guard holders.remove(holder) != nil else { return false }
        return holders.isEmpty
    }
}
