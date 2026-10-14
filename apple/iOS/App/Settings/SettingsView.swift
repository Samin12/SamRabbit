import SamRabbitKit
import SwiftUI
import UserNotifications
import VisionKit

/// Settings: pairing (QR, manual, deep link), the bridge address, notifications, widgets, About.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var scanning = false
    @State private var confirmUnpair = false
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var health: BridgeHealth?

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    OrbView(mood: model.orbMood, halo: false).frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.pairing?.displayName ?? "Not paired")
                            .font(.system(size: 18, weight: .semibold))
                        Text(model.isPaired ? (model.reachable ? "Connected" : model.lastError?.shortDescription ?? "Connecting…")
                             : "Pair with SamRabbit on your Mac")
                            .font(.system(size: 13.5))
                            .foregroundStyle(model.isPaired && model.reachable ? SamTheme.green : SamTheme.muted)
                    }
                }
                .padding(.vertical, 6)
            }
            .listRowBackground(SamTheme.glass2)

            Section {
                Button {
                    scanning = true
                } label: {
                    Label("Scan pairing code", systemImage: "qrcode.viewfinder")
                }
                NavigationLink {
                    ManualPairView()
                } label: {
                    Label("Enter code manually", systemImage: "keyboard")
                }
                if model.isPaired || model.unpairing {
                    Button(role: .destructive) {
                        confirmUnpair = true
                    } label: {
                        HStack {
                            Label(model.unpairing ? "Unpairing…" : "Unpair this iPhone", systemImage: "link.badge.minus")
                            if model.unpairing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .foregroundStyle(SamTheme.red)
                    .disabled(model.unpairing)
                }
            } header: {
                Text("Pairing")
            } footer: {
                Text("On your Mac: SamRabbit > Pair iPhone… shows a QR code and an 8-character code. The samrabbit://pair link also works from the Camera app.")
            }
            .listRowBackground(SamTheme.glass2)

            if let pairing = model.pairing {
                Section("Bridge") {
                    NavigationLink {
                        BridgeHostsView()
                    } label: {
                        LabeledContent("Address", value: pairing.hosts.first?.description ?? "—")
                    }
                    if pairing.hosts.count > 1 {
                        LabeledContent("Also tries", value: pairing.hosts.dropFirst().map(\.description).joined(separator: ", "))
                    }
                    LabeledContent("This device", value: pairing.deviceName)
                    LabeledContent("Paired", value: pairing.pairedAt.formatted(date: .abbreviated, time: .shortened))
                    if let version = health?.version ?? pairing.bridgeVersion {
                        LabeledContent("Bridge version", value: version)
                    }
                }
                .listRowBackground(SamTheme.glass2)
            }

            Section {
                HStack {
                    Label("Notifications", systemImage: "bell.badge")
                    Spacer()
                    switch notificationStatus {
                    case .authorized, .provisional, .ephemeral:
                        Text("On").foregroundStyle(SamTheme.green)
                    case .denied:
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    default:
                        Button("Turn on") {
                            Task {
                                await model.notifications.requestAuthorization()
                                await loadNotificationStatus()
                            }
                        }
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("SamRabbit checks your Mac in the background about every 15 minutes and tells you when a task needs you or a task you started here finishes. Your Apple Watch shows them too.")
            }
            .listRowBackground(SamTheme.glass2)

            Section {
                NavigationLink {
                    ActionButtonHelpView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Action Button")
                            Text("Settings > Action Button > Controls > SamRabbit")
                                .font(.system(size: 12.5))
                                .foregroundStyle(SamTheme.muted)
                        }
                    } icon: {
                        Image(systemName: "button.horizontal.top.press")
                    }
                }
                .accessibilityIdentifier("action-button-help")
            } footer: {
                Text("Pick Talk to SamRabbit (the live call) or Voice Note (records at once, sends when you pause). Set to Ask SamRabbit before? It opens the call now. Apple Watch Ultra: Settings > Action Button > Action > Control, then Control > Ask SamRabbit or Voice Note.")
            }
            .listRowBackground(SamTheme.glass2)

            Section("Widgets") {
                NavigationLink {
                    WidgetGalleryView()
                } label: {
                    Label("Widget gallery", systemImage: "square.grid.2x2")
                }
            }
            .listRowBackground(SamTheme.glass2)

            Section {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                Link(destination: URL(string: "https://github.com/Samin12/SamRabbit")!) {
                    Label("SamRabbit on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            } header: {
                Text("About")
            } footer: {
                Text("SamRabbit talks only to the bridge on your Mac, over your own network. The token lives in this iPhone's Keychain.")
            }
            .listRowBackground(SamTheme.glass2)
        }
        .samScreen()
        .navigationTitle("Settings")
        .sheet(isPresented: $scanning) {
            QRScannerSheet { link in
                scanning = false
                model.sheet = .pair(link)
            }
        }
        .confirmationDialog("Unpair this iPhone?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { Task { await model.unpair() } }
        } message: {
            Text("Your Mac forgets this iPhone and its Apple Watch. The widgets stop updating until you pair again.")
        }
        .task { await loadNotificationStatus() }
        .task(id: model.pairing?.deviceId) { health = try? await model.client?.health() }
    }

    func loadNotificationStatus() async {
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

/// Host and code typed by hand.
struct ManualPairView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var code = ""
    @State private var pairing = false
    @State private var scanning = false
    @FocusState private var field: Field?

    enum Field { case host, code }

    var parsedHost: BridgeHost? { BridgeHost(parsing: host) }
    var parsedCode: String? { PairingCode.normalize(code) }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                OrbView(mood: pairing ? .working : .idle)
                    .frame(width: 96, height: 96)
                    .padding(.top, 24)
                    .padding(.bottom, 12)
                VStack(spacing: 6) {
                    Text("Pair with your Mac").font(.system(size: 24, weight: .bold))
                    Text("On your Mac, open SamRabbit and choose Pair iPhone…, then enter the address and the 8-character code it shows.")
                        .font(.system(size: 14.5)).foregroundStyle(SamTheme.muted).multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MAC ADDRESS").font(SamTheme.eyebrow).tracking(0.5).foregroundStyle(SamTheme.faint)
                        TextField("192.168.1.183:3780", text: $host)
                            .focused($field, equals: .host)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .onSubmit { field = .code }
                            .font(.system(size: 18, weight: .medium, design: .monospaced))
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.28)))
                        if !host.isEmpty, parsedHost == nil {
                            Text("Use an address like 192.168.1.183 or 192.168.1.183:3780.")
                                .font(.system(size: 12)).foregroundStyle(SamTheme.amber)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PAIRING CODE").font(SamTheme.eyebrow).tracking(0.5).foregroundStyle(SamTheme.faint)
                        TextField("ABCD-EFGH", text: $code)
                            .focused($field, equals: .code)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit { pair() }
                            .font(.system(size: 26, weight: .semibold, design: .monospaced))
                            .tracking(4)
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.28)))
                    }
                }
                .glassCard(tint: SamTheme.orb)
                Button {
                    pair()
                } label: {
                    Group {
                        if pairing { ProgressView() } else { Text("Pair").fontWeight(.semibold) }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .disabled(parsedHost == nil || parsedCode == nil || pairing)
                if let problem = model.pairingProblem, !pairing {
                    PairingProblemView(text: problem)
                }
                Button {
                    scanning = true
                } label: {
                    Label("Scan the QR code instead", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.glass)
            }
            .padding(.horizontal, 20)
        }
        .samScreen()
        .navigationTitle("Pair")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model.pairingProblem = nil
            if host.isEmpty, let current = model.pairing?.hosts.first { host = current.description }
        }
        .sheet(isPresented: $scanning) {
            QRScannerSheet { link in
                scanning = false
                host = link.hosts.first?.description ?? host
                code = PairingCode.display(link.code)
                pairing = true
                Task {
                    _ = await model.pair(with: link)
                    pairing = false
                    dismiss()
                }
            }
        }
    }

    func pair() {
        guard let host = parsedHost, let code = parsedCode else { return }
        pairing = true
        field = nil
        Task {
            let ok = await model.pair(with: PairLink(hosts: [host], code: code))
            pairing = false
            if ok {
                model.tab = .home
                dismiss()
            }
        }
    }
}

/// Confirms a `samrabbit://pair` link (QR code, Camera app, simctl openurl).
struct PairConfirmSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let link: PairLink
    @State private var pairing = false

    var body: some View {
        VStack(spacing: 22) {
            OrbView(mood: pairing ? .working : .idle).frame(width: 76, height: 76).padding(.top, 30).padding(.bottom, 6)
            VStack(spacing: 6) {
                Text("Pair with \(link.name ?? "this Mac")?").font(.system(size: 22, weight: .bold)).multilineTextAlignment(.center)
                Text(link.hosts.map(\.description).joined(separator: " · "))
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(SamTheme.muted)
                Text("Code \(PairingCode.display(link.code))")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(SamTheme.orbPale)
                    .padding(.top, 4)
            }
            Text("SamRabbit on this iPhone will be able to see and start your T3 tasks, read your calendar, add journal notes and control the Mac.")
                .font(.system(size: 13.5)).foregroundStyle(SamTheme.ink2).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
            if let problem = model.pairingProblem, !pairing {
                PairingProblemView(text: problem)
            }
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                Button {
                    pairing = true
                    Task {
                        let ok = await model.pair(with: link)
                        pairing = false
                        if ok {
                            model.tab = .home
                            dismiss()
                        }
                    }
                } label: {
                    Group { if pairing { ProgressView() } else { Text("Pair").fontWeight(.semibold) } }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .disabled(pairing)
                Button("Not now") { dismiss() }.buttonStyle(.glass).controlSize(.large)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .samScreen()
        .presentationDetents([.fraction(0.62), .large])
        .onAppear { model.pairingProblem = nil }
    }
}

/// Why pairing failed, under the Pair button ("That code is wrong or expired — get a new one on your Mac.").
struct PairingProblemView: View {
    let text: String

    var body: some View {
        Label {
            Text(text).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(SamTheme.amber)
        }
        .foregroundStyle(SamTheme.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(SamTheme.amber.opacity(0.14)))
        .accessibilityElement(children: .combine)
    }
}

/// The bridge addresses, editable (when the Mac's IP changed).
struct BridgeHostsView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var testing = false
    @State private var result: String?

    var body: some View {
        Form {
            Section {
                TextField("192.168.1.183:3780, 100.x.y.z:3780", text: $text, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(.body, design: .monospaced))
            } footer: {
                Text("Tried in order: your Mac's network address first, then its Tailscale address if you use Tailscale.")
            }
            .listRowBackground(SamTheme.glass2)
            Section {
                Button("Save and test") {
                    let hosts = text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " })
                        .compactMap { BridgeHost(parsing: String($0)) }
                    guard !hosts.isEmpty else {
                        result = "No valid address."
                        return
                    }
                    model.account.updateHosts(hosts)
                    model.pairing = model.account.pairing
                    testing = true
                    Task {
                        do {
                            _ = try await model.account.requireClient().summary()
                            result = "Connected."
                        } catch {
                            result = (error as? BridgeError)?.errorDescription ?? "Failed."
                        }
                        testing = false
                        await model.refresh()
                    }
                }
                .disabled(testing)
                if let result { Text(result).foregroundStyle(SamTheme.muted) }
            }
            .listRowBackground(SamTheme.glass2)
        }
        .samScreen()
        .navigationTitle("Bridge address")
        .onAppear { text = model.pairing?.hosts.map(\.description).joined(separator: ", ") ?? "" }
    }
}

/// The camera QR scanner (VisionKit). Falls back to a note when there is no camera (Simulator).
struct QRScannerSheet: View {
    let found: (PairLink) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ZStack {
                if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                    QRScannerView { payload in
                        if let link = PairLink(string: payload) {
                            Haptics.success()
                            found(link)
                        } else {
                            message = "That QR code isn't a SamRabbit pairing code."
                        }
                    }
                    .ignoresSafeArea()
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(SamTheme.orbPale.opacity(0.85), lineWidth: 3)
                        .frame(width: 250, height: 250)
                } else {
                    ContentUnavailableView("No camera here", systemImage: "camera.metering.unknown",
                                           description: Text("Scanning needs the iPhone camera. Enter the code by hand, or open the samrabbit://pair link."))
                }
            }
            .overlay(alignment: .bottom) {
                if let message {
                    Text(message).font(.system(size: 14)).padding(12).glassEffect(.regular, in: .capsule).padding(.bottom, 40)
                }
            }
            .navigationTitle("Scan pairing code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    let onPayload: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPayload: onPayload) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, recognizesMultipleItems: false,
                                                isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onPayload: (String) -> Void
        private var last: String?

        init(onPayload: @escaping (String) -> Void) { self.onPayload = onPayload }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in items {
                if case .barcode(let code) = item, let payload = code.payloadStringValue, payload != last {
                    last = payload
                    onPayload(payload)
                }
            }
        }
    }
}
