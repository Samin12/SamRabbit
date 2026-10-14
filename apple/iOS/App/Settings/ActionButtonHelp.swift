import SamRabbitKit
import SwiftUI

/// Settings > Action Button: where to set the iPhone's and the Apple Watch Ultra's Action Button so
/// it opens SamRabbit in a live conversation (Talk) or at Ask with dictation listening. Apps can't set
/// the button themselves; this says exactly where to do it.
struct ActionButtonHelpView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                HelpStep(1, "Open **Settings** > **Action Button**.")
                HelpStep(2, "Swipe to **Controls**, tap **Choose a Control…** and pick **SamRabbit** > **Talk to SamRabbit**.")
                HelpStep(3, "**Press and hold** the Action Button. SamRabbit opens in a live conversation, like your R1: just talk. Press it again to send at once or to interrupt; it keeps going with the screen locked.")
            } header: {
                Text("iPhone")
            } footer: {
                Text("Or pick **Ask SamRabbit** for Ask with dictation (say a new task, then tap **Start**). Under **Shortcut** > **Choose a Shortcut…** > **SamRabbit** the same two are **Talk** and **Ask by Voice**.")
            }
            .listRowBackground(SamTheme.glass2)

            Section {
                HelpStep(1, "On the watch, open **Settings** > **Action Button**.")
                HelpStep(2, "Tap **Action** and choose **Control**. Go back, tap **Control** (it says **Configure** until one is set) and pick **SamRabbit** > **Ask SamRabbit**.")
                HelpStep(3, "**Press** the Action Button once. SamRabbit opens on the watch with dictation on. Say what to do, then tap **Done**.")
            } header: {
                Text("Apple Watch Ultra")
            } footer: {
                Text("Install the watch app first: Watch app on this iPhone > SamRabbit > Install. The watch connects through this iPhone by itself. Newer watchOS may say **Choose Action** instead of **Action**.")
            }
            .listRowBackground(SamTheme.glass2)

            Section {
                Button {
                    model.startTalk()
                } label: {
                    Label("Try Talk here", systemImage: "waveform")
                }
                Button {
                    model.sheet = .ask(prefill: "", listen: UUID())
                } label: {
                    Label("Try Ask here", systemImage: "mic.fill")
                }
            } footer: {
                Text("Opens Talk or Ask the way the Action Button does.")
            }
            .listRowBackground(SamTheme.glass2)
        }
        .samScreen()
        .navigationTitle("Action Button")
        .navigationBarTitleDisplayMode(.inline)
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
