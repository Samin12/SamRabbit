import SamRabbitKit
import SwiftUI

/// Make task on a morning-brief item: the words the T3 task starts with, before it starts. They were written from
/// an email (anyone can write one, and the Mac's model read it), so they are shown here, editable, and only these
/// words go to the Mac as the task's `text`: an agent never runs instructions he didn't see. The Mac adds which
/// email it came from.
struct BriefTaskSheet: View {
    let item: BriefingItem
    let verb: BriefingAction
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var working = false

    private var words: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What should the agent do?", text: $text, axis: .vertical)
                        .lineLimit(4...12)
                        .accessibilityIdentifier("brief-task-text")
                } header: {
                    Text("The task starts with")
                } footer: {
                    Label("Written from an email: read it before it starts. The agent gets exactly these words, and "
                          + "which email they came from.", systemImage: "envelope.badge.shield.half.filled")
                        .font(.system(size: 13))
                        .foregroundStyle(SamTheme.amber)
                        .accessibilityIdentifier("brief-task-warning")
                }
                .listRowBackground(SamTheme.glass2)
            }
            .samScreen()
            .navigationTitle("New T3 task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cancel")
                        .accessibilityIdentifier("brief-task-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        working = true
                        let words = words
                        Task {
                            if await model.act(on: item, verb, options: ["text": .string(words)]) { dismiss() }
                            working = false
                        }
                    } label: {
                        if working { ProgressView() } else { Text("Start").fontWeight(.semibold) }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(words.isEmpty || working)
                    .accessibilityIdentifier("brief-task-start")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(working)
        .onAppear { if text.isEmpty { text = item.taskPrompt } }
    }
}
