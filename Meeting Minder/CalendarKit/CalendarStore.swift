import AppKit
import Combine
import Foundation
import os

/// Keeps a rolling window of upcoming events in sync with Google Calendar.
///
/// A plain poll is used rather than push notifications: it needs no public webhook
/// endpoint, is self-correcting after sleep or network loss, and one request per
/// calendar per minute sits far inside Google's quota.
@MainActor
final class CalendarStore: ObservableObject {

    /// How far ahead events are fetched. The menu bar shows the next event whenever it is.
    private static let lookahead: TimeInterval = 7 * 24 * 3600
    /// Fetch slightly into the past so in-progress meetings are still known.
    private static let lookbehind: TimeInterval = 4 * 3600
    private static let pollInterval: TimeInterval = 60
    private static let calendarListTTL: TimeInterval = 10 * 60

    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var isRefreshing = false

    /// Fired whenever the event list changes, so AppKit views can redraw.
    var onChange: (() -> Void)?

    private let auth: GoogleAuthService
    private let service: GoogleCalendarService
    private let settings: AppSettings

    private var pollTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var cachedCalendars: [GoogleCalendarService.CalendarSummary] = []
    private var cachedCalendarsAt: Date?

    init(auth: GoogleAuthService, settings: AppSettings = .shared) {
        self.auth = auth
        self.settings = settings
        self.service = GoogleCalendarService(auth: auth)
    }

    // MARK: - Lifecycle

    func start() {
        stop()

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        // Waking from sleep invalidates our view of the world; refetch immediately.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)

        refresh(force: true)
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func systemDidWake() {
        Log.calendar.info("System woke — refreshing calendar")
        invalidateCalendarCache()
        refresh(force: true)
    }

    func invalidateCalendarCache() {
        cachedCalendarsAt = nil
    }

    /// Called after sign-in/sign-out so stale events never linger.
    func reset() {
        events = []
        lastRefresh = nil
        lastErrorMessage = nil
        invalidateCalendarCache()
        onChange?()
    }

    // MARK: - Refresh

    func refresh(force: Bool = false) {
        guard auth.isSignedIn else { return }
        guard refreshTask == nil else { return }
        if !force, let last = lastRefresh, Date().timeIntervalSince(last) < 5 { return }

        isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.refreshTask = nil
                self.isRefreshing = false
            }
            await self.performRefresh()
        }
    }

    private func performRefresh() async {
        do {
            let calendars = try await loadCalendars()
            let now = Date()
            let from = now.addingTimeInterval(-Self.lookbehind)
            let to = now.addingTimeInterval(Self.lookahead)

            var fetched: [CalendarEvent] = []
            var failures: [String] = []

            await withTaskGroup(of: Result<[CalendarEvent], Error>.self) { group in
                for calendar in calendars {
                    group.addTask { @MainActor in
                        do {
                            return .success(try await self.service.fetchEvents(calendar: calendar, from: from, to: to))
                        } catch {
                            return .failure(error)
                        }
                    }
                }
                for await result in group {
                    switch result {
                    case .success(let events): fetched += events
                    case .failure(let error): failures.append(error.localizedDescription)
                    }
                }
            }

            // A total failure is an error; a single unreadable calendar is not.
            if fetched.isEmpty && !failures.isEmpty {
                throw GoogleCalendarService.ServiceError.http(0, failures[0])
            }

            let filtered = filterAndSort(fetched, now: now, calendars: calendars)
            if filtered != events {
                events = filtered
                onChange?()
            }
            lastRefresh = Date()
            lastErrorMessage = failures.isEmpty ? nil : failures[0]
            Log.calendar.debug("Refreshed \(filtered.count, privacy: .public) events from \(calendars.count, privacy: .public) calendars")
        } catch is CancellationError {
            // Shutting down.
        } catch {
            lastErrorMessage = error.localizedDescription
            Log.calendar.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
            onChange?()
        }
    }

    private func loadCalendars() async throws -> [GoogleCalendarService.CalendarSummary] {
        if let cachedAt = cachedCalendarsAt,
           Date().timeIntervalSince(cachedAt) < Self.calendarListTTL,
           !cachedCalendars.isEmpty {
            return cachedCalendars
        }
        let calendars = try await service.fetchCalendars()
        cachedCalendars = calendars
        cachedCalendarsAt = Date()
        return calendars
    }

    private func filterAndSort(_ input: [CalendarEvent],
                               now: Date,
                               calendars: [GoogleCalendarService.CalendarSummary]) -> [CalendarEvent] {
        let primaryID = calendars.first(where: { $0.isPrimary })?.id

        let kept = input.filter { event in
            if event.hasEnded(at: now) { return false }
            if settings.ignoreAllDay && event.isAllDay { return false }
            if settings.ignoreDeclined && event.isDeclined { return false }
            return true
        }

        // The same invite can land on several subscribed calendars; keep one copy,
        // preferring the primary calendar's version.
        var byOccurrence: [String: CalendarEvent] = [:]
        for event in kept {
            let key = "\(event.title.lowercased())|\(Int(event.start.timeIntervalSince1970))|\(Int(event.end.timeIntervalSince1970))"
            if let existing = byOccurrence[key] {
                if existing.calendarID != primaryID && event.calendarID == primaryID {
                    byOccurrence[key] = event
                } else if existing.meetingLink == nil && event.meetingLink != nil {
                    byOccurrence[key] = event
                }
            } else {
                byOccurrence[key] = event
            }
        }

        return byOccurrence.values.sorted {
            $0.start == $1.start ? $0.title < $1.title : $0.start < $1.start
        }
    }

    // MARK: - Queries

    /// The event to display in the menu bar: the one in progress, otherwise the next to start.
    func nextEvent(at date: Date = Date()) -> CalendarEvent? {
        events.first { !$0.hasEnded(at: date) }
    }

    func upcoming(limit: Int, at date: Date = Date()) -> [CalendarEvent] {
        Array(events.filter { !$0.hasEnded(at: date) }.prefix(limit))
    }

    func event(withID id: String) -> CalendarEvent? {
        events.first { $0.id == id }
    }
}
