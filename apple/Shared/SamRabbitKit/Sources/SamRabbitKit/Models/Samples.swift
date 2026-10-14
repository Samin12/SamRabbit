import Foundation

extension MobileSummary {
    /// Believable sample data for widget placeholders, gallery previews and SwiftUI previews
    /// (never shown as real data: widgets use it only for `placeholder` and the widget picker).
    public static func sample(now: Date = .now) -> MobileSummary {
        let minute: TimeInterval = 60
        let base = now.addingTimeInterval(-now.timeIntervalSince1970.truncatingRemainder(dividingBy: 300))
        return MobileSummary(
            generatedAt: now,
            mac: MacStatus(name: "Samin's MacBook Pro", online: true, screenLocked: false),
            r1: R1Status(lastSeenAt: now.addingTimeInterval(-3 * minute), live: false),
            t3: TaskOverview(available: true, needsYou: 2, working: 2, threads: [
                TaskThread(threadId: "s1", title: "Deploy release 2.4 to staging", projectName: "Assistant",
                           status: .needsApproval, updatedAt: now.addingTimeInterval(-2 * minute),
                           summary: "Build 2.4.0-rc1 is ready; waiting for approval."),
                TaskThread(threadId: "s2", title: "Fix login redirect", projectName: "Website", status: .needsInput,
                           updatedAt: now.addingTimeInterval(-5 * minute), summary: "One question about the default page."),
                TaskThread(threadId: "s3", title: "Weekly report from Linear", projectName: "Assistant", status: .working,
                           updatedAt: now.addingTimeInterval(-40), summary: "Collecting closed issues…"),
                TaskThread(threadId: "s4", title: "Refactor calendar sync", projectName: "SamRabbit", status: .working,
                           updatedAt: now.addingTimeInterval(-90), summary: "2 of 5 files done."),
                TaskThread(threadId: "s5", title: "Pricing page copy", projectName: "Website", status: .done,
                           updatedAt: now.addingTimeInterval(-30 * minute), summary: "PR #42 is ready."),
            ]),
            calendar: CalendarOverview(available: true, next: [
                CalendarEvent(title: "Standup", startsAt: base.addingTimeInterval(25 * minute),
                              endsAt: base.addingTimeInterval(40 * minute), meetingUrl: URL(string: "https://meet.google.com/abc")),
                CalendarEvent(title: "Lunch with Maya", startsAt: base.addingTimeInterval(125 * minute),
                              endsAt: base.addingTimeInterval(185 * minute), location: "Blue Bottle, Hayes St"),
                CalendarEvent(title: "Design review", startsAt: base.addingTimeInterval(245 * minute),
                              endsAt: base.addingTimeInterval(290 * minute)),
            ]),
            latestConversation: ConversationPreview(conversationId: "c_sample", title: "Weekly focus review",
                                                    lastAt: now.addingTimeInterval(-6 * minute),
                                                    preview: "You logged 18.5 hours of deep work, 3.2 more than last week."),
            journal: JournalStatus(available: true),
            inbox: InboxOverview(needsYou: 4, working: 3, total: 9, items: [
                InboxItem(id: "t3:s1", source: .t3, agent: "claude", title: "Deploy release 2.4 to staging",
                          project: "Assistant", status: .needsApproval, statusLabel: "Wants to run a command",
                          summary: "Run ./deploy.sh staging", updatedAt: now.addingTimeInterval(-2 * minute),
                          unread: true, can: ["approve", "reply", "stop", "seen"]),
                InboxItem(id: "claude:sample-flaky", source: .claude, agent: "claude",
                          title: "Investigate the flaky long-poll test", project: "jackrabbit-src",
                          status: .needsApproval, statusLabel: "Waiting for you in the terminal",
                          summary: "Bash: python3 -I -m unittest -k long_poll",
                          updatedAt: now.addingTimeInterval(-3 * minute), unread: true,
                          pending: InboxPending(approvals: [InboxApproval(requestId: "toolu_sample", kind: "command")]),
                          can: ["open"], live: true),
                InboxItem(id: "t3:s2", source: .t3, agent: "codex", title: "Fix login redirect", project: "Website",
                          status: .needsInput, statusLabel: "Has a question", summary: "Where should people land?",
                          updatedAt: now.addingTimeInterval(-5 * minute), unread: true, can: ["answer", "reply"]),
                InboxItem(id: "codex:sample-widgets", source: .codex, agent: "codex",
                          title: "Speed up the widget timeline", project: "jackrabbit-src", status: .done,
                          statusLabel: "Finished", summary: "First paint: 1.9 s → 0.2 s.",
                          updatedAt: now.addingTimeInterval(-25 * minute), unread: true,
                          can: ["reply", "open", "seen"]),
                InboxItem(id: "t3:s3", source: .t3, agent: "claude", title: "Weekly report from Linear",
                          project: "Assistant", status: .working, statusLabel: "Working",
                          summary: "Collecting closed issues…", updatedAt: now.addingTimeInterval(-40),
                          can: ["reply", "stop"]),
            ]),
            briefing: Briefing.sample(now: now).overview(),
            captures: CapturesOverview(recent: [
                .init(captureId: "0d196ba8-190f-4ee5-b248-0f2c76bf13a8", state: .done, kind: .journal, title: "Journal",
                      say: "Added to your journal.", at: now.addingTimeInterval(-240)),
            ]))
    }
}
