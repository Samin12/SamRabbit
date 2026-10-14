import AppKit
import SwiftUI

/// "Connect ChatGPT…": the Mac's own ChatGPT login for the watch assistant's realtime voice (gpt-realtime on the
/// ChatGPT subscription, like the R1). `POST /v1/assistant/chatgpt/start` (loopback + desktop token) gives a one-time
/// code and the link; Samin opens the link (Open Browser), signs in and types the code; the bridge waits for it and
/// this window reads `GET /v1/assistant/chatgpt/status` until it says connected. Disconnect is
/// `POST /v1/assistant/chatgpt/disconnect`. The code is shown here only, never logged; the tokens stay in the bridge.
enum ChatGPTAPI {
    struct Start: Decodable, Equatable {
        let userCode: String
        let verificationUrl: String
        let expiresAt: String
    }

    struct Login: Decodable, Equatable {
        let state: String
        let userCode: String?
        let verificationUrl: String?
        let expiresAt: String?
        let reason: String?
    }

    struct Status: Decodable, Equatable {
        let connected: Bool
        let plan: String?
        let email: String?
        let reason: String?
        let login: Login?
        /// "codex": the bridge borrows Codex's login on this Mac (read-only) because the Mac has none of its own.
        let source: String?
    }

    struct Failure: Error, Equatable {
        let status: Int
        let code: String?
    }

    private struct ErrorBody: Decodable {
        struct Inner: Decodable { let code: String? }
        let error: Inner?
    }

    static func start() async -> Result<Start, Failure> {
        await call("/v1/assistant/chatgpt/start", method: "POST")
    }

    static func status() async -> Result<Status, Failure> {
        await call("/v1/assistant/chatgpt/status", method: "GET")
    }

    static func disconnect() async -> Result<Status, Failure> {
        await call("/v1/assistant/chatgpt/disconnect", method: "POST")
    }

    private static func call<T: Decodable>(_ path: String, method: String) async -> Result<T, Failure> {
        guard var request = Config.request(Config.api(path), timeout: 40) else {
            return .failure(Failure(status: -1, code: nil))
        }
        request.httpMethod = method
        if method == "POST" {
            request.httpBody = Data("{}".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                let code = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error?.code
                return .failure(Failure(status: status, code: code))
            }
            return .success(try JSONDecoder().decode(T.self, from: data))
        } catch is DecodingError {
            return .failure(Failure(status: 502, code: nil))
        } catch {
            return .failure(Failure(status: 0, code: nil))
        }
    }
}

@MainActor
final class ChatGPTModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case disconnected
        case waiting
        case connected
        case failed(ChatGPTAPI.Failure)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var status: ChatGPTAPI.Status?
    @Published private(set) var code: String?
    @Published private(set) var link: URL?
    @Published private(set) var expiresAt: Date?
    @Published private(set) var notice: String?
    @Published private(set) var now = Date()
    @Published var confirmDisconnect = false
    private var timer: Timer?
    private var ticks = 0
    private var busy = false

    var expired: Bool { expiresAt.map { $0 <= now } ?? false }
    var borrowed: Bool { status?.source == "codex" }
    var account: String {
        let parts = [status?.email, status?.plan.map { "\($0.capitalized) plan" }].compactMap { $0 }
        return parts.isEmpty ? "Your ChatGPT account" : parts.joined(separator: " · ")
    }

    func open() {
        Task { await refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func close() {
        timer?.invalidate()
        timer = nil
    }

    /// While a code is on screen the status is read every 2 s (the bridge finishes the login by itself), otherwise
    /// every 30 s, which keeps the bridge log quiet while the window stays open.
    private func tick() {
        now = Date()
        ticks += 1
        let waiting = phase == .waiting && !expired
        if ticks % (waiting ? 2 : 30) == 0 { Task { await refresh() } }
    }

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        switch await ChatGPTAPI.status() {
        case .success(let value):
            status = value
            // A code on screen wins over "connected": with Codex's login borrowed, Samin may still be giving the
            // Mac a login of its own.
            if let login = value.login, login.state == "waiting", let pending = login.userCode {
                code = pending
                link = login.verificationUrl.flatMap(URL.init(string:))
                expiresAt = PairingModel.date(login.expiresAt)
                phase = .waiting
            } else if value.connected {
                if phase != .connected { Log.write(value.source == "codex" ? "chatgpt via codex" : "chatgpt connected") }
                phase = .connected
                code = nil
                link = nil
            } else {
                if phase == .waiting, let state = value.login?.state, state != "waiting" {
                    notice = state == "expired" ? "The code expired. Get a new one."
                        : "The login didn’t finish (\(value.login?.reason ?? state)). Try again."
                }
                if value.reason == "reconnect_required" { notice = "ChatGPT needs to be connected again." }
                phase = .disconnected
            }
        case .failure(let failure):
            phase = .failed(failure)
        }
    }

    func connect() async {
        notice = nil
        phase = .loading
        switch await ChatGPTAPI.start() {
        case .success(let value):
            code = value.userCode
            link = URL(string: value.verificationUrl)
            expiresAt = PairingModel.date(value.expiresAt)
            phase = .waiting
            Log.write("chatgpt login started")
        case .failure(let failure):
            phase = .failed(failure)
            Log.write("chatgpt login start failed (HTTP \(failure.status))")
        }
    }

    func openBrowser() {
        guard let link, link.scheme == "https" else { return }
        NSWorkspace.shared.open(link)
    }

    func copyCode() {
        guard let code else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    func disconnect() async {
        if case .success = await ChatGPTAPI.disconnect() { Log.write("chatgpt disconnected") }
        await refresh()
    }

    var failureText: (title: String, detail: String, command: String?) {
        guard case .failed(let failure) = phase else { return ("", "", nil) }
        switch (failure.status, failure.code) {
        case (-1, _): return ("SamRabbit isn’t set up yet", "There is no desktop token. Run the installer once:", "companion/desktop/install.sh")
        case (0, _): return ("The bridge isn’t answering", "The SamRabbit bridge on this Mac isn’t running.", "companion/mac-bridge/install.sh")
        case (404, _): return ("Update the bridge", "This bridge is too old to connect ChatGPT. Update it:", "companion/mac-bridge/install.sh")
        case (401, _), (403, _): return ("The bridge didn’t accept SamRabbit", "The desktop token was not accepted. Run:", "companion/desktop/install.sh")
        case (_, "chatgpt_dev_copy"): return ("This is a test copy of the bridge", "Only the installed bridge connects to ChatGPT.", "companion/mac-bridge/install.sh")
        case (_, "chatgpt_unreachable"): return ("ChatGPT isn’t reachable", "Check the Mac’s internet connection and try again.", nil)
        default: return ("Connecting isn’t available", "The bridge answered HTTP \(failure.status).", nil)
        }
    }
}

struct ChatGPTView: View {
    @ObservedObject var model: ChatGPTModel

    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.backgroundTop, Palette.background], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                header
                card
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 470, idealHeight: 520)
        .preferredColorScheme(.dark)
        .alert("Disconnect ChatGPT?", isPresented: $model.confirmDisconnect) {
            Button("Disconnect", role: .destructive) { Task { await model.disconnect() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The watch assistant goes back to Claude until you connect again. Your R1 keeps its own login.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            OrbImage(size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("Connect ChatGPT").font(.system(size: 20, weight: .semibold)).foregroundStyle(Palette.ink)
                Text("Your Apple Watch talks with gpt-realtime on your ChatGPT plan, in the R1’s voice.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    @ViewBuilder private var card: some View {
        VStack(spacing: 14) {
            switch model.phase {
            case .loading:
                ProgressView().controlSize(.large).frame(height: 260)
            case .failed:
                failure
            case .disconnected:
                disconnected
            case .waiting:
                waiting
            case .connected:
                connected
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.08)))
    }

    private var disconnected: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.circle").font(.system(size: 48)).foregroundStyle(Palette.pale)
            Text("Not connected").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink)
            Text("Connect once and SamRabbit on your watch uses your ChatGPT subscription, like your R1. Until then "
                 + "it answers with Claude.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let notice = model.notice {
                Text(notice).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.pale)
            }
            Button("Get a Code") { Task { await model.connect() } }
                .keyboardShortcut(.defaultAction).padding(.top, 4)
        }
        .frame(height: 260)
    }

    private var waiting: some View {
        VStack(spacing: 12) {
            Text("1. Open the ChatGPT login page   2. Sign in   3. Enter this code")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
            Text(model.code ?? "")
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .kerning(3)
                .foregroundStyle(model.expired ? Palette.muted : Palette.ink)
                .textSelection(.enabled)
                .accessibilityLabel("Login code " + (model.code ?? "").map { String($0) }.joined(separator: " "))
            if let link = model.link {
                Text(link.absoluteString).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.pale)
                    .textSelection(.enabled)
            }
            if model.expired {
                Text("This code expired").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                Button("New Code") { Task { await model.connect() } }.keyboardShortcut(.defaultAction)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.expiresAt.map { "Waiting for you · valid for \(PairingModel.remaining($0.timeIntervalSince(model.now)))" }
                         ?? "Waiting for you")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).monospacedDigit()
                }
                HStack {
                    Button("Open Browser") { model.openBrowser() }.keyboardShortcut(.defaultAction)
                    Button("Copy Code") { model.copyCode() }
                }
            }
        }
        .frame(height: 260)
    }

    private var connected: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(Palette.orb)
            Text("ChatGPT is connected").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink)
            Text(model.account).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.pale)
                .textSelection(.enabled)
            if model.borrowed {
                Text("Your watch assistant talks with gpt-realtime-2.1 in the R1’s voice, using the Codex login on "
                     + "this Mac. SamRabbit only reads it, so Codex stays signed in; Codex renews it as you use it.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Give SamRabbit Its Own Login") { Task { await model.connect() } }.padding(.top, 4)
            } else {
                Text("Your watch assistant now talks with gpt-realtime-2.1 in the R1’s voice. The Mac has its own login, "
                     + "separate from your R1 and from the ChatGPT app.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Disconnect…") { model.confirmDisconnect = true }.padding(.top, 4)
            }
        }
        .frame(height: 260)
    }

    private var failure: some View {
        let text = model.failureText
        return VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 34)).foregroundStyle(Palette.pale)
            Text(text.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
            Text(text.detail).font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
            if let command = text.command {
                Text(command).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.pale)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
                    .textSelection(.enabled)
            }
            Button("Try Again") { Task { await model.refresh() } }.padding(.top, 4)
        }
        .frame(height: 260)
    }
}

@MainActor
final class ChatGPTWindowController: NSWindowController, NSWindowDelegate {
    let model = ChatGPTModel()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Connect ChatGPT"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 9 / 255, green: 11 / 255, blue: 16 / 255, alpha: 1)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.contentView = NSHostingView(rootView: ChatGPTView(model: model))
        window.minSize = NSSize(width: 420, height: 470)
        if !window.setFrameUsingName("SamRabbitChatGPT") { window.center() }
        window.setFrameAutosaveName("SamRabbitChatGPT")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { model.open() }
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { model.close() }
}
