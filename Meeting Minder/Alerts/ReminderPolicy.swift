import Foundation

/// The "bring this back later" offers on the blocker.
///
/// Every reminder is anchored to the meeting's start time, never to the moment the button was
/// pressed — pressing at four minutes out and at two minutes out both return the alert at the
/// same instant. The view and the scheduler both read this policy, so what a button promises
/// and what actually gets scheduled cannot drift apart.
enum ReminderPolicy {

    enum Option: CaseIterable {
        case oneMinuteBefore
        case atStart

        /// How far ahead of the start the alert returns. Zero means at the start itself.
        var secondsBeforeStart: TimeInterval {
            switch self {
            case .oneMinuteBefore: return 60
            case .atStart: return 0
            }
        }

        var buttonTitle: String {
            switch self {
            case .oneMinuteBefore: return "Remind me 1 minute before"
            case .atStart: return "Remind me at meeting time"
            }
        }
    }

    /// A reminder any closer than this to the present would re-fire on the next tick,
    /// which reads as the alert refusing to go away.
    private static let minimumLeadIn: TimeInterval = 5

    /// Joining inside this window of the start counts as joining on time — a nudge seconds
    /// later would be noise rather than a save. Kept short so a join from the "1 minute
    /// before" reminder, which spends a minute checking audio and video, still gets the
    /// on-time nudge.
    static let earlyJoinThreshold: TimeInterval = 10

    static func remindDate(forStart start: Date, option: Option) -> Date {
        start.addingTimeInterval(-option.secondsBeforeStart)
    }

    /// False once the meeting is too close for this reminder to land in the future.
    static func canRemind(start: Date, now: Date, option: Option) -> Bool {
        remindDate(forStart: start, option: option).timeIntervalSince(now) > minimumLeadIn
    }

    /// The reminders still worth offering, soonest first.
    static func availableOptions(start: Date, now: Date) -> [Option] {
        Option.allCases.filter { canRemind(start: start, now: now, option: $0) }
    }

    /// Whether joining now is early enough that the user could plausibly drift away and
    /// forget the meeting ever starts.
    static func shouldRemindAfterEarlyJoin(start: Date, now: Date) -> Bool {
        start.timeIntervalSince(now) > earlyJoinThreshold
    }
}
