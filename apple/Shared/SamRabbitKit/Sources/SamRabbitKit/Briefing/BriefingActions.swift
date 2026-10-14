import Foundation

extension SamRabbitActions {
    /// One verb on a morning-brief item (the widgets' Done and Dismiss, the app's buttons): tells the Mac, then puts
    /// the item's new state into the widgets' copy of the summary at once (Done and Dismiss take it off) and reloads
    /// them. `state`: what the item becomes when the Mac's answer doesn't say.
    @discardableResult
    public func briefingAct(_ itemId: String, action: String, state: BriefingItem.State? = nil) async throws
        -> BriefingActResult {
        let result = try await account.requireClient().briefingAct(itemId, action: action)
        if let entry = cache.load(), var part = entry.summary.briefing {
            let next = result.state ?? state
            if let next, let index = part.items.firstIndex(where: { $0.id == itemId }) {
                let previous = part.items[index]
                if next.closed {
                    part.items.remove(at: index)
                } else {
                    part.items[index].state = next
                }
                if previous.state == .open, next != .open, part.needsYou > 0,
                   previous.section == .doFirst || previous.section == .agents {
                    part.needsYou -= 1
                }
                var summary = entry.summary
                summary.briefing = part
                cache.publish(summary)
            }
        }
        return result
    }
}
