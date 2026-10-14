import Foundation
import os
import SamRabbitKit

private let notesLog = Logger(subsystem: "com.samrabbit.mobile.watchkitapp", category: "capture")

/// The watch's voice notes on their way to the Mac (CONTRACTS-WAVE8 §C3), kept in the watch's outbox
/// (`CaptureOutbox`, the App Group's `Captures/`) until the bridge has them. Each goes directly; else through the
/// iPhone in chunks (`PhoneLink.relayCapture`, with the watch's own token); else, with neither reachable, it is handed
/// to the iPhone with `WCSession.transferFile`, which watchOS delivers whenever it can and the iPhone sends on from its
/// own outbox. The note's id makes any second try harmless. Notes that wait are tried again when the app comes to
/// the front. Nothing about what was said is logged.
@MainActor
final class WatchCaptures {
    let outbox: CaptureOutbox
    private let account: BridgeAccount
    private let link: PhoneLink
    /// Notes being sent now.
    private var sending: Set<String> = []

    init(account: BridgeAccount, link: PhoneLink, outbox: CaptureOutbox = .shared) {
        self.account = account
        self.link = link
        self.outbox = outbox
    }

    var waiting: Int { outbox.waiting }

    /// Sends one note and says what became of it (waiting up to `outcomeWait` seconds for what the Mac did).
    func send(_ entry: CaptureOutbox.Entry, outcomeWait: Int = 6) async -> CaptureNotice {
        guard sending.insert(entry.id).inserted else { return .queued(waiting: max(1, waiting)) }
        defer { sending.remove(entry.id) }
        guard let client = account.client() else {
            outbox.failed(entry.id, error: "not_paired", retryable: true)
            return CaptureNotice(tone: .queued, title: "Saved", detail: "Pair on your iPhone to send it.",
                                 symbol: "iphone.slash")
        }
        let audio = outbox.audioURL(entry.id)
        do {
            var status = try await client.capture(file: audio, meta: entry.meta, timeout: 20)
            outbox.delivered(entry.id, status: status)
            notesLog.info("capture \(entry.id.prefix(8), privacy: .public) received")
            let deadline = Date.now.addingTimeInterval(TimeInterval(outcomeWait))
            while !status.state.settled, Date.now < deadline {
                let left = Int(deadline.timeIntervalSinceNow.rounded(.up))
                guard left > 0, let next = try? await client.captureStatus(entry.id, wait: left) else { break }
                status = next
            }
            outbox.record(status)
            return status.notice
        } catch let error as BridgeError where error.isRetryableCapture {
            // Neither the Mac nor the iPhone answered now: watchOS carries it to the iPhone when it can.
            if case .unreachable = error, link.transferCapture(audio, meta: entry.meta) {
                outbox.failed(entry.id, error: "handed_to_phone", retryable: true)
                notesLog.notice("capture \(entry.id.prefix(8), privacy: .public) handed to the iPhone")
                return .handedToPhone
            }
            outbox.failed(entry.id, error: error.code ?? "unreachable", retryable: true)
            return .queued(waiting: max(1, waiting))
        } catch let error as BridgeError {
            outbox.failed(entry.id, error: error.code ?? "refused", retryable: false)
            return CaptureNotice(tone: .failed, title: "Your Mac didn't take it",
                                 detail: error.watchDetail ?? "Say it again.", symbol: "exclamationmark.triangle.fill")
        } catch {
            outbox.failed(entry.id, error: "failed", retryable: true)
            return .queued(waiting: max(1, waiting))
        }
    }

    /// Sends the notes whose pause is over, quietly; `now`: every waiting note, its pause or not (the app came to the
    /// front). Notes on their way (being sent, or handed to the iPhone) are left to it.
    func flush(now: Bool = false) {
        outbox.prune()
        if now { outbox.retryNow() }
        let due = outbox.due(excluding: sending).filter { !link.transferring($0.id) }
        guard !due.isEmpty else { return }
        Task {
            for entry in due { _ = await send(entry, outcomeWait: 0) }
        }
    }
}
