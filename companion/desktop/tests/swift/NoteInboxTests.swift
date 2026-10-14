import Foundation

/// Voice notes in the inbox (`note:<captureId>`, samrabbit_capture `inbox_items`): their suggestion decoded, the row's
/// button (the suggestion's verb, "Try again" for a failed note), what counts as needing Samin, and that DockAttention
/// leaves them to the note's own outcome (no "needs you" notification for each).
enum NoteInboxTests {
    static let all: [(String, () throws -> Void)] = [
        ("decodesTheBridgesNoteItems", decodesTheBridgesNoteItems),
        ("aNoteOffersItsSuggestion", aNoteOffersItsSuggestion),
        ("aFailedNoteNeedsSaminUntilSeen", aFailedNoteNeedsSaminUntilSeen),
        ("notesAreNotAnnounced", notesAreNotAnnounced),
    ]

    /// The bridge's own item (samrabbit_capture.CaptureService.inbox_items).
    static func noteJSON(_ id: String, status: String, unread: Bool = true, suggestion: String? = nil,
                         can: String = #"["act", "dismiss", "seen"]"#) -> String {
        """
        {"id": "note:\(id)", "source": "note", "agent": null, "title": "Call the bank about the replacement card.",
         "project": "Voice note", "cwd": null, "status": "\(status)", "statusLabel": "Start it as a T3 task?",
         "summary": "Call the bank about the replacement card.", "updatedAt": "2026-10-14T13:00:00Z",
         "unread": \(unread), "pending": {"approvals": [], "inputs": []}, "can": \(can), "live": false,
         "progress": null, "phase": null, "suggestion": \(suggestion ?? "null"), "captureId": "\(id)",
         "capturedAt": "2026-10-14T09:00:00-04:00"}
        """
    }

    static func inbox(_ items: [String]) throws -> DockInbox {
        try DockInbox.decode(Data((#"{"revision": 3, "items": ["# + items.joined(separator: ",") + "]}").utf8))
    }

    static let id = "3f2b8c1e-7d4a-4e9b-8f21-6a5c0d9e1b47"

    static func decodesTheBridgesNoteItems() throws {
        let decoded = try inbox([noteJSON(id, status: "needs-input", suggestion: #"{"action": "task", "label": "Start it as a T3 task?"}"#),
                                 noteJSON("9c4e2a7b-1f3d-4b8e-a6c5-2d7f0e8b3a91", status: "error")])
        expectEqual(decoded.items.count, 2)
        let kept = decoded.items.first { $0.id == "note:\(id)" }
        expect(kept?.isVoiceNote == true)
        expectEqual(kept?.noteSuggestion, DockNoteSuggestion(action: "task", label: "Start it as a T3 task?"))
        expectEqual(decoded.items.first { $0.status == .error }?.noteSuggestion, nil, "no suggestion: nil")
        // Odd suggestions never drop the item.
        let odd = try inbox([noteJSON(id, status: "idle", suggestion: #""Start it?""#),
                             noteJSON("9c4e2a7b-1f3d-4b8e-a6c5-2d7f0e8b3a91", status: "idle", suggestion: #"{"label": "no action"}"#)])
        expectEqual(odd.items.count, 2)
        expect(odd.items.allSatisfy { $0.noteSuggestion == nil }, "a string or a suggestion without an action is none")
        // Every other item has none, whatever it carries.
        let t3 = try DockInbox.decode(Fixture.inboxData()).items
        expect(t3.allSatisfy { $0.noteSuggestion == nil && !$0.isVoiceNote })
    }

    static func aNoteOffersItsSuggestion() throws {
        func act(_ suggestion: String?, status: String = "needs-input", can: String = #"["act", "dismiss", "seen"]"#) throws -> DockItem? {
            try inbox([noteJSON(id, status: status, suggestion: suggestion, can: can)]).items.first
        }
        expectEqual(try act(#"{"action": "task", "label": "Start it as a T3 task?"}"#)?.noteAct?.title, "Start as task")
        expectEqual(try act(#"{"action": "task", "label": "x"}"#)?.noteAct?.action, "task")
        expectEqual(try act(#"{"action": "journal", "label": "Add it to your journal?"}"#)?.noteAct?.title, "Add to journal")
        expectEqual(try act(#"{"action": "event", "label": "Put it on your calendar for Thu 9:00 AM?", "startsAt": "2026-10-15T09:00:00-04:00"}"#)?
            .noteAct?.title, "Put on calendar")
        expect(try act(#"{"action": "block", "label": "Block the time?"}"#)?.noteAct == nil, "the bridge has no act for a block")
        expect(try act(nil, status: "idle")?.noteAct == nil, "a plain note: nothing to do but read it")
        expect(try act(#"{"action": "task", "label": "x"}"#, can: #"["seen"]"#)?.noteAct == nil, "a bridge without act")
        let failed = try act(nil, status: "error")
        expectEqual(failed?.noteAct?.title, "Try again")
        expect(failed?.noteAct?.action == nil, "the bridge picks the retry itself")
        // Only voice notes: a T3 item with "act" in its list offers nothing of this.
        var t3 = try DockInbox.decode(Fixture.inboxData()).items[0]
        t3.can.append("act")
        expect(t3.noteAct == nil)
    }

    static func aFailedNoteNeedsSaminUntilSeen() throws {
        let unseen = try inbox([noteJSON(id, status: "error", unread: true)]).items[0]
        let seen = try inbox([noteJSON(id, status: "error", unread: false)]).items[0]
        expect(unseen.needsYou, "a failed note he hasn't seen needs him")
        expect(!seen.needsYou, "Mark seen clears it from the count")
        expect(try inbox([noteJSON(id, status: "needs-input", suggestion: #"{"action": "task", "label": "x"}"#)]).items[0].needsYou)
        expect(!(try inbox([noteJSON(id, status: "idle", unread: false)]).items[0].needsYou), "a plain note: never")
        // Any other failure needs him until it changes, seen or not.
        var t3 = try DockInbox.decode(Fixture.inboxData()).items[0]
        t3.status = .error
        t3.unread = false
        expect(t3.needsYou)
        let counted = try inbox([noteJSON(id, status: "error", unread: false), noteJSON("9c4e2a7b-1f3d-4b8e-a6c5-2d7f0e8b3a91", status: "error")])
        expectEqual(counted.shownCounts(items: counted.items).needsYou, 1, "only the unseen failure counts")
    }

    static func notesAreNotAnnounced() throws {
        var attention = DockAttention()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        _ = attention.update([], now: t0)
        let notes = try inbox([noteJSON(id, status: "needs-input", suggestion: #"{"action": "task", "label": "x"}"#),
                               noteJSON("9c4e2a7b-1f3d-4b8e-a6c5-2d7f0e8b3a91", status: "error")]).items
        expect(attention.update(notes, now: t0.addingTimeInterval(5)).isEmpty, "a kept or failed note posts no notification")
        var t3 = try DockInbox.decode(Fixture.inboxData()).items[0]
        t3.id = "t3:th_new_need"
        t3.status = .needsApproval
        expectEqual(attention.update(notes + [t3], now: t0.addingTimeInterval(10)).map(\.id), ["t3:th_new_need"], "an agent's still does")
    }
}
