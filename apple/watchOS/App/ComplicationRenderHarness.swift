import SamRabbitKit
import SwiftUI

/// Debug only: `-SamRabbitRenderComplications` renders every complication face with
/// `ImageRenderer` (from the watch's current summary, or the sample) into the app's
/// Documents/renders, for screenshots and reviews without a watch face.
enum ComplicationRenderHarness {
    @MainActor static func runIfRequested() {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "SamRabbitRenderComplications") else { return }
        let cached = SummaryCache.shared.load()
        let snapshot = ComplicationSnapshot(date: .now, summary: cached?.summary ?? .sample(),
                                            fetchedAt: cached?.savedAt ?? .now, paired: true)
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("renders", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let faces: [(String, CGSize, AnyView)] = [
            ("complication-circular", CGSize(width: 50, height: 50),
             AnyView(NeedsYouCircularComplication(snapshot: snapshot))),
            ("complication-corner", CGSize(width: 50, height: 50),
             AnyView(NeedsYouCornerComplication(snapshot: snapshot))),
            ("complication-rectangular", CGSize(width: 186, height: 66),
             AnyView(NextUpRectangularComplication(snapshot: snapshot))),
            ("complication-inline", CGSize(width: 186, height: 22),
             AnyView(StatusInlineComplication(snapshot: snapshot).font(.system(size: 14, weight: .medium)))),
            ("complication-note-circular", CGSize(width: 50, height: 50), AnyView(VoiceNoteCircularComplication())),
            ("complication-note-corner", CGSize(width: 50, height: 50), AnyView(VoiceNoteCornerComplication())),
            ("complication-brief-rectangular", CGSize(width: 186, height: 66),
             AnyView(BriefRectangularComplication(snapshot: snapshot))),
            ("complication-brief-inline", CGSize(width: 186, height: 22),
             AnyView(BriefInlineComplication(snapshot: snapshot).font(.system(size: 14, weight: .medium)))),
        ]
        for (name, size, face) in faces {
            let tile = face
                .frame(width: size.width, height: size.height)
                .padding(10)
                .background(Color.black)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: tile)
            renderer.scale = 3
            if let image = renderer.uiImage, let data = image.pngData() {
                try? data.write(to: folder.appendingPathComponent("\(name).png"))
            }
        }
        #endif
    }
}
