import Foundation
import Testing
@testable import Meeting_Minder

// MARK: - Meeting link detection

@Suite("Meeting link detection")
struct MeetingLinkDetectionTests {

    @Test("Finds a Google Meet link in a description")
    func findsGoogleMeet() throws {
        let description = """
        Hi all,<br>Join with Google Meet: https://meet.google.com/abc-defg-hij<br>Or dial in.
        """
        let link = try #require(MeetingLinkDetector.firstLink(in: description))
        #expect(link.provider == .googleMeet)
        #expect(link.url.absoluteString == "https://meet.google.com/abc-defg-hij")
    }

    @Test("Finds a Zoom link on a company subdomain in the location field")
    func findsZoom() throws {
        let link = try #require(MeetingLinkDetector.firstLink(in: "https://valorstudio.zoom.us/j/98765432101?pwd=Ab1Cd2"))
        #expect(link.provider == .zoom)
        #expect(link.url.absoluteString.contains("pwd=Ab1Cd2"))
    }

    @Test("Finds a Microsoft Teams meetup-join link")
    func findsTeams() throws {
        let text = "Microsoft Teams meeting: https://teams.microsoft.com/l/meetup-join/19%3ameeting_ABC%40thread.v2/0?context=%7b%22Tid%22%3a%22x%22%7d"
        let link = try #require(MeetingLinkDetector.firstLink(in: text))
        #expect(link.provider == .microsoftTeams)
    }

    @Test("Decodes HTML entities so query strings survive")
    func decodesEntities() throws {
        let link = try #require(MeetingLinkDetector.firstLink(in: "https://acme.zoom.us/j/123456789?pwd=xyz&amp;uname=jack"))
        #expect(link.url.absoluteString.contains("&uname=jack"))
        #expect(!link.url.absoluteString.contains("&amp;"))
    }

    @Test("Strips punctuation that trails a URL in prose")
    func trimsTrailingPunctuation() throws {
        let link = try #require(MeetingLinkDetector.firstLink(in: "Join at https://meet.google.com/xyz-abcd-efg."))
        #expect(link.url.absoluteString.hasSuffix("efg"))
    }

    @Test("Returns the earliest link when several are present")
    func picksEarliestLink() throws {
        let text = "Primary: https://meet.google.com/aaa-bbbb-ccc — backup: https://acme.zoom.us/j/111222333"
        let link = try #require(MeetingLinkDetector.firstLink(in: text))
        #expect(link.provider == .googleMeet)
    }

    @Test("Ignores text with no conference link")
    func ignoresPlainText() {
        #expect(MeetingLinkDetector.firstLink(in: "Room 4, second floor. Bring the roadmap.") == nil)
        #expect(MeetingLinkDetector.firstLink(in: "") == nil)
        #expect(MeetingLinkDetector.firstLink(in: nil) == nil)
    }

    @Test("Does not mistake a Zoom marketing page for a meeting")
    func ignoresNonMeetingZoomURL() {
        #expect(MeetingLinkDetector.firstLink(in: "See https://zoom.us/pricing for plans") == nil)
    }

    @Test("Classifies providers from a structured conference URL", arguments: [
        ("https://meet.google.com/abc", MeetingProvider.googleMeet),
        ("https://teams.microsoft.com/l/meetup-join/x", .microsoftTeams),
        ("https://teams.live.com/meet/123", .microsoftTeams),
        ("https://acme.zoom.us/j/1", .zoom),
        ("https://acme.webex.com/meet/jack", .webex),
        ("https://whereby.com/valor", .other),
    ])
    func classifiesProviders(url: String, expected: MeetingProvider) {
        #expect(MeetingLinkDetector.provider(for: url) == expected)
    }
}

// MARK: - Countdown formatting

@Suite("Relative time formatting")
struct RelativeTimeTests {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    @Test("Menu bar shows a compact countdown only inside the next hour")
    func compactWithinTheHour() {
        #expect(RelativeTime.compact(from: now, to: now.addingTimeInterval(5 * 60)) == "in 5m")
        #expect(RelativeTime.compact(from: now, to: now.addingTimeInterval(59 * 60)) == "in 59m")
        // Anything beyond an hour shows the title alone.
        #expect(RelativeTime.compact(from: now, to: now.addingTimeInterval(61 * 60)) == nil)
        #expect(RelativeTime.compact(from: now, to: now.addingTimeInterval(5 * 3600)) == nil)
    }

    @Test("Compact form rounds up and collapses to 'now' once started")
    func compactEdges() {
        #expect(RelativeTime.compact(from: now, to: now.addingTimeInterval(90)) == "in 2m")
        #expect(RelativeTime.compact(from: now, to: now.addingTimeInterval(20)) == "in 1m")
        #expect(RelativeTime.compact(from: now, to: now) == "now")
        #expect(RelativeTime.compact(from: now, to: now.addingTimeInterval(-120)) == "now")
    }

    @Test("Long form describes both sides of the start time")
    func longForm() {
        #expect(RelativeTime.description(from: now, to: now.addingTimeInterval(4 * 60)) == "in 4 min")
        #expect(RelativeTime.description(from: now, to: now.addingTimeInterval(30)) == "in 30 sec")
        #expect(RelativeTime.description(from: now, to: now.addingTimeInterval(3600)) == "in 1 hr")
        #expect(RelativeTime.description(from: now, to: now.addingTimeInterval(5400)) == "in 1 hr 30 min")
        #expect(RelativeTime.description(from: now, to: now) == "starting now")
        #expect(RelativeTime.description(from: now, to: now.addingTimeInterval(-180)) == "started 3 min ago")
    }

    @Test("Countdown is a zero-padded mm:ss that never goes negative")
    func countdown() {
        #expect(RelativeTime.countdown(from: now, to: now.addingTimeInterval(272)) == "04:32")
        #expect(RelativeTime.countdown(from: now, to: now.addingTimeInterval(9)) == "00:09")
        #expect(RelativeTime.countdown(from: now, to: now.addingTimeInterval(-50)) == "00:00")
    }
}

// MARK: - Menu bar title

@Suite("Menu bar title truncation")
struct TruncationTests {

    @Test("Leaves short titles untouched")
    func shortTitle() {
        #expect("Standup".truncated(to: 28) == "Standup")
    }

    @Test("Truncates long titles with an ellipsis inside the budget")
    func longTitle() {
        let result = "Quarterly Business Review with the Platform Team".truncated(to: 28)
        #expect(result.count <= 28)
        #expect(result.hasSuffix("…"))
        #expect(result.hasPrefix("Quarterly Business"))
    }

    @Test("Trims surrounding whitespace")
    func trimsWhitespace() {
        #expect("  Standup  ".truncated(to: 28) == "Standup")
    }

    @Test("Strips HTML down to readable text")
    func stripsHTML() {
        #expect("<p>Join <b>now</b> &amp; say hi</p>".strippingHTML() == "Join now & say hi")
    }
}

// MARK: - Reminder policy

@Suite("Reminder policy")
struct ReminderPolicyTests {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    @Test("Reminders are anchored to the meeting start, not to when the button was pressed")
    func anchoredToStart() {
        let start = now.addingTimeInterval(5 * 60)
        // Pressing at five minutes out and at two minutes out must land on the same instant.
        let pressedEarly = ReminderPolicy.remindDate(forStart: start, option: .oneMinuteBefore)
        let pressedLate = ReminderPolicy.remindDate(forStart: start, option: .oneMinuteBefore)
        #expect(pressedEarly == pressedLate)
        #expect(pressedEarly == start.addingTimeInterval(-60))
    }

    @Test("'At meeting time' lands exactly on the start")
    func atStartLandsOnStart() {
        let start = now.addingTimeInterval(5 * 60)
        #expect(ReminderPolicy.remindDate(forStart: start, option: .atStart) == start)
    }

    @Test("Both options are offered while the meeting is far enough out")
    func bothOffered() {
        #expect(ReminderPolicy.availableOptions(start: now.addingTimeInterval(5 * 60), now: now)
                == [.oneMinuteBefore, .atStart])
        #expect(ReminderPolicy.availableOptions(start: now.addingTimeInterval(2 * 60), now: now)
                == [.oneMinuteBefore, .atStart])
    }

    @Test("'1 minute before' withdraws first, leaving 'at meeting time'")
    func oneMinuteBeforeWithdrawsFirst() {
        // Inside 65s the one-minute reminder could not land in the future any more.
        #expect(ReminderPolicy.availableOptions(start: now.addingTimeInterval(61), now: now) == [.atStart])
        #expect(ReminderPolicy.availableOptions(start: now.addingTimeInterval(30), now: now) == [.atStart])
        #expect(ReminderPolicy.availableOptions(start: now.addingTimeInterval(6), now: now) == [.atStart])
    }

    @Test("Both withdraw once the meeting is upon you")
    func bothWithdraw() {
        #expect(ReminderPolicy.availableOptions(start: now.addingTimeInterval(5), now: now).isEmpty)
        #expect(ReminderPolicy.availableOptions(start: now, now: now).isEmpty)
        #expect(ReminderPolicy.availableOptions(start: now.addingTimeInterval(-120), now: now).isEmpty)
    }

    @Test("Joining well before the start re-arms for meeting time")
    func earlyJoinRearms() {
        #expect(ReminderPolicy.shouldRemindAfterEarlyJoin(start: now.addingTimeInterval(5 * 60), now: now))
        #expect(ReminderPolicy.shouldRemindAfterEarlyJoin(start: now.addingTimeInterval(60), now: now))
    }

    @Test("Joining on time is treated as a dismissal, not a deferral")
    func onTimeJoinDoesNotRearm() {
        // A nudge seconds after a deliberate join would be noise, not a save.
        #expect(!ReminderPolicy.shouldRemindAfterEarlyJoin(start: now.addingTimeInterval(59), now: now))
        #expect(!ReminderPolicy.shouldRemindAfterEarlyJoin(start: now.addingTimeInterval(10), now: now))
        #expect(!ReminderPolicy.shouldRemindAfterEarlyJoin(start: now, now: now))
        #expect(!ReminderPolicy.shouldRemindAfterEarlyJoin(start: now.addingTimeInterval(-300), now: now))
    }

    @Test("Button titles say what they do")
    func buttonTitles() {
        #expect(ReminderPolicy.Option.oneMinuteBefore.buttonTitle == "Remind me 1 minute before")
        #expect(ReminderPolicy.Option.atStart.buttonTitle == "Remind me at meeting time")
    }
}
