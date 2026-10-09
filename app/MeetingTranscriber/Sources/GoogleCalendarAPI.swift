import Foundation

protocol GoogleCalendarFetching: Sendable {
    func fetchEvents(accessToken: String, from: Date, to: Date) async throws -> [CalendarEvent]
    func primaryEmail(accessToken: String) async -> String?
}

/// Fetches upcoming events from the Google Calendar API (readonly).
struct GoogleCalendarAPI: GoogleCalendarFetching, Sendable {
    var session: URLSession
    var maxCalendars: Int

    init(session: URLSession = .shared, maxCalendars: Int = 8) {
        self.session = session
        self.maxCalendars = maxCalendars
    }

    func fetchEvents(accessToken: String, from: Date, to: Date) async throws -> [CalendarEvent] {
        let calendars = try await calendarList(accessToken: accessToken)
        let ids = calendars.isEmpty ? ["primary"] : calendars
        var collected: [CalendarEvent] = []
        for id in ids.prefix(maxCalendars) {
            let page = try await fetchCalendarEvents(
                calendarID: id,
                accessToken: accessToken,
                from: from,
                to: to,
            )
            collected.append(contentsOf: page)
        }
        return collected
    }

    func primaryEmail(accessToken: String) async -> String? {
        guard let data = try? await get(GoogleOAuthConfig.calendarListEndpoint, accessToken: accessToken),
              let payload = try? JSONDecoder().decode(CalendarListPayload.self, from: data) else {
            return nil
        }
        if let primary = payload.items?.first(where: { $0.primary == true }) {
            return primary.id
        }
        return payload.items?.first?.id
    }

    static func parseEvents(_ data: Data, calendarName: String?) -> [CalendarEvent] {
        guard let payload = try? JSONDecoder().decode(EventsPayload.self, from: data) else { return [] }
        return (payload.items ?? []).compactMap { item in
            event(from: item, calendarName: calendarName)
        }
    }

    private func calendarList(accessToken: String) async throws -> [String] {
        let data = try await get(GoogleOAuthConfig.calendarListEndpoint, accessToken: accessToken)
        let payload = try JSONDecoder().decode(CalendarListPayload.self, from: data)
        let selected = (payload.items ?? []).filter { item in
            item.selected != false && item.hidden != true
        }
        let ids = selected.compactMap(\.id)
        return ids.isEmpty ? ["primary"] : ids
    }

    static func eventsURL(calendarID: String, from: Date, to: Date) -> URL? {
        var components = URLComponents(
            url: GoogleOAuthConfig.eventsEndpoint
                .appendingPathComponent(calendarID)
                .appendingPathComponent("events"),
            resolvingAgainstBaseURL: false,
        )
        components?.queryItems = [
            URLQueryItem(name: "timeMin", value: isoString(from)),
            URLQueryItem(name: "timeMax", value: isoString(to)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "50"),
            URLQueryItem(name: "conferenceDataVersion", value: "1"),
        ]
        return components?.url
    }

    private func fetchCalendarEvents(calendarID: String, accessToken: String, from: Date, to: Date) async throws -> [CalendarEvent] {
        guard let url = Self.eventsURL(calendarID: calendarID, from: from, to: to) else { return [] }
        let data = try await get(url, accessToken: accessToken)
        return Self.parseEvents(data, calendarName: calendarID)
    }

    private func get(_ url: URL, accessToken: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ... 299).contains(status) else {
            throw GoogleOAuthError.fromHTTP(status: status, data: data)
        }
        return data
    }

    private static func event(from item: EventItem, calendarName: String?) -> CalendarEvent? {
        let startDate = item.start?.dateTime ?? item.start?.dayStart
        let endDate = item.end?.dateTime ?? item.end?.dayStart
        guard let startDate, let endDate else { return nil }
        let title = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let join = MeetingLinkExtractor.url(
            from: [item.hangoutLink, item.location, item.description],
            explicit: item.conferenceURI.flatMap(URL.init(string:)),
        )
        return CalendarEvent(
            id: "google:\(item.id ?? UUID().uuidString)",
            title: title.isEmpty ? "Busy" : title,
            start: startDate,
            end: endDate,
            source: .google,
            isAllDay: item.start?.date != nil,
            joinURL: join,
            calendarName: calendarName,
            attendees: attendees(from: item),
        )
    }

    private static func attendees(from item: EventItem) -> [CalendarAttendee] {
        var mapped = (item.attendees ?? []).compactMap { person in
            CalendarAttendeeMapping.google(
                email: person.email,
                displayName: person.displayName,
                isSelf: person.isSelf == true,
                isOrganizer: person.organizer == true,
                isResource: person.resource == true,
                responseStatus: person.responseStatus,
            )
        }
        if let organizer = item.organizer {
            let organizerEmail = organizer.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let alreadyListed = mapped.contains { existing in
                if let organizerEmail, !organizerEmail.isEmpty,
                   existing.email?.lowercased() == organizerEmail {
                    return true
                }
                return existing.isOrganizer
            }
            if !alreadyListed,
               let extra = CalendarAttendeeMapping.google(
                   email: organizer.email,
                   displayName: organizer.displayName,
                   isSelf: organizer.isSelf == true,
                   isOrganizer: true,
                   isResource: organizer.resource == true,
                   responseStatus: organizer.responseStatus ?? "accepted",
               ) {
                mapped.insert(extra, at: 0)
            }
        }
        return mapped
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

// Google's JSON uses absent keys for these; empty/false is the mapped default.
// swiftlint:disable discouraged_optional_boolean discouraged_optional_collection
private struct CalendarListPayload: Decodable {
    let items: [CalendarListItem]?
}

private struct CalendarListItem: Decodable {
    let id: String?
    let primary: Bool?
    let selected: Bool?
    let hidden: Bool?
}

private struct EventsPayload: Decodable {
    let items: [EventItem]?
}

private struct EventItem: Decodable {
    let id: String?
    let summary: String?
    let description: String?
    let location: String?
    let hangoutLink: String?
    let start: EventTime?
    let end: EventTime?
    let conferenceData: ConferenceData?
    let organizer: GooglePerson?
    let attendees: [GooglePerson]?

    var conferenceURI: String? {
        conferenceData?.entryPoints?.first { $0.uri != nil }?.uri
    }
}

private struct GooglePerson: Decodable {
    let email: String?
    let displayName: String?
    let isSelf: Bool?
    let organizer: Bool?
    let resource: Bool?
    let responseStatus: String?

    enum CodingKeys: String, CodingKey {
        case email, displayName, organizer, resource, responseStatus
        case isSelf = "self"
    }
}

private struct EventTime {
    let dateTime: Date?
    let date: String?

    var dayStart: Date? {
        guard let date else { return nil }
        return GoogleCalendarAPI.parseAllDay(date)
    }
}

private struct ConferenceData: Decodable {
    let entryPoints: [EntryPoint]?
}

private struct EntryPoint: Decodable {
    let uri: String?
}

// swiftlint:enable discouraged_optional_boolean discouraged_optional_collection

extension EventTime: Decodable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decodeIfPresent(String.self, forKey: .date)
        if let raw = try container.decodeIfPresent(String.self, forKey: .dateTime) {
            dateTime = GoogleCalendarAPI.parseDate(raw)
        } else {
            dateTime = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case dateTime
        case date
    }
}

extension GoogleCalendarAPI {
    static func parseDate(_ raw: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) { return date }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: raw)
    }

    /// Google all-day `start.date` / `end.date` values are calendar dates, not
    /// GMT midnights. Parse as local `startOfDay` so a holiday does not shift
    /// into the previous evening in US timezones.
    static func parseAllDay(_ raw: String, calendar: Calendar = .current) -> Date? {
        let parts = raw.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        return calendar.startOfDay(for: date)
    }
}
