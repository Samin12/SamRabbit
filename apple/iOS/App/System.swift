import ActivityKit
import BackgroundTasks
import Foundation
import os
import SamRabbitKit
import UserNotifications

private let log = Logger(subsystem: "com.samrabbit.mobile", category: "system")

/// Local notifications (no push: the bridge has no APNs). Each T3 request that needs you (keyed by
/// thread and request id, shared with the background refresh through the App Group), each Claude Code or Codex
/// prompt waiting in its terminal or app (keyed by item and tool call), and each task started from the phone that
/// finishes is announced once.
final class NotificationController: Sendable {
    private let tracker = TaskTracker.shared

    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    var authorized: Bool {
        get async {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        }
    }

    /// Plans and posts what changed since the last check. `agents`: the inbox's Claude Code and Codex items;
    /// `needsYou`: the app icon's badge (every agent that needs you, from the inbox; T3's waiting threads without it).
    func check(threads: [TaskThread], agents: [InboxItem] = [], needsYou: Int? = nil) async {
        let plan = AlertPlanner.plan(threads: threads, agents: agents, announced: tracker.announced,
                                     tracked: tracker.tasks)
        tracker.setAnnounced(plan.announced)
        tracker.update(plan.tracked)
        guard !plan.alerts.isEmpty, await authorized else { return }
        for alert in plan.alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = Self.alertSound
            content.threadIdentifier = "samrabbit.tasks"
            content.userInfo = ["url": alert.link]
            content.interruptionLevel = alert.kind == .needsYou ? .timeSensitive : .active
            let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
        try? await UNUserNotificationCenter.current().setBadgeCount(needsYou ?? threads.filter(\.status.needsYou).count)
    }

    /// Talk's rule: the simulator plays nothing out loud unless `-SamRabbitAudioOut on`, so its alerts come silent
    /// (the UI tests' needs-you rows would otherwise chime through the Mac).
    static var alertSound: UNNotificationSound? {
        #if targetEnvironment(simulator)
        UserDefaults.standard.string(forKey: "SamRabbitAudioOut") == "on" ? .default : nil
        #else
        .default
        #endif
    }
}

/// Shows banners in the foreground and opens the thread when one is tapped.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let url = response.notification.request.content.userInfo["url"] as? String, let link = URL(string: url) {
            await MainActor.run { UIApplicationOpener.open(link) }
        }
    }
}

import UIKit

@MainActor
enum UIApplicationOpener {
    static func open(_ url: URL) {
        UIApplication.shared.open(url)
    }
}

/// `BGAppRefreshTask`: polls the summary about every 15 minutes in the background, posts local
/// notifications and moves the Live Activities along.
enum BackgroundRefresh {
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: SamRabbit.backgroundRefreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.notice("background refresh not scheduled: \(String(describing: error), privacy: .public)")
        }
    }

    static func run() async {
        schedule()
        let account = BridgeAccount.shared
        guard let client = account.client() else { return }
        do {
            // The inbox beside the summary: the widgets and the badge count every agent on the Mac.
            async let inboxCall = BridgeError.capture { try await client.inbox(timeout: 15) }
            let fresh = try await client.summary(timeout: 15)
            let inbox = await inboxCall
            let summary = fresh.with(inbox: inbox, kept: SummaryCache.shared.load()?.summary.inbox)
            let agents = (try? inbox.get())?.agentItems.filter { $0.source != .t3 } ?? []
            SummaryCache.shared.publish(summary) // reloads the widgets only when something changed
            var threads = summary.t3.threads
            // What waits for you comes from the thread list: its entries carry the request ids the
            // notifications are keyed on (summary threads don't, so they are never announced), the
            // same keys the foreground app uses: a request is announced once, by whichever runs first.
            var complete = true
            if summary.t3.needsYou > 0 {
                if let waiting = try? await client.threads(filter: .needsYou) {
                    let ids = Set(waiting.map(\.threadId))
                    threads = waiting + threads.filter { !ids.contains($0.threadId) && !$0.status.needsYou }
                } else {
                    complete = false
                }
            }
            // Tasks started from the phone that fell out of the summary's top five.
            let known = Set(threads.map(\.threadId))
            for task in TaskTracker.shared.tasks where !known.contains(task.threadId) {
                if let detail = try? await client.thread(task.threadId) { threads.append(detail.thread) }
            }
            if complete {
                await NotificationController().check(threads: threads, agents: agents, needsYou: summary.inbox?.needsYou)
            }
            await LiveActivityController().update(with: threads)
        } catch {
            log.notice("background refresh failed")
        }
    }
}

/// "Task running" Live Activities for tasks started from this phone.
final class LiveActivityController: Sendable {
    func start(threadId: String, title: String, projectName: String) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = TaskActivityAttributes(threadId: threadId, title: title, projectName: projectName)
        let state = TaskActivityAttributes.ContentState(status: .working, detail: "Starting…")
        do {
            _ = try Activity.request(attributes: attributes,
                                     content: ActivityContent(state: state, staleDate: .now.addingTimeInterval(30 * 60)))
        } catch {
            log.notice("live activity not started: \(String(describing: error), privacy: .public)")
        }
    }

    func update(with threads: [TaskThread]) async {
        let byId = Dictionary(threads.map { ($0.threadId, $0) }, uniquingKeysWith: { first, _ in first })
        for activity in Activity<TaskActivityAttributes>.activities {
            guard let thread = byId[activity.attributes.threadId] else { continue }
            let state = TaskActivityAttributes.ContentState(status: thread.status,
                                                            detail: thread.pending?.text ?? thread.summary ?? thread.status.label,
                                                            updatedAt: thread.updatedAt ?? .now)
            if state.status == activity.content.state.status, state.detail == activity.content.state.detail { continue }
            let content = ActivityContent(state: state, staleDate: .now.addingTimeInterval(30 * 60))
            if thread.status == .done || thread.status == .error || thread.status == .idle {
                await activity.end(content, dismissalPolicy: .after(.now.addingTimeInterval(15 * 60)))
            } else {
                await activity.update(content)
            }
        }
    }

    func endAll() async {
        for activity in Activity<TaskActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
