import AppKit
import Foundation
import os

/// Decides when the blocker should appear, and remembers per-occurrence dismiss/remind state.
@MainActor
final class AlertScheduler {

    /// Keep alerting for a short while after a meeting has started, so a machine that was
    /// asleep through the warning window still surfaces the meeting you are late for.
    private static let graceAfterStart: TimeInterval = 120
    private static let tickInterval: TimeInterval = 1

    struct EventState {
        var dismissed = false
        /// When the alert should come back, anchored to the meeting start.
        var remindAt: Date?
        var lastShownAt: Date?
    }

    private let store: CalendarStore
    private let settings: AppSettings
    private var states: [String: EventState] = [:]
    private var timer: Timer?
    private var isPreview = false

    private(set) var presentedEvent: CalendarEvent?

    var onPresent: ((CalendarEvent) -> Void)?
    var onUpdate: ((CalendarEvent) -> Void)?
    var onHide: (() -> Void)?

    init(store: CalendarStore, settings: AppSettings = .shared) {
        self.store = store
        self.settings = settings
    }

    func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Evaluation

    private func tick() {
        let now = Date()
        pruneStates(now: now)

        if let presented = presentedEvent {
            guard !isPreview else { return }
            // The meeting was deleted, moved, or has run its course.
            guard let current = store.event(withID: presented.id), !current.hasEnded(at: now) else {
                hide()
                return
            }
            if current != presented {
                presentedEvent = current
                onUpdate?(current)
            }
            return
        }

        // `store.events` is sorted by start, so the first due event is the most urgent.
        guard let due = store.events.first(where: { isDue($0, now: now) }) else { return }
        present(due)
    }

    func isDue(_ event: CalendarEvent, now: Date = Date()) -> Bool {
        guard !event.isAllDay, !event.hasEnded(at: now) else { return false }

        let state = states[event.id] ?? EventState()
        if state.dismissed { return false }

        if let remindAt = state.remindAt {
            return now >= remindAt
        }

        let lead = TimeInterval(settings.leadTimeMinutes * 60)
        return now >= event.start.addingTimeInterval(-lead)
            && now < event.start.addingTimeInterval(Self.graceAfterStart)
    }

    private func present(_ event: CalendarEvent) {
        presentedEvent = event
        var state = states[event.id] ?? EventState()
        state.lastShownAt = Date()
        state.remindAt = nil
        states[event.id] = state

        Log.alerts.info("Presenting alert for \"\(event.displayTitle, privacy: .public)\"")
        playSound()
        onPresent?(event)
    }

    private func hide() {
        presentedEvent = nil
        isPreview = false
        onHide?()
    }

    // MARK: - User actions

    func dismissCurrent() {
        guard let event = presentedEvent else { return }
        if !isPreview {
            var state = states[event.id] ?? EventState()
            state.dismissed = true
            state.remindAt = nil
            states[event.id] = state
        }
        hide()
    }

    /// Brings the alert back at a point anchored to the meeting start.
    func remind(_ option: ReminderPolicy.Option) {
        guard let event = presentedEvent else { return }

        // Too close to the start for this reminder to be worth anything — the button is
        // hidden by then, so this only guards against a race on the last tick.
        guard ReminderPolicy.canRemind(start: event.start, now: Date(), option: option) else {
            dismissCurrent()
            return
        }

        scheduleReminder(for: event, at: ReminderPolicy.remindDate(forStart: event.start, option: option))
        Log.alerts.info("Will re-alert \"\(event.displayTitle, privacy: .public)\" — \(option.buttonTitle, privacy: .public)")
        hide()
    }

    private func scheduleReminder(for event: CalendarEvent, at date: Date) {
        guard !isPreview else { return }
        var state = states[event.id] ?? EventState()
        state.remindAt = date
        state.dismissed = false
        states[event.id] = state
    }

    func joinCurrent() {
        guard let event = presentedEvent, let link = event.meetingLink else {
            dismissCurrent()
            return
        }
        NSWorkspace.shared.open(link.url)

        // Joining early is the easiest way to lose a meeting: you land in the tab, switch
        // away to fill the wait, and never notice it start. Re-arm for the start time
        // instead of treating the join as a dismissal.
        if ReminderPolicy.shouldRemindAfterEarlyJoin(start: event.start, now: Date()) {
            scheduleReminder(for: event, at: event.start)
            Log.alerts.info("Joined early — will re-alert \"\(event.displayTitle, privacy: .public)\" at start")
            hide()
        } else {
            dismissCurrent()
        }
    }

    // MARK: - Preview

    /// Shows a sample blocker so the alert can be checked without waiting for a meeting.
    func showPreview() {
        guard presentedEvent == nil else { return }
        let now = Date()
        let sample = CalendarEvent(
            id: "preview",
            calendarID: "preview",
            calendarTitle: "Preview",
            title: "Sample Meeting — this is what an alert looks like",
            start: now.addingTimeInterval(TimeInterval(settings.leadTimeMinutes * 60)),
            end: now.addingTimeInterval(TimeInterval(settings.leadTimeMinutes * 60) + 1800),
            isAllDay: false,
            location: "Meeting Room 2",
            meetingLink: MeetingLink(provider: .googleMeet, url: URL(string: "https://meet.google.com/")!),
            htmlLink: nil,
            organizer: "Meeting Minder",
            attendeeCount: 4,
            isDeclined: false
        )
        isPreview = true
        presentedEvent = sample
        playSound()
        onPresent?(sample)
    }

    // MARK: - Housekeeping

    private func pruneStates(now: Date) {
        guard !states.isEmpty else { return }
        let live = Set(store.events.map(\.id))
        states = states.filter { id, state in
            if live.contains(id) { return true }
            // Keep briefly after the event leaves the window so a late refresh cannot re-alert.
            guard let shown = state.lastShownAt else { return false }
            return now.timeIntervalSince(shown) < 6 * 3600
        }
    }

    private func playSound() {
        guard settings.playSound else { return }
        NSSound(named: NSSound.Name("Glass"))?.play()
    }
}
