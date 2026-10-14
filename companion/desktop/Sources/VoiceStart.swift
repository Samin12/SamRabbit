import Foundation

/// How a conversation's microphone starts (`VoiceAudio.startDevice`), apart from AVFoundation so it is tested
/// (tests/voice/StartTests.swift, run by tests/voice/run.sh):
///
/// * Echo cancellation (voice processing) first, only when it is on (`defaults write com.samrabbit.desktop
///   VoiceEchoCancellation -bool true`) and has not failed slowly on this input. On Samin's Mac (a USB microphone,
///   speakers on a DisplayPort monitor) it took about 12 s to fail (-10875) and left the device unable to start for
///   the next try: a failure that slow is not tried again on that input until the app restarts (another input is
///   tried; a quick failure, a microphone busy for a moment, is tried again next time).
/// * Then the plain microphone, tried three times 0.3 s apart (a microphone the "Hey Rabbit" listener just handed
///   over can be busy for a moment).
/// * A start that `stop()` or another `start()` overtook while it waited gives up with `CancellationError`: it never
///   starts an engine of its own.
@MainActor
final class MicrophoneStart {
    enum Outcome: Equatable {
        case echoCancellation
        /// The plain microphone, on this try (1, 2 or 3).
        case plain(attempt: Int)
    }

    /// Every try failed.
    struct GaveUp: Error {}

    static let tries = 3
    static let pause: Duration = .milliseconds(300)
    /// A voice-processing failure at least this slow is not tried again on that input.
    static let slowFailure: TimeInterval = 1

    /// The inputs (CoreAudio device ids; 0: none known) voice processing failed slowly on.
    private(set) var echoFailedOn: Set<UInt32> = []

    /// Whether this start tries echo cancellation first.
    func triesEchoCancellation(_ enabled: Bool, input: UInt32?) -> Bool {
        enabled && !echoFailedOn.contains(input ?? 0)
    }

    /// - `start`: builds and starts the engine, with voice processing or without (cleaning up after itself when it
    ///   throws). `wait`: the pause between tries (it throws when the task is cancelled). `current`: this start is
    ///   still the one wanted. `now`: the clock that tells a slow failure.
    func run(echoCancellation enabled: Bool, input: UInt32?, now: () -> Date = { Date() },
             start: (_ echoCancellation: Bool) throws -> Void, wait: () async throws -> Void,
             current: () -> Bool, log: (String) -> Void) async throws -> Outcome {
        if triesEchoCancellation(enabled, input: input) {
            let began = now()
            do {
                try start(true)
                return .echoCancellation
            } catch {
                let took = now().timeIntervalSince(began)
                let slow = took >= Self.slowFailure
                if slow { echoFailedOn.insert(input ?? 0) }
                log("voice processing did not start (\(Self.describe(error)) after \(String(format: "%.1f", took)) s); "
                    + "going on without it" + (slow ? ", not tried again on this microphone until SamRabbit restarts" : ""))
            }
        }
        for attempt in 1...Self.tries {
            if attempt > 1 {
                try await wait()
                guard current() else { throw CancellationError() }
            }
            do {
                try start(false)
                return .plain(attempt: attempt)
            } catch {
                log("audio did not start (try \(attempt): \(Self.describe(error)))")
            }
        }
        throw GaveUp()
    }

    /// An error as `domain#code` (never its text).
    nonisolated static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain)#\(ns.code)"
    }
}
