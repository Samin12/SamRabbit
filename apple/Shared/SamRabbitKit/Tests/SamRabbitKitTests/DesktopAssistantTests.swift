import Foundation
import Synchronization
import Testing
@testable import SamRabbitKit

/// The Mac app's voice (CONTRACTS-WAVE6 "Mac voice"): the same conversation and turn protocol as the watch, through
/// the bridge's desktop API (`/v1/desktop/assistant/*`, the desktop token, loopback only).
@Suite("The Mac app's assistant")
struct DesktopAssistantTests {
    @Test func desktopRequestsCarryTheDesktopToken() throws {
        let host = BridgeHost(host: "127.0.0.1", port: 3780)
        let desktop = BridgeClient(hosts: [host], token: "desktop-token-for-tests", api: .desktop)
        #expect(desktop.api == .desktop)
        let session = try #require(desktop.makeRequest(.post(desktop.api.assistantPath("session"), body: [:]), host: host))
        #expect(session.url?.path == "/v1/desktop/assistant/session")
        #expect(session.value(forHTTPHeaderField: "X-SamRabbit-Desktop") == "desktop-token-for-tests")
        #expect(session.value(forHTTPHeaderField: "Authorization") == nil)
        // The phone and the watch keep their bearer token and their routes.
        let mobile = BridgeClient(hosts: [host], token: "mobile-token-for-tests")
        #expect(mobile.api == .mobile)
        let turn = try #require(mobile.makeRequest(.post(mobile.api.assistantPath("cancel"), body: [:]), host: host))
        #expect(turn.url?.path == "/v1/mobile/assistant/cancel")
        #expect(turn.value(forHTTPHeaderField: "Authorization") == "Bearer mobile-token-for-tests")
        #expect(turn.value(forHTTPHeaderField: "X-SamRabbit-Desktop") == nil)
        #expect(BridgeAPI.desktop.assistantPath("turn") == "/v1/desktop/assistant/turn")
        #expect(BridgeAPI.mobile.assistantPath("turn") == AssistantTurnRequest.path)
    }

    /// The Mac says what is wrong with the Mac (the watch's lines talk about reaching the Mac and the iPhone).
    @Test func theMacSaysWhatIsWrongWithTheMac() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let counter = Mutex(0)
        var m = ConversationMachine(idleTimeout: 90, device: .mac) {
            counter.withLock { value in
                value += 1
                return "t\(value)"
            }
        }
        #expect(m.device == .mac)
        _ = m.handle(.start, at: t0)
        _ = m.handle(.audioReady, at: t0)
        _ = m.handle(.utterance(WAV.encode(pcm: Data(count: 32_000))), at: t0)
        let effects = m.handle(.turn("t1", .failed(.unreachable)), at: t0)
        #expect(effects == [.closeMic, .speak("I can't reach the SamRabbit bridge on this Mac."), .haptic(.failure)])
        _ = m.handle(.playing, at: t0)
        _ = m.handle(.drained, at: t0)
        #expect(m.phase == .idle)
        #expect(m.problem == "The SamRabbit bridge isn't running")
        #expect(ConversationMachine.Failure.unauthorized.spoken(on: .mac).contains("this Mac"))
        #expect(ConversationMachine.Failure.outdated.shown(on: .mac) == "Update the SamRabbit bridge")
        // Failures that mean the same everywhere are said the same way.
        #expect(ConversationMachine.Failure.busy.spoken(on: .mac) == ConversationMachine.Failure.busy.spoken)
        let timeout = ConversationMachine.Failure.failed(code: "assistant_timeout", message: "")
        #expect(timeout.spoken(on: .mac) == "Sorry, that didn't work. Try again.")
        // The watch's own lines are unchanged.
        #expect(ConversationMachine().device == .watch)
        #expect(ConversationMachine.Failure.unreachable.spoken == "I can't reach your Mac right now.")
    }
}

#if os(macOS)
@Suite("The Mac app's assistant against the fake bridge", .serialized)
struct DesktopAssistantBridgeTests {
    static let desktopToken = "fake-desktop-token"

    @Test func streamsATurnThroughTheDesktopRoutes() async throws {
        let bridge = try FakeBridgeProcess()
        let client = BridgeClient(hosts: [bridge.host], token: Self.desktopToken, api: .desktop)
        let session = try await client.assistantSession()
        #expect(session.brain == .realtime && session.ready)
        let turn = AssistantTurnRequest(turnId: UUID().uuidString, conversationId: session.conversationId,
                                        input: .audio(utteranceWAV), language: "en-US")
        let items = try await collect(client.assistantTurn(turn))
        #expect(items.heard == "Draft the release notes for build 2.4")
        #expect(items.said == AssistantBridgeTests.say)
        #expect(items.audioBytes > 100_000)
        let done = try #require(items.done)
        #expect(done.conversationId == session.conversationId && done.turnId == turn.turnId)
        let state = try await bridge.assistantState()
        let sent = state["turns"].array?.last
        #expect(sent?["deviceId"].string == "mac")
        #expect(sent?["accept"].string == AssistantStream.contentType)
        #expect(sent?["kind"].string == "audio")
        #expect(state["sessions"].array?.last?["deviceId"].string == "mac")
        // Announcements, cancel and end go to the desktop routes too.
        _ = try await bridge.control("announce", ["say": "“Fix login redirect” in Hermes finished."])
        let page = try await client.assistantAnnouncements(conversationId: session.conversationId)
        #expect(page.items.map(\.say) == ["“Fix login redirect” in Hermes finished."])
        try await client.assistantCancel(conversationId: session.conversationId)
        try await client.assistantEnd(conversationId: session.conversationId)
        let after = try await bridge.assistantState()
        #expect(after["cancels"].array?.last?["conversationId"].string == session.conversationId)
        #expect(after["ends"].array?.last?["ended"].bool == true)
    }

    @Test func aWrongDesktopTokenIsRefused() async throws {
        let bridge = try FakeBridgeProcess()
        let stranger = BridgeClient(hosts: [bridge.host], token: "not-the-desktop-token", api: .desktop)
        await #expect(throws: BridgeError.unauthorized) { _ = try await stranger.assistantSession() }
        // The desktop token opens nothing on the mobile API.
        let mobile = BridgeClient(hosts: [bridge.host], token: Self.desktopToken)
        await #expect(throws: BridgeError.unauthorized) { _ = try await mobile.assistantSession() }
    }
}
#endif
