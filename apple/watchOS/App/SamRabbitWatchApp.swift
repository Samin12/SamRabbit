import SamRabbitKit
import SwiftUI

@main
struct SamRabbitWatchApp: App {
    @State private var model: WatchModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        PhoneLink.shared.start()
        VoiceFormat.removeLeftovers() // recordings a stopped run left behind
        _model = State(initialValue: WatchModel())
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(model)
                .onOpenURL { model.handle(url: $0) }
                .task {
                    ComplicationRenderHarness.runIfRequested()
                    await Self.runIntentIfRequested()
                }
        }
        // Opened (launch, from the background, the Action Button, Siri, a complication): straight into a live
        // conversation. Wrist down keeps it going (the app stays in front, background audio keeps the microphone);
        // the wrist coming back up (inactive -> active) goes on with it; the Crown pauses it after the reply.
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                model.start()
                model.sceneActive()
            case .background:
                model.stop()
                model.sceneLeft()
            default:
                break
            }
        }
    }
}

extension SamRabbitWatchApp {
    /// `-SamRabbitIntent ask` (or another `WatchDestination`): runs the Action Button's intent at
    /// launch, for the simulator walkthrough. A watch simulator has no Action Button to press.
    @MainActor
    static func runIntentIfRequested() async {
        guard let raw = UserDefaults.standard.string(forKey: "SamRabbitIntent"),
              let destination = WatchDestination(rawValue: raw) else { return }
        _ = try? await OpenSamRabbitWatchIntent(destination).perform()
    }
}

/// The pages (Digital Crown / swipe): the conversation first, then the morning brief (while there is one), Needs
/// you, Working, Up next and Quick; or the "pair on your iPhone" screen.
struct WatchRootView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.paired {
                NavigationStack {
                    TabView(selection: $model.page) {
                        AssistantPage().tag(WatchPage.status)
                        // The morning brief, while there is one today.
                        if model.showsBrief { BriefPage().tag(WatchPage.brief) }
                        NeedsYouPage().tag(WatchPage.needs)
                        WorkingPage().tag(WatchPage.working)
                        UpNextPage().tag(WatchPage.upnext)
                        QuickPage().tag(WatchPage.quick)
                    }
                    .tabViewStyle(.verticalPage)
                    .navigationDestination(for: ThreadRoute.self) { route in
                        ThreadDetailView(route: route)
                    }
                }
                // Every text the watch takes comes from here: voice only, never a keyboard.
                .sheet(item: $model.voice) { request in
                    VoiceCaptureView(request: request, model: model)
                }
            } else {
                UnpairedView()
            }
        }
        .tint(SamTheme.accent)
        .preferredColorScheme(.dark)
    }
}

struct ThreadRoute: Hashable {
    var threadId: String
    var title: String
}

/// Shown until the iPhone has sent a pairing.
struct UnpairedView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                OrbView(mood: .offline, animated: false).frame(width: 64, height: 64).padding(.top, 8)
                Text("Pair on your iPhone").font(.system(size: 17, weight: .semibold)).foregroundStyle(SamTheme.ink)
                Text("Open SamRabbit on your iPhone and pair it with your Mac. Your watch connects by itself.")
                    .font(.system(size: 13))
                    .foregroundStyle(SamTheme.muted)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await model.connect() }
                } label: {
                    CapsuleFace(title: model.connecting ? "Checking…" : "Check again", symbol: "iphone",
                                colors: [SamTheme.orb2, SamTheme.orb], height: 40, busy: model.connecting)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(.horizontal, 4)
        }
        .background(SamTheme.night.ignoresSafeArea())
        .withBanner()
    }
}
