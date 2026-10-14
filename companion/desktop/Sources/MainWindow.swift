import AppKit
import SwiftUI
import WebKit

/// What the native "waiting" screen shows until the page loads.
@MainActor
final class WaitingModel: ObservableObject {
    enum Reason: Equatable {
        case starting
        case unreachable
        case noToken
        case bridgeWithoutApp
        case http(Int)
    }

    @Published var visible = true
    @Published var reason: Reason = .starting
    @Published var retrying = false
    var retry: () -> Void = {}

    var title: String {
        switch reason {
        case .starting: return "Opening SamRabbit…"
        case .noToken: return "SamRabbit isn’t set up yet"
        case .http(401), .http(403): return "The bridge didn’t accept SamRabbit"
        default: return "Waiting for the SamRabbit bridge…"
        }
    }

    var detail: String {
        let host = "\(Config.baseURL.host ?? "127.0.0.1"):\(Config.baseURL.port ?? 80)"
        switch reason {
        case .starting:
            return "Connecting to the bridge on this Mac."
        case .unreachable:
            return "The bridge at \(host) isn’t answering yet. It starts with your Mac; SamRabbit keeps trying."
        case .noToken:
            return "There is no desktop token at \(Config.tokenFile). Run the installer once:"
        case .bridgeWithoutApp:
            return "The bridge at \(host) is running, but this version doesn’t serve the SamRabbit app yet. SamRabbit keeps checking; updating the bridge turns it on:"
        case .http(404):
            return "The bridge at \(host) is running but doesn’t serve the SamRabbit app yet. Update the bridge:"
        case .http(401), .http(403):
            return "The desktop token was not accepted. Run the desktop installer again:"
        case .http(503):
            return "The bridge says the desktop app isn’t installed or set up. Run the installer:"
        case .http(let status):
            return "The bridge at \(host) answered HTTP \(status). SamRabbit keeps trying."
        }
    }

    var command: String? {
        switch reason {
        case .noToken, .http(401), .http(403), .http(503): return "companion/desktop/install.sh"
        case .http(404), .bridgeWithoutApp: return "companion/mac-bridge/install.sh"
        default: return nil
        }
    }
}

/// Transparent strip over the web view's header that drags the window (WKWebView has no drag
/// regions). The page reports its header controls; clicks there pass through to the web view.
final class DragStripView: NSView {
    var passThrough: [NSRect] = []

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if passThrough.contains(where: { $0.insetBy(dx: -3, dy: -3).contains(local) }) { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount >= 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.miniaturize(nil)
            case "None": break
            default: window.zoom(nil)
            }
            return
        }
        window.performDrag(with: event)
    }
}

/// The main window. `keepsOffscreen` is for the window snapshots only: AppKit moves a window that is off every display
/// back onto one when it is ordered in, and that one must stay where nobody sees it.
final class MainAppWindow: NSWindow {
    var keepsOffscreen = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        keepsOffscreen ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

/// Forwards script messages without retaining the controller (WKUserContentController keeps handlers alive).
final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate,
    WKScriptMessageHandler {
    static let headerHeight: CGFloat = 52
    static let trafficLightX: CGFloat = 20

    let webView: WKWebView
    let waiting = WaitingModel()
    private let dragStrip = DragStripView()
    private var hosting: NSHostingView<WaitingView>!
    private var retryTimer: Timer?
    private var attempt = 0
    private var loaded = false
    private var loading = false
    private var pendingConversation: String?
    /// App calls (`window.SamRabbitApp.…`) asked for before the page loaded; run once it has.
    private var pendingCalls: [String] = []
    private var lastBlockedLog = Date.distantPast
    var onPageStatus: (([String: Any]) -> Void)?
    /// Talk and Settings: the page and MacVoice, the dock's switch, the native windows (MainWindowBridge.swift).
    private(set) var bridge: MainWindowBridge!

    /// `live: false` for `--render-window-snapshots` (the bridge then opens no other window and leaves the dock be).
    init(live: Bool = true) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.suppressesIncrementalRendering = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        let window = MainAppWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "SamRabbit"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.backgroundColor = NSColor(srgbRed: 9 / 255, green: 11 / 255, blue: 16 / 255, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.collectionBehavior.insert(.fullScreenPrimary)
        if !window.setFrameUsingName("SamRabbitMain") { window.center() }
        window.setFrameAutosaveName("SamRabbitMain")

        let controller = configuration.userContentController
        controller.add(ScriptMessageProxy(self), name: "samrabbit")
        controller.addUserScript(WKUserScript(source: nativeInfoScript(), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView.navigationDelegate = self
        webView.uiDelegate = self
        bridge = MainWindowBridge(webView: webView, live: live)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = window.backgroundColor
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.customUserAgent = nil
        if #available(macOS 13.3, *) { webView.isInspectable = true }

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = window.backgroundColor.cgColor
        window.contentView = container
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        waiting.retry = { [weak self] in self?.reload() }
        hosting = NSHostingView(rootView: WaitingView(model: waiting))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        dragStrip.frame = NSRect(x: 0, y: container.bounds.height - Self.headerHeight, width: container.bounds.width,
                                 height: Self.headerHeight)
        dragStrip.autoresizingMask = [.width, .minYMargin]
        container.addSubview(dragStrip)
        layoutTrafficLights()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: window chrome

    private func nativeInfoScript() -> String {
        let right = trafficLightsRight()
        return "window.SAMRABBIT_NATIVE={version:\(jsString(Config.version)),"
            + "trafficLights:{right:\(Int(right.rounded())),centerY:\(Int(Self.headerHeight / 2))}};"
    }

    private func trafficLightsRight() -> CGFloat {
        guard let zoom = window?.standardWindowButton(.zoomButton), let close = window?.standardWindowButton(.closeButton) else {
            return 78
        }
        let spacing = (zoom.frame.minX - close.frame.minX) / 2  // close, minimise, zoom
        return Self.trafficLightX + 2 * spacing + zoom.frame.width
    }

    /// Centres the traffic lights vertically in the 52 pt header (same approach as Electron's
    /// trafficLightPosition: resize the titlebar container and move the three buttons).
    func layoutTrafficLights() {
        guard let window, !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let mini = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let container = close.superview?.superview else { return }
        let height = Self.headerHeight
        var frame = container.frame
        frame.size.height = height
        frame.origin.y = window.frame.height - height
        container.frame = frame
        let spacing = mini.frame.minX - close.frame.minX
        for (index, button) in [close, mini, zoom].enumerated() {
            button.setFrameOrigin(NSPoint(x: Self.trafficLightX + CGFloat(index) * spacing,
                                          y: (height - button.frame.height) / 2))
        }
    }

    func windowWillClose(_ notification: Notification) { Log.write("window closed (SamRabbit keeps running in the menu bar)") }
    func windowDidResize(_ notification: Notification) { layoutTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) {
        layoutTrafficLights()
        bridge.windowBecameKey()
    }
    func windowDidResignKey(_ notification: Notification) { layoutTrafficLights() }
    func windowDidExitFullScreen(_ notification: Notification) { layoutTrafficLights() }

    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { Log.write("window shown") }
        window.makeKeyAndOrderFront(nil)
        layoutTrafficLights()
        if !loaded && !loading { attemptLoad() }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    // MARK: loading

    func start() {
        attemptLoad()
    }

    func reload() {
        retryTimer?.invalidate()
        attempt = 0
        if loaded, let token = Config.token() {
            installCookie(token) { [weak self] in self?.webView.reload() }
        } else {
            loaded = false
            attemptLoad()
        }
    }

    private func attemptLoad() {
        retryTimer?.invalidate()
        guard let token = Config.token() else {
            show(.noToken)
            scheduleRetry()
            return
        }
        guard let request = Config.request(Config.baseURL, timeout: 6) else { return }
        loading = true
        waiting.retrying = true
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            // samrabbit_app never sends WWW-Authenticate; the bridge's own bearer 401 does.
            let oldBridge = status == 401 && (http?.value(forHTTPHeaderField: "WWW-Authenticate") ?? "").hasPrefix("Bearer")
            Task { @MainActor in
                guard let self else { return }
                if status == 200 {
                    self.installCookie(token) { self.loadPage(token) }
                } else {
                    self.loading = false
                    let reason: WaitingModel.Reason = status == 0 ? .unreachable : oldBridge ? .bridgeWithoutApp : .http(status)
                    if self.attempt == 0 || self.waiting.reason != reason {
                        Log.write(status == 0 ? "bridge not reachable at \(Config.origin.absoluteString)"
                                  : oldBridge ? "bridge does not serve the app page yet (HTTP 401 bearer; needs the updated bridge)"
                                  : "bridge answered HTTP \(status) for the app page")
                    }
                    self.show(reason)
                    self.scheduleRetry()
                }
            }
        }.resume()
    }

    private func installCookie(_ token: String, then: @escaping () -> Void) {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: Config.tokenCookie, .value: token, .path: "/",
            .domain: Config.baseURL.host ?? "127.0.0.1",
            .originURL: Config.origin,
            HTTPCookiePropertyKey("HttpOnly"): "TRUE",
        ]
        if #available(macOS 10.15, *) { properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax }
        guard let cookie = HTTPCookie(properties: properties) else { return then() }
        webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { then() }
    }

    private func loadPage(_ token: String) {
        var request = URLRequest(url: Config.baseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue(token, forHTTPHeaderField: Config.tokenHeader)
        Log.write("loading \(Config.baseURL.absoluteString)")
        webView.load(request)
    }

    private func show(_ reason: WaitingModel.Reason) {
        waiting.reason = reason
        waiting.visible = true
        hosting.isHidden = false
    }

    private func scheduleRetry() {
        let delays: [TimeInterval] = [2, 3, 5, 8, 10]
        var delay = delays[min(attempt, delays.count - 1)]
        // A bridge that answers but can't serve the app won't change until it is reinstalled: check less often.
        if waiting.reason == .bridgeWithoutApp || waiting.reason == .http(404) { delay = attempt == 0 ? 5 : 30 }
        attempt += 1
        waiting.retrying = true
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.attemptLoad() }
        }
    }

    func openConversation(_ id: String?) {
        guard let id else { return }
        if loaded {
            webView.evaluateJavaScript("window.SamRabbitApp && window.SamRabbitApp.openConversation(\(jsString(id)))")
        } else {
            pendingConversation = id
        }
    }

    func focusSearch() {
        call("focusSearch()")
    }

    /// ⌘1–⌘5 and Settings… from the menus: "home" | "tasks" | "chats" | "calendar" | "settings".
    func showView(_ view: String) {
        call("show(\(jsString(view)))")
    }

    /// New Task (⌘N): Tasks with the composer open.
    func newTask() {
        call("newTask()")
    }

    /// Runs `window.SamRabbitApp.<call>` now, or once the page has loaded.
    private func call(_ call: String) {
        let script = "window.SamRabbitApp && window.SamRabbitApp.\(call)"
        if loaded {
            webView.evaluateJavaScript(script)
        } else if !pendingCalls.contains(script) {
            pendingCalls.append(script)
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        let sameOrigin = url.scheme == Config.origin.scheme && url.host == Config.origin.host && url.port == Config.origin.port
        let scheme = url.scheme?.lowercased() ?? ""
        if ["about", "data", "blob"].contains(scheme) || sameOrigin {
            return decisionHandler(.allow)
        }
        if navigationAction.targetFrame?.isMainFrame == true {
            // Only our own page runs in the main frame (generated UIs are sandboxed without
            // allow-top-navigation): a link the user clicked or dropped there opens in the browser.
            openExternal(url)
            return decisionHandler(.cancel)
        }
        // A generated UI (model-written code in a sandboxed iframe) navigating its frame elsewhere or
        // asking for a new window. Script can do that without any click (location = …, a.click()), so it
        // never opens anything by itself: the page asks the user first, like its open-link messages.
        if scheme == "http" || scheme == "https" {
            webView.evaluateJavaScript("window.SamRabbitApp && window.SamRabbitApp.confirmOpen(\(jsString(url.absoluteString)))")
        }
        let now = Date()
        if now.timeIntervalSince(lastBlockedLog) > 60 {
            lastBlockedLog = now
            Log.write("blocked a navigation inside a generated UI (the page asks before opening links)")
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse, http.statusCode != 200 {
            Log.write("app page answered HTTP \(http.statusCode)")
            loading = false
            loaded = false
            show(.http(http.statusCode))
            scheduleRetry()
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        loaded = true
        attempt = 0
        waiting.visible = false
        waiting.retrying = false
        hosting.isHidden = true
        Log.write("page loaded")
        let calls = pendingCalls
        pendingCalls = []
        for script in calls { webView.evaluateJavaScript(script) }
        if let id = pendingConversation {
            pendingConversation = nil
            openConversation(id)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A new page (a reload, the bridge back after a restart): it says when it is ready for the native state.
        bridge.pageGone()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        Log.write("page failed to load (\((error as NSError).code))")
        loading = false
        loaded = false
        show(.unreachable)
        scheduleRetry()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        Log.write("page failed (\((error as NSError).code))")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.write("web content process ended; reloading")
        bridge.pageGone()
        loaded = false
        attemptLoad()
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Only reached for navigations the policy above allowed (same origin, about:, data:, blob:):
        // nothing to open outside, and no second web view.
        return nil
    }

    // MARK: messages from the page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "ready" { onPageStatus?(body) }
        if bridge.handle(body) { return }
        switch type {
        case "open":
            if let text = body["url"] as? String, let url = URL(string: text) { openExternal(url) }
        case "copy":
            if let text = body["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case "noDrag":
            let rects = (body["rects"] as? [[NSNumber]] ?? []).compactMap { values -> NSRect? in
                guard values.count == 4 else { return nil }
                return NSRect(x: values[0].doubleValue, y: values[1].doubleValue, width: values[2].doubleValue,
                              height: values[3].doubleValue)
            }
            dragStrip.passThrough = rects
        case "status", "diag":
            onPageStatus?(body)
        case "pairPhone":
            AppModel.shared.openPairing()
        default:
            break
        }
    }

    private func openExternal(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }
}

func jsString(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [value])
    let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
    return String(array.dropFirst().dropLast())
}
