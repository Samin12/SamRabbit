import AppKit
import SwiftUI

// The Agent Dock's look: one neutral liquid glass whatever the Mac or the page behind is set to (white text with a muted
// secondary, the orb's blue as the only accent, red only for errors), rounded 18–22 pt, no shadow (each window is
// exactly its glass; the edge is drawn: a dark hairline outside, a bright line inside, so it reads on a white page
// and on a black one alike).

enum DockPalette {
    static let ink = Palette.ink
    static let secondary = Palette.ink.opacity(0.64)
    static let tertiary = Palette.ink.opacity(0.42)
    static let accent = Palette.orb
    static let accentText = Palette.pale
    static let accentFill = LinearGradient(colors: [Color(red: 0.16, green: 0.51, blue: 1), Color(red: 0.1, green: 0.42, blue: 0.9)],
                                           startPoint: .top, endPoint: .bottom)
    static let error = Color(red: 1, green: 0.45, blue: 0.43)
    static let control = Color.white.opacity(0.09)
    static let controlHover = Color.white.opacity(0.15)
    static let hairline = Color.white.opacity(0.09)
}

/// How the dock draws its glass. Live: macOS 26's Liquid Glass when available, else `NSVisualEffectView` (.hudWindow);
/// `defaults write <bundle id> AgentDockGlass hud|liquid` or `SAMRABBIT_DOCK_GLASS` picks one. Snapshots (the dev
/// renderer, which cannot sample the screen) blur a backdrop picture instead.
struct DockRender {
    enum Glass: String {
        case liquid, hud
    }

    var glass: Glass = .hud
    var backdrop: NSImage?
    var canvas: CGSize = .zero
    var isSnapshot: Bool { backdrop != nil }

    static let canvasSpace = "dockCanvas"

    static func liveGlass() -> Glass {
        let wanted = ProcessInfo.processInfo.environment["SAMRABBIT_DOCK_GLASS"]
            ?? UserDefaults.standard.string(forKey: "AgentDockGlass")
        if let wanted, let glass = Glass(rawValue: wanted.lowercased()) {
            if glass == .liquid, #unavailable(macOS 26) { return .hud }
            return glass
        }
        if #available(macOS 26, *) { return .liquid }
        return .hud
    }
}

private struct DockRenderKey: EnvironmentKey {
    static let defaultValue = DockRender()
}

extension EnvironmentValues {
    var dockRender: DockRender {
        get { self[DockRenderKey.self] }
        set { self[DockRenderKey.self] = newValue }
    }
}

/// The glass behind the pill, the panel and the voice bar.
struct DockGlass<S: InsettableShape>: View {
    let shape: S
    /// 1 = the pill; the panel is a little firmer, because it is read.
    var firmness: Double = 1
    @Environment(\.dockRender) private var render

    var body: some View {
        ZStack {
            material
            shape.fill(LinearGradient(colors: [Color(red: 0.12, green: 0.135, blue: 0.17).opacity(tint * 0.9),
                                               Color(red: 0.045, green: 0.055, blue: 0.08).opacity(tint)],
                                      startPoint: .top, endPoint: .bottom))
            // A soft sheen across the top, like light on a pane.
            shape.fill(LinearGradient(colors: [Color.white.opacity(0.075), Color.white.opacity(0)],
                                      startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.5)))
            // The edge: a dark hairline out, a bright line in (brighter at the top).
            shape.strokeBorder(Color.black.opacity(0.32), lineWidth: 1)
            shape.inset(by: 1).strokeBorder(LinearGradient(colors: [Color.white.opacity(0.26), Color.white.opacity(0.07),
                                                                    Color.white.opacity(0.11)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    /// How dark the tint over the material is: the live materials are already dark, a blurred picture is not.
    private var tint: Double {
        let base: Double
        if render.isSnapshot {
            base = 0.64
        } else {
            switch render.glass {
            case .liquid: base = 0.42
            case .hud: base = 0.16
            }
        }
        return min(0.92, base * firmness)
    }

    @ViewBuilder private var material: some View {
        if let backdrop = render.backdrop {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named(DockRender.canvasSpace))
                Image(nsImage: backdrop)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: render.canvas.width, height: render.canvas.height)
                    .offset(x: -frame.minX, y: -frame.minY)
                    .blur(radius: 34)
                    .saturation(0.8)
            }
            .clipShape(shape)
        } else if render.glass == .liquid {
            if #available(macOS 26, *) {
                Color.clear.glassEffect(.regular.tint(Color.black.opacity(0.18)), in: shape)
            } else {
                DockVisualEffect().clipShape(shape)
            }
        } else {
            DockVisualEffect().clipShape(shape)
        }
    }
}

/// `NSVisualEffectView` (.hudWindow, behind the window): the dark frosted material of HUD panels.
struct DockVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: the orb mark

/// The SamRabbit orb at mark size (OrbRenderer, the R1's math): still at rest, it moves gently for a moment when
/// something changes, and pulses with the voice level while listening. Frames are rendered once per size and played
/// back and forth, so a running animation costs a few image swaps a second, and nothing at rest.
struct DockOrbMark: View {
    let size: CGFloat
    var moving = false
    var lively = false
    var level: CGFloat = 0
    var dim = false

    var body: some View {
        Group {
            if moving || lively {
                TimelineView(.animation(minimumInterval: 1 / 24)) { context in
                    frame(DockOrbFrames.index(at: context.date, lively: lively))
                }
            } else {
                frame(0)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(1 + min(1, max(0, level)) * 0.22)
        .animation(.easeOut(duration: 0.12), value: level)
        .opacity(dim ? 0.5 : 1)
        .saturation(dim ? 0.3 : 1)
    }

    private func frame(_ index: Int) -> some View {
        let frames = DockOrbFrames.frames(points: size, lively: lively)
        return Group {
            if frames.isEmpty {
                Circle().fill(Palette.orb).padding(size * 0.2)
            } else {
                Image(nsImage: frames[index % frames.count]).resizable().interpolation(.high)
            }
        }
    }
}

enum DockOrbFrames {
    static let count = 24
    private static var cache: [String: [NSImage]] = [:]

    static func frames(points: CGFloat, lively: Bool) -> [NSImage] {
        let pixels = max(8, Int((points * 2).rounded()))
        let key = "\(pixels)-\(lively)"
        if let cached = cache[key] { return cached }
        var images: [NSImage] = []
        for index in 0..<count {
            let time = 2.0 + Double(index) * (lively ? 0.16 : 0.11)
            guard let image = OrbRenderer.image(pixels: pixels, radiusFraction: 0.37, centerYFraction: 0.47, time: time,
                                                energy: lively ? 0.42 : 0.14, glow: 0.62) else { break }
            images.append(NSImage(cgImage: image, size: NSSize(width: points, height: points)))
        }
        cache[key] = images
        return images
    }

    /// Back and forth through the frames (a time loop would jump at the wrap).
    static func index(at date: Date, lively: Bool) -> Int {
        let fps = lively ? 18.0 : 12.0
        let step = Int(date.timeIntervalSinceReferenceDate * fps) % (2 * count - 2)
        return step < count ? step : 2 * count - 2 - step
    }
}

// MARK: controls

/// A round glass button with an SF Symbol (mic, stop, end…).
struct DockRoundButton: View {
    let symbol: String
    let size: CGFloat
    var tint: Color = DockPalette.ink
    var fill: Color = DockPalette.control
    var badge = false
    var help = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(hover ? DockPalette.controlHover : fill)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: size, height: size)
                if badge {
                    Circle()
                        .fill(Palette.pale)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.75))
                        .frame(width: size * 0.24, height: size * 0.24)
                        .offset(x: -size * 0.04, y: size * 0.04)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// A capsule button: `.accent` for the recommended action, `.plain` for the rest.
struct DockCapsuleButton: View {
    enum Style {
        case accent, plain, quiet
    }

    let title: String
    var symbol: String?
    var style: Style = .plain
    var scale: CGFloat = 1
    var disabled = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5 * scale) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10.5 * scale, weight: .semibold)) }
                Text(title).font(.system(size: 12 * scale, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(style == .quiet ? DockPalette.secondary : DockPalette.ink)
            .padding(.horizontal, 11 * scale)
            .padding(.vertical, 5.5 * scale)
            .background(background)
            .contentShape(Capsule())
            .opacity(disabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hover = $0 }
    }

    @ViewBuilder private var background: some View {
        switch style {
        case .accent:
            Capsule().fill(DockPalette.accentFill)
                .overlay(Capsule().strokeBorder(Color.white.opacity(hover ? 0.32 : 0.18), lineWidth: 1))
                .brightness(hover ? 0.05 : 0)
        case .plain:
            Capsule().fill(hover ? DockPalette.controlHover : DockPalette.control)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        case .quiet:
            Capsule().fill(hover ? DockPalette.control : Color.clear)
        }
    }
}

/// Lays children out in rows, wrapping when the width runs out (option chips, approval buttons).
struct DockFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += line + lineSpacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += line + lineSpacing
                x = bounds.minX
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

// MARK: text input

/// A text field for the dock: Enter sends, ⇧Enter starts a new line, Esc lets go of the keys; it grows up to a few
/// lines. An AppKit field (NSTextField) so it can take the keys in a panel that never activates the app. Snapshots
/// draw the same text with SwiftUI (AppKit views can't be rendered off screen).
struct DockTextInput: View {
    @Binding var text: String
    let placeholder: String
    let focus: DockFocus
    @ObservedObject var ui: DockUIState
    var fontSize: CGFloat = 13
    var maxLines = 5
    var onSubmit: () -> Void
    var onEscape: () -> Void = {}
    @Environment(\.dockRender) private var render

    var body: some View {
        if render.isSnapshot {
            Text(text.isEmpty ? placeholder : text)
                .font(.system(size: fontSize))
                .foregroundStyle(text.isEmpty ? DockPalette.tertiary : DockPalette.ink)
                .lineLimit(maxLines)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 2)
                .overlay(alignment: .leading) {
                    if ui.editing == focus {
                        Rectangle().fill(DockPalette.ink).frame(width: 1.5, height: fontSize * 1.25)
                            .offset(x: text.isEmpty ? 1 : textWidth + 3)
                    }
                }
        } else {
            DockFieldRepresentable(text: $text, placeholder: placeholder, focus: focus, ui: ui, fontSize: fontSize,
                                   maxLines: maxLines, onSubmit: onSubmit, onEscape: onEscape)
        }
    }

    private var textWidth: CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width
    }
}

final class DockField: NSTextField {
    var onFocus: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?(true) }
        return became
    }
}

struct DockFieldRepresentable: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focus: DockFocus
    @ObservedObject var ui: DockUIState
    let fontSize: CGFloat
    let maxLines: Int
    let onSubmit: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> DockField {
        let field = DockField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.textColor = NSColor(Palette.ink)
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.onFocus = { [weak coordinator = context.coordinator] on in coordinator?.focusChanged(on) }
        return field
    }

    func updateNSView(_ field: DockField, context: Context) {
        context.coordinator.parent = self
        let font = NSFont.systemFont(ofSize: fontSize)
        if field.font != font { field.font = font }
        if field.stringValue != text { field.stringValue = text }
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder, attributes: [.foregroundColor: NSColor(Palette.ink).withAlphaComponent(0.42), .font: font])
        if ui.focusRequest == focus {
            DispatchQueue.main.async {
                guard ui.focusRequest == focus, let window = field.window else { return }
                window.makeKey()
                window.makeFirstResponder(field)
                if let editor = field.currentEditor() { editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0) }
                ui.focusRequest = nil
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DockField, context: Context) -> CGSize? {
        let width = max(40, proposal.width ?? 240)
        let font = NSFont.systemFont(ofSize: fontSize)
        let line = ceil(font.ascender - font.descender + font.leading)
        let sample = text.isEmpty ? "M" : (text.hasSuffix("\n") ? text + "M" : text)
        let rect = (sample as NSString).boundingRect(with: NSSize(width: width - 5, height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                     attributes: [.font: font])
        let height = min(CGFloat(maxLines) * line, max(line, ceil(rect.height))) + 2
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DockFieldRepresentable

        init(_ parent: DockFieldRepresentable) { self.parent = parent }

        func focusChanged(_ on: Bool) {
            let focus = parent.focus
            let ui = parent.ui
            DispatchQueue.main.async {
                if on {
                    ui.editing = focus
                } else if ui.editing == focus {
                    ui.editing = nil
                }
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            focusChanged(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    parent.text = control.stringValue
                } else {
                    parent.text = control.stringValue
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertNewlineIgnoringFieldEditor(nil)
                parent.text = control.stringValue
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                control.window?.makeFirstResponder(nil)
                parent.onEscape()
                return true
            default:
                return false
            }
        }
    }
}
