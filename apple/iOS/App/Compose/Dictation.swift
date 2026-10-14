import AVFoundation
import Observation
import os
import SamRabbitKit
import Speech
import SwiftUI

private let dictationLog = Logger(subsystem: "com.samrabbit.mobile", category: "dictation")

/// Speech to text on this iPhone (on-device when the language supports it and its model is ready,
/// otherwise Apple's speech service, like the keyboard's mic). Appends to the bound text as you
/// speak; the keyboard's own mic works in every field too.
@MainActor
@Observable
final class SpeechDictation {
    enum State: Equatable { case idle, listening, unavailable(String) }

    var state: State = .idle
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var prefix = ""
    /// Something was recognised since the last start.
    private var heard = false
    /// Which listening session is current: callbacks from an earlier one (stopped and started again, or
    /// restarted without the on-device model) arrive late and are ignored, so they never write into the
    /// text or stop the new session.
    private var generation = 0

    var isListening: Bool { state == .listening }

    /// Runs just before dictation takes the microphone: a live conversation (Talk) ends first, one microphone.
    static var willStart: (@MainActor () -> Void)?

    func toggle(_ text: Binding<String>) {
        if isListening { stop() } else { Task { await start(text) } }
    }

    /// `onDevice`: require the on-device recognizer when the language has one. If it can't start
    /// (its model isn't on this iPhone yet; the Simulator has none), dictation starts once more with
    /// Apple's speech service.
    func start(_ text: Binding<String>, onDevice: Bool = true) async {
        guard await Self.speechAuthorization() == .authorized else {
            state = .unavailable("Allow Speech Recognition for SamRabbit in Settings.")
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .unavailable("Allow the microphone for SamRabbit in Settings.")
            return
        }
        guard !isListening else { return }
        Self.willStart?()
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            state = .unavailable("Dictation isn't available right now.")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let engine = AVAudioEngine()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            let localOnly = onDevice && recognizer.supportsOnDeviceRecognition
            request.requiresOnDeviceRecognition = localOnly
            Self.feed(engine.inputNode, into: request)
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.request = request
            let base = text.wrappedValue.trimmingCharacters(in: .whitespaces)
            prefix = base.isEmpty ? "" : base + " "
            heard = false
            state = .listening
            generation += 1
            let current = generation
            task = Self.recognize(request, with: recognizer) { [weak self] transcript, done, failure in
                Task { @MainActor in
                    guard let self, self.generation == current else { return } // a finished session's late callback
                    if done { self.generation += 1 } // nothing after its end counts either
                    if let transcript {
                        text.wrappedValue = self.prefix + transcript
                        self.heard = true
                    }
                    guard done else { return }
                    let wasListening = self.isListening
                    self.stop()
                    if let failure {
                        dictationLog.notice("dictation ended: \(failure, privacy: .public)")
                        if wasListening, !self.heard, localOnly, failure.hasPrefix("kLSRErrorDomain") {
                            Task { await self.start(text, onDevice: false) }
                            return
                        }
                        // It stopped on its own before hearing anything (silence, no network, no
                        // speech model): say so instead of just going quiet.
                        if wasListening, !self.heard {
                            self.state = .unavailable("Dictation stopped before it heard anything. Tap the mic to try again, or type.")
                        }
                    }
                }
            }
        } catch {
            state = .unavailable("The microphone couldn't start.")
            stop()
        }
    }

    // Speech and AVFoundation call these back on their own queues (the tap on the audio thread). They
    // are nonisolated so the closures don't inherit the main actor: Swift 6 traps a main-actor closure
    // that runs anywhere else.

    private nonisolated static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private nonisolated static func feed(_ input: AVAudioInputNode, into request: SFSpeechAudioBufferRecognitionRequest) {
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
    }

    /// `update(transcript, done, failure)`: the text so far, whether recognition ended (final or
    /// failed), and the error's domain and code when it failed (never the words).
    private nonisolated static func recognize(_ request: SFSpeechAudioBufferRecognitionRequest, with recognizer: SFSpeechRecognizer,
                                              update: @escaping @Sendable (String?, Bool, String?) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let failure = error.map { error -> String in
                let ns = error as NSError
                return "\(ns.domain) \(ns.code)"
            }
            update(result?.bestTranscription.formattedString, error != nil || (result?.isFinal ?? false), failure)
        }
    }

    func stop() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        engine = nil
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if state == .listening { state = .idle }
    }
}

/// The mic button next to text fields. It has its own `SpeechDictation` unless it is given the
/// one its screen drives (the Ask sheet starts listening on its own).
struct DictationButton: View {
    @Binding var text: String
    @State private var own = SpeechDictation()
    private let shared: SpeechDictation?

    init(text: Binding<String>, dictation: SpeechDictation? = nil) {
        _text = text
        shared = dictation
    }

    private var dictation: SpeechDictation { shared ?? own }

    var body: some View {
        Button {
            Haptics.tap()
            dictation.toggle($text)
        } label: {
            Image(systemName: dictation.isListening ? "waveform" : "mic.fill")
                .font(.system(size: 15, weight: .semibold))
                .symbolEffect(.variableColor.iterative, isActive: dictation.isListening)
                .foregroundStyle(dictation.isListening ? SamTheme.red : SamTheme.ink2)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(dictation.isListening ? "Stop dictation" : "Dictate")
        .onDisappear { dictation.stop() }
        .popover(isPresented: Binding(get: {
            if case .unavailable = dictation.state { return true }
            return false
        }, set: { if !$0 { dictation.state = .idle } })) {
            if case .unavailable(let message) = dictation.state {
                Text(message).font(.system(size: 14)).padding().presentationCompactAdaptation(.popover)
            }
        }
    }
}

/// A one-line-to-five-line text field with a mic and a send button (thread replies, the Ask sheet).
struct Composer: View {
    @Binding var text: String
    var placeholder: String
    var sending = false
    var focused: FocusState<Bool>.Binding
    var send: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .focused(focused)
                .lineLimit(1...5)
                .font(.system(size: 16))
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
                .submitLabel(.send)
            DictationButton(text: $text)
            Button(action: send) {
                Group {
                    if sending { ProgressView().controlSize(.small) } else {
                        Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold))
                    }
                }
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            .accessibilityLabel("Send")
        }
    }
}
