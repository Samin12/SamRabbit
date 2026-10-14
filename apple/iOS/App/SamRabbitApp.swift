import BackgroundTasks
import SamRabbitKit
import SwiftUI

@main
struct SamRabbitApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        WatchLink.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { model.handle(url: $0) }
                .task { RenderHarness.runIfRequested() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.consumePendingRoute()
                model.startRefreshing()
            case .background:
                model.stopRefreshing()
                BackgroundRefresh.schedule()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(SamRabbit.backgroundRefreshTask)) {
            await BackgroundRefresh.run()
        }
    }
}

/// The five tabs and everything presented over them.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        @Bindable var talk = model.talk
        TabView(selection: $model.tab) {
            Tab("Home", systemImage: "circle.hexagongrid.fill", value: AppTab.home) {
                NavigationStack(path: $model.homePath) { HomeView().destinations() }
            }
            Tab("Chats", systemImage: "bubble.left.and.text.bubble.right.fill", value: AppTab.chats) {
                NavigationStack(path: $model.chatsPath) { ChatsView().destinations() }
            }
            .badge(model.summary?.r1.live == true ? Text("Live") : nil)
            Tab("Tasks", systemImage: "checklist", value: AppTab.tasks) {
                NavigationStack(path: $model.tasksPath) { TasksView().destinations() }
            }
            .badge(model.summary?.t3.needsYou ?? 0)
            Tab("Mac", systemImage: "macbook", value: AppTab.mac) {
                NavigationStack(path: $model.macPath) { MacView().destinations() }
            }
            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                NavigationStack { SettingsView() }
            }
        }
        .talkAccessory(talk.active && !talk.presented)
        .tint(SamTheme.accent)
        .preferredColorScheme(.dark)
        .sheet(item: $model.sheet) { sheet in
            SheetView(sheet: sheet)
                .environment(model)
        }
        .fullScreenCover(isPresented: $talk.presented) {
            TalkView()
                .environment(model)
                .overlay(alignment: .top) { ToastOverlay().environment(model) }
        }
        .overlay(alignment: .top) { ToastOverlay() }
    }
}

extension View {
    /// The pushed screens every tab can reach.
    func destinations() -> some View {
        navigationDestination(for: ThreadRoute.self) { ThreadDetailView(threadId: $0.threadId) }
            .navigationDestination(for: ConversationRoute.self) {
                ConversationView(conversationId: $0.conversationId, initialTitle: $0.title)
            }
    }
}

/// The sheet for an `AppSheet`.
struct SheetView: View {
    let sheet: AppSheet

    var body: some View {
        switch sheet {
        case .ask(let prefill, let listen): ComposerSheet(kind: .ask, prefill: prefill, listen: listen)
        case .note(let prefill, let listen): ComposerSheet(kind: .note, prefill: prefill, listen: listen)
        case .generate(let prefill, let start): ComposerSheet(kind: .generate, prefill: prefill, startAtOnce: start)
        case .openOnMac(let prefill): ComposerSheet(kind: .openOnMac, prefill: prefill)
        case .newTask: NewTaskSheet()
        case .pair(let link): PairConfirmSheet(link: link)
        case .manualPair: NavigationStack { ManualPairView() }
        case .confirm(let action): LinkConfirmSheet(action: action)
        }
    }
}

/// Toasts slide in under the status bar and leave on their own.
struct ToastOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(toast.id)
                    .task(id: toast.id) {
                        try? await Task.sleep(for: .seconds(toast.style == .failure ? 4.5 : 2.6))
                        withAnimation(.smooth) { if model.toast?.id == toast.id { model.toast = nil } }
                    }
                    .onTapGesture { withAnimation(.smooth) { model.toast = nil } }
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.25), value: model.toast)
        .padding(.top, 6)
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        let (symbol, color): (String, Color) = switch toast.style {
        case .success: ("checkmark.circle.fill", SamTheme.green)
        case .failure: ("exclamationmark.triangle.fill", SamTheme.amber)
        case .info: ("info.circle.fill", SamTheme.orbPale)
        }
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(SamTheme.ink)
                if let detail = toast.detail {
                    Text(detail).font(.system(size: 13)).foregroundStyle(SamTheme.ink2).lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular.tint(SamTheme.night.opacity(0.5)), in: .rect(cornerRadius: 20))
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
    }
}
