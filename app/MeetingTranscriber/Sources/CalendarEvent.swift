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
    /// True when the provider marked the event cancelled. Overlap matching
    /// skips these so a recording does not inherit a cancelled invite.
    let isCancelled: Bool
    /// Calendar id when it looks like an email (Google). Not treated as the
    /// connected user — subscribed calendars use the owner's address here.
    let ownerEmail: String?

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
        isCancelled: Bool = false,
        ownerEmail: String? = nil,
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
        self.isCancelled = isCancelled
        self.ownerEmail = ownerEmail
    }

    /// True when the *app user* declined. Google `self` on a subscribed
    /// colleague calendar is not enough: pass the connected account emails
    /// (or rely on Apple's `isCurrentUser`, which sets `isSelf` with no mail).
    func declinedByCurrentUser(emails: Set<String>) -> Bool {
        attendees.contains { attendee in
            guard attendee.isDeclined else { return false }
            if let mail = attendee.normalizedEmail, emails.contains(mail) { return true }
            guard attendee.isSelf else { return false }
            if emails.isEmpty { return true }
            if let mail = attendee.normalizedEmail { return emails.contains(mail) }
            return true
        }
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
            isCancelled: isCancelled,
            ownerEmail: ownerEmail,
        )
    }

    func markingCurrentUser(emails: Set<String>) -> Self {
        guard !emails.isEmpty else { return self }
        return withAttendees(attendees.map { $0.markingSelf(ifEmailIn: emails) })
    }

    var sourceLabel: String {
        switch source {
        case .apple: "Apple Calendar"
        case .google: "Google Calendar"
        }
    }
}
