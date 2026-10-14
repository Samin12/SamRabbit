import SamRabbitKit
import SwiftUI
import UIKit
import WidgetKit

/// Every widget face at its real size, with this iPhone's latest data (Settings > Widget gallery).
struct WidgetGalleryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let snapshot = WidgetGallery.snapshot(model.summary, fetchedAt: model.summaryDate, paired: model.isPaired)
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("Long-press the Home Screen, tap Edit > Add Widget and search for SamRabbit. Lock Screen widgets and the Ask SamRabbit control are in the same places.")
                    .font(.system(size: 14))
                    .foregroundStyle(SamTheme.muted)
                ForEach(WidgetGallery.items) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(item.title.uppercased()).font(SamTheme.eyebrow).tracking(0.5).foregroundStyle(SamTheme.faint)
                        item.view(snapshot)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(16)
        }
        .samScreen()
        .navigationTitle("Widgets")
    }
}

enum WidgetGallery {
    struct Item: Identifiable {
        let id: String
        let title: String
        let size: CGSize
        let face: (WidgetSnapshot) -> AnyView

        @MainActor func view(_ snapshot: WidgetSnapshot) -> AnyView { face(snapshot) }
    }

    /// iPhone 16/17/18 Pro widget sizes in points.
    static let small = CGSize(width: 170, height: 170)
    static let medium = CGSize(width: 364, height: 170)
    static let large = CGSize(width: 364, height: 382)

    @MainActor static let items: [Item] = [
        Item(id: "small", title: "Small · status", size: small) { snapshot in
            AnyView(WidgetChrome(standalone: true, size: small) { StatusSmallFace(snapshot: snapshot) })
        },
        Item(id: "medium-tasks", title: "Medium · Tasks", size: medium) { snapshot in
            AnyView(WidgetChrome(standalone: true, size: medium) { TasksMediumFace(snapshot: snapshot) })
        },
        Item(id: "medium-upnext", title: "Medium · Up next", size: medium) { snapshot in
            AnyView(WidgetChrome(standalone: true, size: medium) { UpNextMediumFace(snapshot: snapshot) })
        },
        Item(id: "large-dashboard", title: "Large · Dashboard", size: large) { snapshot in
            AnyView(WidgetChrome(standalone: true, size: large) { DashboardLargeFace(snapshot: snapshot) })
        },
        Item(id: "lock-screen", title: "Lock Screen", size: CGSize(width: 364, height: 210)) { snapshot in
            AnyView(LockScreenPreview(snapshot: snapshot))
        },
        Item(id: "talk", title: "Talk · Lock Screen and Live Activity", size: CGSize(width: 364, height: 330)) { _ in
            AnyView(TalkPreview())
        },
    ]

    static func snapshot(_ summary: MobileSummary?, fetchedAt: Date?, paired: Bool) -> WidgetSnapshot {
        guard paired, let summary else { return .sample() }
        return WidgetSnapshot(date: .now, summary: summary, fetchedAt: fetchedAt ?? .now, paired: true)
    }
}

/// The three Lock Screen faces over a wallpaper-like gradient, in the system's vibrant white.
struct LockScreenPreview: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(spacing: 14) {
            InlineFace(snapshot: snapshot)
                .font(.system(size: 15, weight: .medium))
            Text(Date.now.formatted(.dateTime.hour().minute()))
                .font(.system(size: 64, weight: .semibold, design: .rounded))
            HStack(spacing: 14) {
                NeedsYouCircularFace(snapshot: snapshot)
                    .frame(width: 66, height: 66)
                NextEventRectangularFace(snapshot: snapshot)
                    .frame(width: 168, height: 70)
                    .padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)))
            }
        }
        .foregroundStyle(.white)
        .padding(.vertical, 22)
        .frame(width: 364)
        .background {
            LinearGradient(colors: [Color(hex: 0x1C2F5C), Color(hex: 0x35246B), Color(hex: 0x0D1730)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

/// Talk's Lock Screen widgets, its Live Activity on the Lock Screen and the Dynamic Island expanded, with a
/// made-up conversation.
struct TalkPreview: View {
    private let state = TalkActivityState(phase: .speaking,
                                          line: "Okay, I started the release notes for build 2.4. Anything else?")

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                // Outside a widget `AccessoryWidgetBackground` draws nothing: the Lock Screen's backing, drawn here.
                TalkCircularFace()
                    .frame(width: 66, height: 66)
                    .background(Circle().fill(.white.opacity(0.12)))
                TalkRectangularFace()
                    .frame(width: 168, height: 66)
                    .padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)))
            }
            TalkActivityLockFace(state: state, startedAt: .now.addingTimeInterval(-83))
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(hex: 0x0B1324).opacity(0.88)))
                .padding(.horizontal, 10)
            TalkIslandExpandedFace(state: TalkActivityState(phase: .listening, line: "“What's next on my calendar?”"))
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 40, style: .continuous).fill(.black))
                .padding(.horizontal, 10)
        }
        .foregroundStyle(.white)
        .padding(.vertical, 20)
        .frame(width: 364)
        .background {
            LinearGradient(colors: [Color(hex: 0x1C2F5C), Color(hex: 0x35246B), Color(hex: 0x0D1730)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

/// Writes every widget face to PNG (`-SamRabbitRenderWidgets` launch argument) into
/// Documents/renders, for screenshots when widgets cannot be added to the simulator's Home Screen.
enum RenderHarness {
    @MainActor
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-SamRabbitRenderWidgets") else { return }
        let cache = SummaryCache.shared.load()
        let snapshot = WidgetGallery.snapshot(cache?.summary, fetchedAt: cache?.savedAt, paired: BridgeAccount.shared.isPaired)
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("renders", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for item in WidgetGallery.items {
            let renderer = ImageRenderer(content: item.view(snapshot).padding(12).background(Color(hex: 0x05070B)))
            renderer.scale = 3
            if let image = renderer.uiImage, let data = image.pngData() {
                try? data.write(to: folder.appendingPathComponent("widget-\(item.id).png"))
            }
        }
        try? Data("done".utf8).write(to: folder.appendingPathComponent("DONE"))
    }
}
