import Foundation

/// Read-only Google Calendar v3 client.
///
/// Only ever issues GETs, and only for `calendarList` and `events`.
@MainActor
final class GoogleCalendarService {

    struct CalendarSummary {
        let id: String
        let title: String
        let isPrimary: Bool
    }

    enum ServiceError: LocalizedError {
        case notSignedIn
        case http(Int, String?)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Not signed in to Google."
            case .http(let code, let message):
                if code == 403 { return "Google denied the request (403). Check the Calendar API is enabled. \(message ?? "")" }
                return "Google Calendar returned HTTP \(code). \(message ?? "")"
            case .malformedResponse:
                return "Could not read the response from Google Calendar."
            }
        }
    }

    private let auth: GoogleAuthService
    private let session: URLSession

    init(auth: GoogleAuthService) {
        self.auth = auth
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Calendars

    func fetchCalendars() async throws -> [CalendarSummary] {
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
        components.queryItems = [
            .init(name: "minAccessRole", value: "reader"),
            .init(name: "showDeleted", value: "false"),
            .init(name: "showHidden", value: "false"),
        ]

        let response: CalendarListResponse = try await get(components.url!)
        return (response.items ?? [])
            .filter { $0.deleted != true && $0.selected != false }
            .map { entry in
                CalendarSummary(
                    id: entry.id,
                    title: entry.summaryOverride ?? entry.summary ?? entry.id,
                    isPrimary: entry.primary ?? false
                )
            }
    }

    // MARK: - Events

    func fetchEvents(calendar: CalendarSummary, from: Date, to: Date) async throws -> [CalendarEvent] {
        var collected: [CalendarEvent] = []
        var pageToken: String?
        var page = 0

        repeat {
            let encodedID = calendar.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendar.id
            var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedID)/events")!
            var query: [URLQueryItem] = [
                .init(name: "timeMin", value: Self.rfc3339.string(from: from)),
                .init(name: "timeMax", value: Self.rfc3339.string(from: to)),
                // Expand recurring events into individual occurrences.
                .init(name: "singleEvents", value: "true"),
                .init(name: "orderBy", value: "startTime"),
                .init(name: "showDeleted", value: "false"),
                .init(name: "maxResults", value: "250"),
            ]
            if let pageToken { query.append(.init(name: "pageToken", value: pageToken)) }
            components.queryItems = query

            let response: EventsResponse = try await get(components.url!)
            collected += (response.items ?? []).compactMap { Self.makeEvent($0, calendar: calendar) }
            pageToken = response.nextPageToken
            page += 1
        } while pageToken != nil && page < 4

        return collected
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var attemptedRefresh = false

        while true {
            let token = try await auth.accessToken()
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ServiceError.malformedResponse }

            if http.statusCode == 401 && !attemptedRefresh {
                attemptedRefresh = true
                try await auth.refreshAccessToken()
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                throw ServiceError.http(http.statusCode, Self.errorMessage(from: data))
            }
            guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
                throw ServiceError.malformedResponse
            }
            return decoded
        }
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any]
        else { return nil }
        return error["message"] as? String
    }

    // MARK: - Mapping

    private static func makeEvent(_ dto: EventDTO, calendar: CalendarSummary) -> CalendarEvent? {
        guard dto.status != "cancelled", let id = dto.id else { return nil }
        guard let startInfo = dto.start, let endInfo = dto.end else { return nil }

        let isAllDay = startInfo.dateTime == nil && startInfo.date != nil
        guard let start = parse(startInfo), let end = parse(endInfo) else { return nil }

        let selfAttendee = dto.attendees?.first { $0.isSelf == true }
        let isDeclined = selfAttendee?.responseStatus == "declined"

        let attendeeCount = (dto.attendees ?? []).filter { $0.resource != true }.count

        return CalendarEvent(
            id: "\(calendar.id)|\(id)|\(Int(start.timeIntervalSince1970))",
            calendarID: calendar.id,
            calendarTitle: calendar.title,
            title: (dto.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            start: start,
            end: max(end, start),
            isAllDay: isAllDay,
            location: dto.location?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            meetingLink: meetingLink(for: dto),
            htmlLink: dto.htmlLink.flatMap(URL.init(string:)),
            organizer: dto.organizer?.displayName ?? dto.organizer?.email,
            attendeeCount: attendeeCount,
            isDeclined: isDeclined
        )
    }

    private static func meetingLink(for dto: EventDTO) -> MeetingLink? {
        // 1. Structured conference data is the most reliable source.
        if let entryPoints = dto.conferenceData?.entryPoints {
            if let video = entryPoints.first(where: { $0.entryPointType == "video" }),
               let uri = video.uri, let url = URL(string: uri) {
                return MeetingLink(provider: MeetingLinkDetector.provider(for: uri), url: url)
            }
        }
        // 2. Legacy Hangouts/Meet field.
        if let hangout = dto.hangoutLink, let url = URL(string: hangout) {
            return MeetingLink(provider: MeetingLinkDetector.provider(for: hangout), url: url)
        }
        // 3. Third-party invites usually put the URL in location or description.
        if let link = MeetingLinkDetector.firstLink(in: dto.location) { return link }
        if let link = MeetingLinkDetector.firstLink(in: dto.description) { return link }
        return nil
    }

    private static let rfc3339: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let rfc3339Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func parse(_ info: EventDateTimeDTO) -> Date? {
        if let dateTime = info.dateTime {
            return rfc3339.date(from: dateTime) ?? rfc3339Fractional.date(from: dateTime)
        }
        if let date = info.date {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = info.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
            return formatter.date(from: date)
        }
        return nil
    }

    // MARK: - DTOs

    private struct CalendarListResponse: Decodable {
        let items: [CalendarListEntry]?
    }

    private struct CalendarListEntry: Decodable {
        let id: String
        let summary: String?
        let summaryOverride: String?
        let selected: Bool?
        let deleted: Bool?
        let primary: Bool?
    }

    private struct EventsResponse: Decodable {
        let items: [EventDTO]?
        let nextPageToken: String?
    }

    private struct EventDTO: Decodable {
        let id: String?
        let status: String?
        let summary: String?
        let description: String?
        let location: String?
        let htmlLink: String?
        let hangoutLink: String?
        let start: EventDateTimeDTO?
        let end: EventDateTimeDTO?
        let attendees: [AttendeeDTO]?
        let organizer: PersonDTO?
        let conferenceData: ConferenceDataDTO?
    }

    private struct EventDateTimeDTO: Decodable {
        let date: String?
        let dateTime: String?
        let timeZone: String?
    }

    private struct AttendeeDTO: Decodable {
        let email: String?
        let responseStatus: String?
        let isSelf: Bool?
        let resource: Bool?

        enum CodingKeys: String, CodingKey {
            case email, responseStatus, resource
            case isSelf = "self"
        }
    }

    private struct PersonDTO: Decodable {
        let email: String?
        let displayName: String?
    }

    private struct ConferenceDataDTO: Decodable {
        let entryPoints: [EntryPointDTO]?
    }

    private struct EntryPointDTO: Decodable {
        let entryPointType: String?
        let uri: String?
        let label: String?
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
