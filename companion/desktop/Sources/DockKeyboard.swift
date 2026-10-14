import Foundation

// The expanded panel's keyboard, when the panel is the key window and no text field has the keys:
// J/K or ↓/↑ move, Enter expands (and on an expanded row, opens it), E approves with the recommended option,
// R replies, N goes to the compose field, Esc closes the row and then the panel. ⌘+/⌘−/⌘0 size the dock.
// Pure: the panel turns NSEvents into DockKey and carries out the DockKeyAction this answers.

enum DockKey: Equatable {
    case down, up, enter, approve, reply, compose, escape, zoomIn, zoomOut, zoomReset
}

extension DockKey {
    /// Key code / characters / modifiers to a key the panel understands (nil = not ours, let it through).
    static func from(keyCode: UInt16, characters: String, command: Bool, control: Bool, option: Bool) -> DockKey? {
        if command {
            switch characters {
            case "=", "+": return .zoomIn
            case "-", "_": return .zoomOut
            case "0": return .zoomReset
            default: return nil
            }
        }
        if control || option { return nil }
        switch keyCode {
        case 125: return .down
        case 126: return .up
        case 36, 76: return .enter
        case 53: return .escape
        default: break
        }
        switch characters.lowercased() {
        case "j": return .down
        case "k": return .up
        case "e": return .approve
        case "r": return .reply
        case "n": return .compose
        default: return nil
        }
    }
}

/// What a row allows, as far as the keyboard is concerned.
struct DockKeyRow: Equatable {
    let id: String
    var canOpen = false
    var canReply = false
    /// The approval E would answer, with its recommended decision.
    var approval: (requestId: String, decision: String)?

    static func == (a: DockKeyRow, b: DockKeyRow) -> Bool {
        a.id == b.id && a.canOpen == b.canOpen && a.canReply == b.canReply
            && a.approval?.requestId == b.approval?.requestId && a.approval?.decision == b.approval?.decision
    }

    init(id: String, canOpen: Bool = false, canReply: Bool = false, approval: (requestId: String, decision: String)? = nil) {
        self.id = id
        self.canOpen = canOpen
        self.canReply = canReply
        self.approval = approval
    }

    init(_ item: DockItem) {
        id = item.id
        canOpen = item.supports("open")
        canReply = item.supports("reply")
        if item.supports("approve"), let approval = item.firstApproval, let option = approval.recommended {
            self.approval = (approval.requestId, option.decision)
        }
    }
}

enum DockKeyAction: Equatable {
    case none
    case select(String)
    case expand(String)
    case collapseRow
    case open(String)
    case approve(id: String, requestId: String, decision: String)
    case reply(String)
    case compose
    case collapsePanel
    case zoom(Int)  // +1, −1, 0 = reset
}

enum DockKeyboard {
    static func action(for key: DockKey, rows: [DockKeyRow], selected: String?, expanded: String?) -> DockKeyAction {
        let index = selected.flatMap { id in rows.firstIndex { $0.id == id } }
        switch key {
        case .down:
            guard !rows.isEmpty else { return .none }
            guard let index else { return .select(rows[0].id) }
            return .select(rows[min(rows.count - 1, index + 1)].id)
        case .up:
            guard !rows.isEmpty else { return .none }
            guard let index else { return .select(rows[0].id) }
            return .select(rows[max(0, index - 1)].id)
        case .enter:
            guard let index else { return rows.isEmpty ? .none : .select(rows[0].id) }
            let row = rows[index]
            if row.id == expanded { return row.canOpen ? .open(row.id) : .none }
            return .expand(row.id)
        case .approve:
            // The selected row, or when nothing is selected the first one waiting on an approval.
            let row = index.map { rows[$0] } ?? rows.first { $0.approval != nil }
            guard let row, let approval = row.approval else { return .none }
            return .approve(id: row.id, requestId: approval.requestId, decision: approval.decision)
        case .reply:
            guard let index, rows[index].canReply else { return .none }
            return .reply(rows[index].id)
        case .compose:
            return .compose
        case .escape:
            return expanded != nil ? .collapseRow : .collapsePanel
        case .zoomIn:
            return .zoom(1)
        case .zoomOut:
            return .zoom(-1)
        case .zoomReset:
            return .zoom(0)
        }
    }
}
