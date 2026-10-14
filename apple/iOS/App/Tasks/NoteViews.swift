import SamRabbitKit
import SwiftUI

// Voice notes in Tasks (CONTRACTS-WAVE8 §C4): a note the Mac could only save (`note:<captureId>`, source `note`)
// waits under Needs you with what it suggests ("Start it as a T3 task?"). Its buttons: the suggestion (done by the
// Mac, `POST /captures/<id>/act`), Keep as note (seen) and Dismiss (it leaves the list).

/// A note's chip: it suggests something, it couldn't be heard, or it is just kept.
struct NoteChip: View {
    let item: InboxItem

    var body: some View {
        let (word, symbol, tint): (String, String, Color) = switch item.status {
        case .error: ("Couldn't hear it", "exclamationmark.triangle.fill", SamTheme.red)
        case .needsInput, .needsApproval: ("Suggestion", "lightbulb.fill", SamTheme.amber)
        default: ("Saved", "note.text", SamTheme.mint)
        }
        Label(word, systemImage: symbol)
            .font(.system(size: 11.5, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.14)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
    }
}

enum NoteText {
    /// The card's box: the suggestion ("Start it as a T3 task?"), else what the title doesn't say already (the rest of
    /// a long note, why it failed), else nothing (the title is his words).
    static func body(_ item: InboxItem) -> String? {
        if let suggestion = item.suggestion, item.status.needsYou { return suggestion.label }
        return item.summary.isEmpty || item.summary == item.title ? nil : item.summary
    }
}

/// What a saved voice note's card offers.
struct NoteActions: View {
    @Environment(AppModel.self) private var model
    let item: InboxItem

    var body: some View {
        let busy = model.busyItems.contains(item.id)
        HStack(spacing: 10) {
            if let suggestion = item.suggestion, item.supports(.act) {
                Button {
                    Task { await model.actOnNote(item, action: suggestion.action) }
                } label: {
                    Label(suggestion.buttonTitle, systemImage: suggestion.symbol).lineLimit(1).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(SamTheme.orb)
                .accessibilityIdentifier("note-act-\(item.id)")
            }
            if item.supports(.seen), item.unread {
                Button {
                    Task { await model.markSeen(item) }
                } label: {
                    Text("Keep").lineLimit(1).fixedSize()
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Keep as note")
                .accessibilityIdentifier("note-keep-\(item.id)")
            }
            if item.supports(.dismiss) {
                Button {
                    Task { await model.dismissNote(item) }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold))
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("note-dismiss-\(item.id)")
            }
        }
        .controlSize(.large)
        .disabled(busy)
    }
}

extension AppModel {
    /// Does a saved note's suggestion (his tap): the Mac starts the T3 task with his words, adds them to the journal,
    /// or puts them on the calendar. The note leaves Needs you.
    func actOnNote(_ item: InboxItem, action: String) async {
        guard let client, item.source == .note else { return }
        busyItems.insert(item.id)
        defer { busyItems.remove(item.id) }
        do {
            let status = try await client.captureAct(item.key, action: action)
            Haptics.success()
            let notice = status.map(CaptureNotice.init) ?? CaptureNotice(tone: .sent, title: "Done", symbol: "checkmark")
            show(.success, notice.title, detail: notice.detail)
            withAnimation(.smooth) { tasks.removeAll { $0.id == item.id } }
            await refresh()
        } catch {
            fail(error)
            await refresh()
        }
    }

    /// Dismisses a saved note: it leaves the list (the inbox's `dismiss`; an older bridge's capture route does it
    /// otherwise).
    func dismissNote(_ item: InboxItem) async {
        guard let client else { return }
        busyItems.insert(item.id)
        defer { busyItems.remove(item.id) }
        let row = tasks.firstIndex { $0.id == item.id }.map { (index: $0, item: tasks[$0]) }
        withAnimation(.smooth) { tasks.removeAll { $0.id == item.id } }
        do {
            try await client.dismissNote(item.id)
            Haptics.tap()
        } catch {
            if let row { withAnimation(.smooth) { tasks.insert(row.item, at: min(row.index, tasks.count)) } }
            fail(error)
        }
        await refresh()
    }
}
