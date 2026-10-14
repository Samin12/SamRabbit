import SamRabbitKit
import SwiftUI

/// The quick-action sheets: Ask (a new task, automatic placement), Note (journal), Generate UI and
/// Open on Mac. Each has a big field, dictation and one primary action.
struct ComposerSheet: View {
    enum Kind { case ask, note, generate, openOnMac }

    let kind: Kind
    var prefill = ""
    /// Submit the prefilled text right away (a link's prompt the person already confirmed).
    var startAtOnce = false
    /// Start dictation as the sheet opens, and again whenever this changes (the Action Button, the
    /// Ask control and the widgets' Ask buttons).
    var listen: UUID?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var working = false
    @State private var artifact: GeneratedArtifact?
    @State private var dictation = SpeechDictation()
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        OrbView(mood: working ? .working : dictation.isListening ? .live : .idle, halo: false)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(heading).font(.system(size: 20, weight: .semibold))
                            Text(dictation.isListening ? listeningHint : explainer)
                                .font(.system(size: 13.5))
                                .foregroundStyle(dictation.isListening ? SamTheme.orbPale : SamTheme.muted)
                                .contentTransition(.opacity)
                                .animation(.smooth, value: dictation.isListening)
                        }
                    }
                    .padding(.top, 6)
                    VStack(alignment: .trailing, spacing: 10) {
                        TextField(placeholder, text: $text, axis: .vertical)
                            .focused($focused)
                            .lineLimit(kind == .openOnMac ? 1...2 : 4...10)
                            .font(.system(size: 17))
                            .textInputAutocapitalization(kind == .openOnMac ? .never : .sentences)
                            .autocorrectionDisabled(kind == .openOnMac)
                            .keyboardType(kind == .openOnMac ? .URL : .default)
                            .submitLabel(kind == .openOnMac ? .go : .return)
                            .onSubmit { if kind == .openOnMac { submit() } }
                        HStack {
                            if kind == .openOnMac {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(["Google Chrome", "T3 Code", "Notes", "Slack", "Calendar", "Messages"], id: \.self) { app in
                                            Button(app) { text = app }
                                                .font(.system(size: 13, weight: .medium))
                                                .buttonStyle(.glass)
                                                .controlSize(.small)
                                        }
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                            DictationButton(text: $text, dictation: dictation)
                        }
                    }
                    .glassCard(radius: 22, padding: 14)
                    if kind == .generate, let artifact { GeneratedResultCard(artifact: artifact) }
                    if kind == .generate, working, artifact == nil {
                        HStack(spacing: 12) {
                            ProgressView().tint(SamTheme.orbPale)
                            Text("Your Mac is designing it… this takes about half a minute.")
                                .font(.system(size: 14)).foregroundStyle(SamTheme.ink2)
                        }
                        .glassCard(radius: 18, padding: 14)
                    }
                }
                .padding(.horizontal, 18)
            }
            .samScreen()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        submit()
                    } label: {
                        if working { ProgressView() } else { Text(actionTitle).fontWeight(.semibold) }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                }
            }
        }
        .presentationDetents(kind == .generate && artifact != nil ? [.large] : [.medium, .large])
        .presentationBackground(.clear)
        .onAppear {
            if text.isEmpty { text = prefill }
            if startAtOnce, !text.isEmpty, artifact == nil, !working {
                submit()
            } else if listen == nil {
                focused = true // with the mic on, no keyboard: tap the field to type instead
            }
        }
        .task(id: listen) {
            guard listen != nil, !working, !dictation.isListening else { return }
            focused = false
            await dictation.start($text)
        }
    }

    var listeningHint: String {
        switch kind {
        case .ask: "Listening… say what to do, then tap Start."
        case .note: "Listening… say your note, then tap Add."
        case .generate: "Listening… describe it, then tap Generate."
        case .openOnMac: "Listening… say an app or a site."
        }
    }

    var heading: String {
        switch kind {
        case .ask: "Ask SamRabbit"
        case .note: "Journal note"
        case .generate: "Generate a UI"
        case .openOnMac: "Open on Mac"
        }
    }

    var explainer: String {
        switch kind {
        case .ask: "Starts a T3 Code task. SamRabbit picks the project."
        case .note: "Added to today's Heptabase journal, word for word."
        case .generate: "A chart, dashboard or diagram, made on your Mac."
        case .openOnMac: "An app name or a link."
        }
    }

    var placeholder: String {
        switch kind {
        case .ask: "What should SamRabbit do?"
        case .note: "What happened?"
        case .generate: "Show my focus hours this week as a bar chart"
        case .openOnMac: "Notes, or https://…"
        }
    }

    var actionTitle: String {
        switch kind {
        case .ask: "Start"
        case .note: "Add"
        case .generate: artifact == nil ? "Generate" : "Again"
        case .openOnMac: "Open"
        }
    }

    func submit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !working else { return }
        working = true
        focused = false
        dictation.stop()
        Task {
            defer { working = false }
            switch kind {
            case .ask:
                if await model.ask(value) { dismiss() }
            case .note:
                if await model.note(value) { dismiss() }
            case .openOnMac:
                let link = value.lowercased().hasPrefix("http") || value.contains(".") && !value.contains(" ")
                let url = link && !value.lowercased().hasPrefix("http") ? "https://" + value : value
                if await model.openOnMac(app: link ? nil : value, url: link ? url : nil) { dismiss() }
            case .generate:
                artifact = nil
                do {
                    guard let client = model.client else { throw BridgeError.notPaired }
                    let id = try await client.generateUI(prompt: value)
                    let result = try await client.waitForArtifact(id)
                    withAnimation(.smooth) { artifact = result }
                    if result.status == .failed {
                        model.show(.failure, "Couldn't make that one", detail: result.errorMessage)
                    } else {
                        Haptics.success()
                    }
                } catch {
                    model.fail(error)
                }
            }
        }
    }
}

/// A generated UI: its preview picture and a button to open it interactive.
struct GeneratedResultCard: View {
    let artifact: GeneratedArtifact
    @State private var showViewer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if artifact.status == .ready {
                Button { showViewer = true } label: {
                    ArtifactImage(artifactId: artifact.artifactId, aspect: aspect)
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(artifact.title.isEmpty ? "Your visual" : artifact.title).font(.system(size: 17, weight: .semibold))
                if !artifact.summary.isEmpty {
                    Text(artifact.summary).font(.system(size: 14)).foregroundStyle(SamTheme.ink2)
                }
            }
            if artifact.status == .ready {
                Button {
                    showViewer = true
                } label: {
                    Label("Open interactive", systemImage: "hand.tap").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
        .glassCard(tint: SamTheme.pink)
        .fullScreenCover(isPresented: $showViewer) {
            GeneratedUIViewer(artifactId: artifact.artifactId, title: artifact.title)
        }
    }

    var aspect: CGFloat {
        guard let w = artifact.width, let h = artifact.height, w > 0, h > 0 else { return 1.5 }
        return CGFloat(w) / CGFloat(h)
    }
}

/// "+" in Tasks: a new task with a project picker (automatic placement by default).
/// A new T3 Code task: what to do, which agent runs it (Claude or Codex, and the model; automatic: the project's
/// own) and where (automatic placement, or a project). The agents and models are what T3 offers (`/inbox/targets`);
/// an older bridge without them offers the projects only.
struct NewTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var projectId: String?
    @State private var agent: String?
    @State private var modelId: String?
    @State private var working = false
    @FocusState private var focused: Bool

    var projectChoices: [TaskProject] {
        if let targets = model.targets, !targets.projects.isEmpty {
            return targets.projects.map { TaskProject(id: $0.id, name: $0.title) }
        }
        return model.projects
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What should be done?", text: $text, axis: .vertical)
                        .focused($focused)
                        .lineLimit(4...10)
                    HStack {
                        Spacer()
                        DictationButton(text: $text)
                    }
                    .listRowBackground(Color.clear)
                }
                .listRowBackground(SamTheme.glass2)
                if let targets = model.targets, !targets.agents.isEmpty {
                    Section("Agent") {
                        Picker("Agent", selection: $agent) {
                            Text("Automatic").tag(String?.none)
                            ForEach(targets.agents) { choice in
                                Text(choice.label).tag(Optional(choice.id))
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("new-task-agent")
                        if let chosen = targets.agent(agent), !chosen.models.isEmpty {
                            Picker("Model", selection: $modelId) {
                                ForEach(chosen.models) { option in
                                    Text(option.label).tag(Optional(option.id))
                                }
                            }
                        }
                    }
                    .listRowBackground(SamTheme.glass2)
                }
                Section("Project") {
                    Picker("Project", selection: $projectId) {
                        Label("Automatic", systemImage: "sparkles").tag(String?.none)
                        ForEach(projectChoices) { project in
                            Text(project.name).tag(Optional(project.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .listRowBackground(SamTheme.glass2)
            }
            .onChange(of: agent) { _, chosen in
                // The model this agent ran last (the Mac's default for it), else its first.
                let models = model.targets?.agent(chosen)?.models ?? []
                let preferred = model.targets?.defaultChoice.agent == chosen ? model.targets?.defaultChoice.model : nil
                modelId = models.first { $0.id == preferred }?.id ?? models.first?.id
            }
            .samScreen()
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        working = true
                        let choice = InboxTargets.Choice(projectId: projectId, agent: agent,
                                                         model: agent == nil ? nil : modelId)
                        Task {
                            if await model.newTask(text, choice: choice) { dismiss() }
                            working = false
                        }
                    } label: {
                        if working { ProgressView() } else { Text("Start").fontWeight(.semibold) }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                }
            }
            .task {
                await model.loadTargets()
                if model.targets == nil { await model.loadProjects() }
            }
            .onAppear { focused = true }
        }
    }
}
