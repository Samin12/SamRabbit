import Foundation

/// What a voice note on the iPhone is doing, for its Live Activity (the Lock Screen and the Dynamic Island) and the
/// recorder: recording (with Stop), sending, then what the Mac did ("Sent ✓ — Added to your journal"), kept on the
/// phone until the Mac can be reached, sent but not done there (nothing heard, the Mac couldn't do it), or not sent.
/// It shows on a locked phone, so its line never carries what was said. Platform-neutral (the attributes are iOS
/// only), so `swift test` covers it.
public struct CaptureActivityState: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Sendable, Hashable {
        case recording, sending, sent, queued
        /// The Mac has it but couldn't do it, or heard nothing in it: sent, with what went wrong.
        case problem
        /// It didn't reach the Mac and won't go by itself.
        case failed
    }

    public var phase: Phase
    /// The outcome's line once it went ("Added to your journal", "Saved as a note · It's in Tasks.").
    public var line: String
    /// When the recording stopped (the timer stops there).
    public var stoppedAt: Date?

    public static let maxLine = 120

    public init(phase: Phase, line: String = "", stoppedAt: Date? = nil) {
        self.phase = phase
        self.line = Formatting.clip(line, Self.maxLine)
        self.stoppedAt = stoppedAt
    }

    /// From what the recorder shows once the note went: its title and what a locked phone may show of it
    /// (`CaptureNotice.glance`), never the words the recorder repeats.
    public init(_ notice: CaptureNotice, stoppedAt: Date?) {
        let phase: Phase = switch notice.tone {
        case .sent: .sent
        case .queued: .queued
        case .failed: notice.reachedMac ? .problem : .failed
        }
        let line = [notice.title == "Sent" ? nil : notice.title, notice.glance].compactMap { $0 }.joined(separator: " · ")
        self.init(phase: phase, line: line, stoppedAt: stoppedAt)
    }

    /// "Recording…", "Sending…", "Sent ✓", "Saved", "Sent" (but not done), "Not sent".
    public var word: String {
        switch phase {
        case .recording: "Recording…"
        case .sending: "Sending…"
        case .sent: "Sent ✓"
        case .queued: "Saved"
        case .problem: "Sent"
        case .failed: "Not sent"
        }
    }

    public var symbol: String {
        switch phase {
        case .recording: "waveform"
        case .sending: "arrow.up.circle.fill"
        case .sent: "checkmark.circle.fill"
        case .queued: "tray.and.arrow.up.fill"
        case .problem: "exclamationmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    /// The activity is over (it ends a few seconds after showing this).
    public var final: Bool { phase == .sent || phase == .queued || phase == .problem || phase == .failed }
}

#if os(iOS) && canImport(ActivityKit)
import ActivityKit

/// The "Voice note" Live Activity: while the iPhone records a note (the screen may be locked) the Lock Screen and
/// the Dynamic Island show the timer and Stop; then what became of it, for a few seconds.
public struct CaptureActivityAttributes: ActivityAttributes {
    public typealias ContentState = CaptureActivityState

    public var captureId: String
    public var startedAt: Date
    /// The longest it records (the timer's end).
    public var limit: TimeInterval

    public init(captureId: String, startedAt: Date = .now, limit: TimeInterval = CaptureFormat.iphoneMaxSeconds) {
        self.captureId = captureId
        self.startedAt = startedAt
        self.limit = limit
    }
}
#endif
