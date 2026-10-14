import SamRabbitKit
import SwiftUI

/// Settings > Action Button: where to set the iPhone's and the Apple Watch Ultra's Action Button so it opens
/// SamRabbit in a live conversation (Talk) or records a voice note, and what a voice note does. Apps can't set the
/// button themselves; this says exactly where to do it.
struct ActionButtonHelpView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(BackgroundNote.key) private var backgroundNote = false

    var body: some View {
        List {
            Section {
                HelpStep(1, "Open **Settings** > **Action Button**.")
                HelpStep(2, "Swipe to **Controls**, tap **Choose a Control…** and pick **SamRabbit** > **Talk to SamRabbit** or **Voice Note**.")
                HelpStep(3, "**Press and hold** the Action Button. **Talk** opens SamRabbit in a live call, like your R1: just talk. **Voice Note** records at once and sends it when you pause. Press again to send now; both keep going with the screen locked.")
            } header: {
                Text("iPhone")
            } footer: {
                Text("Already set to **Ask SamRabbit**? It now opens the live call too: nothing to change. Under **Shortcut** > **Choose a Shortcut…** > **SamRabbit** the same are **Talk** and **Voice Note**, and **Back Tap** (Settings > Accessibility > Touch) can run them as well.")
            }
            .listRowBackground(SamTheme.glass2)

            Section {
                HelpLine(symbol: "book.closed.fill", tint: SamTheme.mint,
                         text: "“Put this in my journal: …” goes to today's journal, in your words. Only when you say so.")
                HelpLine(symbol: "sparkles", tint: SamTheme.orbPale,
                         text: "“Make a task to …” starts a T3 Code task with what you said.")
                HelpLine(symbol: "calendar.badge.clock", tint: SamTheme.violet,
                         text: "A time (“remind me at 3 to call Dana”, “block an hour”) goes on your calendar.")
                HelpLine(symbol: "note.text", tint: SamTheme.amber,
                         text: "Anything else is saved as a note in Tasks, with a suggestion you can tap.")
            } header: {
                Text("Voice note")
            } footer: {
                Text("Nothing is said back: you see “Sent ✓” and what your Mac did. With your Mac out of reach it waits on this iPhone and goes later.")
            }
            .listRowBackground(SamTheme.glass2)

            Section {
                HelpStep(1, "On the watch, open **Settings** > **Action Button**.")
                HelpStep(2, "Tap **Action** and choose **Control**. Go back, tap **Control** (it says **Configure** until one is set) and pick **SamRabbit** > **Ask SamRabbit** (the live conversation) or **Voice Note**.")
                HelpStep(3, "**Press** the Action Button once. Talk opens the conversation; Voice Note records and sends when you pause (or tap Stop, or double-tap on watches that can).")
            } header: {
                Text("Apple Watch Ultra")
            } footer: {
                Text("Install the watch app first: Watch app on this iPhone > SamRabbit > Install. The watch connects through this iPhone by itself. Newer watchOS may say **Choose Action** instead of **Action**. A Voice note complication is in the watch face's list too.")
            }
            .listRowBackground(SamTheme.glass2)

            Section {
                Button {
                    model.startTalk()
                } label: {
                    Label("Try Talk here", systemImage: "waveform")
                }
                Button {
                    model.startVoiceNote(record: true)
                } label: {
                    Label("Try a voice note here", systemImage: "waveform.badge.mic")
                }
                .accessibilityIdentifier("help-try-note")
                Button {
                    model.sheet = .ask(prefill: "", listen: UUID())
                } label: {
                    Label("Try Ask here", systemImage: "mic.fill")
                }
            } footer: {
                Text("Opens Talk, the voice-note recorder or Ask the way the Action Button does.")
            }
            .listRowBackground(SamTheme.glass2)

            Section {
                Toggle(isOn: $backgroundNote) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Record without opening SamRabbit")
                        Text("Experimental").font(.system(size: 12.5)).foregroundStyle(SamTheme.muted)
                    }
                }
                .tint(SamTheme.red)
            } footer: {
                Text("For the **Voice Note Without Opening** shortcut: it tries to record with SamRabbit in the background (a Live Activity shows it). iOS may not allow it; then SamRabbit opens and records as usual.")
            }
            .listRowBackground(SamTheme.glass2)
        }
        .samScreen()
        .navigationTitle("Action Button")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A line with a coloured symbol (what a voice note does).
private struct HelpLine: View {
    let symbol: String
    let tint: Color
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
            Text(text).font(.system(size: 15)).foregroundStyle(SamTheme.ink)
        }
        .padding(.vertical, 2)
    }
}

/// A numbered step.
private struct HelpStep: View {
    let number: Int
    let text: LocalizedStringKey

    init(_ number: Int, _ text: LocalizedStringKey) {
        self.number = number
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(SamTheme.night)
                .frame(width: 22, height: 22)
                .background(Circle().fill(SamTheme.orbPale))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            Text(text).font(.system(size: 15)).foregroundStyle(SamTheme.ink)
        }
        .padding(.vertical, 2)
    }
}
