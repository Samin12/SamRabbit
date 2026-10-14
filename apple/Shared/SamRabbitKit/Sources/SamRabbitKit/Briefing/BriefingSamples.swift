import Foundation

extension Briefing {
    /// A believable morning brief for widget placeholders, the gallery and previews (never shown as real data).
    public static func sample(now: Date = .now) -> Briefing {
        let hour: TimeInterval = 3600
        let today = Calendar.current.startOfDay(for: now)
        return Briefing(
            available: true, date: BriefingClock.day(of: now), revision: 1, status: .ready,
            headline: "3 things need you · 4 meetings, first at 10:00",
            spoken: "Good morning. Dana needs the SOW signed by Friday, a Stripe payout failed, and Acme reported checkout "
                + "errors. Four meetings today, the first at ten.",
            updatedAt: today.addingTimeInterval(7 * hour + 60),
            items: [
                BriefingItem(id: "bi_sample_dana", section: .doFirst, kind: "email", account: "business",
                             title: "Reply to Dana about the SOW", why: "She needs it signed by Friday; asked twice",
                             suggestion: "Draft a reply confirming Thu 2 pm",
                             actions: [BriefingAction(.draftReply), BriefingAction(.remind, label: "Remind 2 pm")],
                             priority: 1),
                BriefingItem(id: "bi_sample_payout", section: .doFirst, kind: "email", account: "business",
                             title: "Fix the failed Stripe payout", why: "Bank details rejected; $1,240 on hold",
                             actions: [BriefingAction(.open), BriefingAction(.remind, label: "Remind 2 pm")], priority: 1),
                BriefingItem(id: "bi_sample_acme", section: .doFirst, kind: "email", account: "personal",
                             title: "Look into Acme's checkout errors", why: "Two customers saw 500s since last night",
                             actions: [BriefingAction(.makeTask), BriefingAction(.draftReply)], priority: 2),
                BriefingItem(id: "bi_sample_standup", section: .today, kind: "event", title: "Standup",
                             why: "10:00 · overlaps the dentist", actions: [BriefingAction(.blockTime)],
                             startsAt: today.addingTimeInterval(10 * hour), endsAt: today.addingTimeInterval(10.25 * hour),
                             conflict: true),
                BriefingItem(id: "bi_sample_review", section: .today, kind: "event", title: "Design review",
                             why: "2:00 PM · Dana sent the deck", startsAt: today.addingTimeInterval(14 * hour),
                             endsAt: today.addingTimeInterval(15 * hour)),
                BriefingItem(id: "bi_sample_deploy", section: .agents, kind: "agent",
                             title: "Approve the staging deploy", why: "T3 · Assistant wants to run ./deploy.sh staging",
                             actions: [BriefingAction(.open)], inboxItemId: "t3:s1"),
                BriefingItem(id: "bi_sample_payout_in", section: .fyi, kind: "fyi", title: "Stripe payout arrived",
                             why: "$3,420 landed in checking"),
            ],
            footer: "Skipped 182 promos and newsletters")
    }
}
