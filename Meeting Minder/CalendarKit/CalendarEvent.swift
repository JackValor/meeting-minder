import Foundation

struct CalendarEvent: Identifiable, Equatable {
    /// Stable per occurrence. The start time is part of the identity so that moving a
    /// meeting produces a fresh alert rather than inheriting an earlier dismissal.
    let id: String
    let calendarID: String
    let calendarTitle: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let meetingLink: MeetingLink?
    let htmlLink: URL?
    let organizer: String?
    let attendeeCount: Int
    let isDeclined: Bool

    var displayTitle: String {
        title.isEmpty ? "(No title)" : title
    }

    func isInProgress(at date: Date) -> Bool {
        date >= start && date < end
    }

    func hasEnded(at date: Date) -> Bool {
        date >= end
    }

    var timeRangeDescription: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let startText = formatter.string(from: start)
        let endText = formatter.string(from: end)

        if Calendar.current.isDateInToday(start) {
            return "\(startText) – \(endText)"
        }
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = Calendar.current.isDateInTomorrow(start) ? "'Tomorrow'" : "EEE d MMM"
        return "\(dayFormatter.string(from: start)), \(startText) – \(endText)"
    }
}

enum RelativeTime {
    /// "in 4 min" / "in 45 sec" / "now" / "started 2 min ago"
    static func description(from now: Date, to start: Date) -> String {
        let seconds = start.timeIntervalSince(now)

        if seconds <= 0 {
            let elapsed = Int((-seconds) / 60)
            if elapsed < 1 { return "starting now" }
            return "started \(elapsed) min ago"
        }
        if seconds < 60 {
            return "in \(Int(seconds.rounded(.up))) sec"
        }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "in \(minutes) min" }

        let hours = minutes / 60
        let remainder = minutes % 60
        if remainder == 0 { return "in \(hours) hr" }
        return "in \(hours) hr \(remainder) min"
    }

    /// Compact form for the menu bar: "in 4m".
    static func compact(from now: Date, to start: Date) -> String? {
        let seconds = start.timeIntervalSince(now)
        guard seconds > 0 else { return "now" }
        let minutes = Int((seconds / 60).rounded(.up))
        guard minutes <= 60 else { return nil }
        return minutes <= 1 ? "in 1m" : "in \(minutes)m"
    }

    /// mm:ss countdown used on the blocker.
    static func countdown(from now: Date, to start: Date) -> String {
        let seconds = Int(start.timeIntervalSince(now).rounded())
        guard seconds > 0 else { return "00:00" }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
