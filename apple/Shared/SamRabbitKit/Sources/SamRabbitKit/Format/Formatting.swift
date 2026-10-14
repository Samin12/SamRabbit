import Foundation

/// Short human strings for times and counts, shared by the app, widgets and watch.
public enum Formatting {
    /// "now", "3 min ago", "2 h ago", "yesterday", "Oct 3".
    public static func ago(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "never" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 { return "now" }
        if seconds < 3600 { return "\(max(1, Int(seconds / 60))) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        if Calendar.current.isDateInYesterday(date) { return "yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "in 25 min", "in 2 h 10 min", "now", "ended" (`short`: "in 25m", "in 2h 10m").
    public static func until(_ date: Date?, end: Date? = nil, now: Date = .now, short: Bool = false) -> String {
        guard let date else { return "" }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 {
            if let end, end > now { return "now" }
            return end == nil ? "now" : "ended"
        }
        // A day or more away (or a far-off date from a bad timestamp): the date itself. Bounded before it becomes an
        // `Int`, which is 32 bits on the Apple Watch.
        guard seconds < 86_400 else { return date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        let minutes = Int((seconds / 60).rounded(.up))
        let (m, h) = short ? ("m", "h") : (" min", " h")
        if minutes < 60 { return "in \(minutes)\(m)" }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours < 24 { return rest == 0 ? "in \(hours)\(h)" : "in \(hours)\(h) \(rest)\(m)" }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// "2:00 PM" (or "All day").
    public static func time(_ date: Date?, allDay: Bool = false) -> String {
        if allDay { return "All day" }
        guard let date else { return "" }
        return date.formatted(.dateTime.hour().minute())
    }

    /// A text's 24-hour clock times in the device's own style, as `time` shows every other time: the Mac writes the
    /// brief's headline with `%H:%M` ("first at 16:00"), which becomes "first at 4:00 PM" (and stays "16:00" where
    /// the clock is 24-hour). Only two-digit hours, what `%H` writes; a time already marked AM/PM or inside a longer
    /// number stays as it is, so running it again changes nothing.
    public static func clockTimes(in text: String, locale: Locale = .current) -> String {
        guard text.contains(":"),
              let regex = try? NSRegularExpression(pattern: #"(?<![\d:.])([01]\d|2[0-3]):([0-5]\d)(?![\d:])(?!\s?[AaPp]\.?\s?[Mm]\b)"#)
        else { return text }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: .gmt).hour().minute()
        var result = ""
        var last = 0
        for match in matches {
            guard let hour = Int(source.substring(with: match.range(at: 1))),
                  let minute = Int(source.substring(with: match.range(at: 2))),
                  let moment = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute))
            else { continue }
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            result += moment.formatted(style)
            last = match.range.location + match.range.length
        }
        return result + source.substring(from: last)
    }

    /// "2:00 – 2:30 PM", "Tomorrow 9:00 AM".
    public static func range(_ start: Date?, _ end: Date?, allDay: Bool = false, now: Date = .now) -> String {
        if allDay { return "All day" }
        guard let start else { return "" }
        let calendar = Calendar.current
        var prefix = ""
        if !calendar.isDate(start, inSameDayAs: now) {
            prefix = calendar.isDateInTomorrow(start) ? "Tomorrow " : start.formatted(.dateTime.weekday(.abbreviated)) + " "
        }
        guard let end else { return prefix + time(start) }
        return prefix + "\(start.formatted(.dateTime.hour().minute())) – \(end.formatted(.dateTime.hour().minute()))"
    }

    /// "30 minutes", "1 hour", "1 h 30 min", "2 hours".
    public static func minutes(_ value: Int) -> String {
        if value < 60 { return value == 1 ? "1 minute" : "\(value) minutes" }
        let hours = value / 60
        let rest = value % 60
        if rest == 0 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        return "\(hours) h \(rest) min"
    }

    /// "1 task", "3 tasks".
    public static func count(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(value) \(value == 1 ? singular : (plural ?? singular + "s"))"
    }

    /// The first line of `text`, at most `limit` characters, with an ellipsis.
    public static func clip(_ text: String?, _ limit: Int) -> String {
        guard let text else { return "" }
        let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return flat.count <= limit ? flat : String(flat.prefix(max(1, limit - 1))) + "…"
    }
}

/// One sentence summaries for Siri, notifications and complications.
public enum SpokenSummary {
    /// "Two tasks need you: approve “Deploy staging” and answer “Fix login”. One is working. Next: Standup at 10:30 AM."
    /// With the inbox's counts in the summary (the iPhone), every agent counts: "… answer “Flaky test” in the terminal".
    public static func whatNeedsMe(_ summary: MobileSummary, now: Date = .now) -> String {
        var parts: [String] = []
        let needsCount: Int
        let details: [String]
        if let inbox = summary.inbox {
            needsCount = inbox.needsYou
            details = inbox.items.filter(\.needsYou).prefix(3).map { item -> String in
                let verb = switch item.status {
                case .needsApproval: "approve"
                case .needsInput: "answer"
                case .error: "check"
                default: "look at"
                }
                let place = switch item.heldOnMac {
                case .waitingInTerminal: " in the terminal"
                case .waitingInApp: " in the Codex app"
                default: ""
                }
                return "\(verb) “\(Formatting.clip(item.title, 48))”\(place)"
            }
        } else {
            let needing = summary.t3.threads.filter(\.status.needsYou)
            needsCount = max(summary.t3.needsYou, needing.count)
            details = needing.prefix(3).map { thread -> String in
                let verb = thread.status == .needsApproval ? "approve" : "answer"
                return "\(verb) “\(Formatting.clip(thread.title, 48))”"
            }
        }
        if needsCount == 0 {
            parts.append("Nothing needs you right now.")
        } else {
            let lead = needsCount == 1 ? "One task needs you" : "\(number(needsCount)) tasks need you"
            parts.append(details.isEmpty ? lead + "." : lead + ": " + list(details) + ".")
        }
        let working = summary.workingCount
        if working > 0 {
            parts.append(working == 1 ? "One is working." : "\(number(working)) are working.")
        }
        if let next = summary.nextEvent(after: now), let start = next.startsAt {
            let when = next.isNow(now) ? "now" : Formatting.until(start, end: next.endsAt, now: now)
            parts.append("Next: \(next.title) \(when).")
        }
        return parts.joined(separator: " ")
    }

    static func number(_ value: Int) -> String {
        let words = ["Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"]
        return value < words.count ? words[value] : String(value)
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}
