import Foundation

/// Which connected calendar a meeting came from.
enum CalendarProviderKind: String, Codable, Sendable {
    case apple
    case google
}

/// One calendar event the app can use for titles, agenda, and join links.
///
/// Deliberately a value type: EventKit and the Google Calendar API both map
/// into this, and title-matching / merge live on the mapped form so tests
/// never need a live calendar store.
struct CalendarEvent: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let joinURL: URL?
    let source: CalendarProviderKind
    let calendarName: String?
    /// People on the invite. Empty when the provider did not return any, or
    /// when calendars are off. Stored on the recording so live and later
    /// speaker naming can offer the same list.
    let attendees: [CalendarAttendee]

    init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        source: CalendarProviderKind,
        isAllDay: Bool = false,
        joinURL: URL? = nil,
        calendarName: String? = nil,
        attendees: [CalendarAttendee] = [],
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.joinURL = joinURL
        self.source = source
        self.calendarName = calendarName
        self.attendees = attendees
    }

    func withAttendees(_ attendees: [CalendarAttendee]) -> Self {
        Self(
            id: id,
            title: title,
            start: start,
            end: end,
            source: source,
            isAllDay: isAllDay,
            joinURL: joinURL,
            calendarName: calendarName,
            attendees: attendees,
        )
    }

    var sourceLabel: String {
        switch source {
        case .apple: "Apple Calendar"
        case .google: "Google Calendar"
        }
    }
}
