import EventKit
import Foundation

typealias AppleCalendarAccess = EventKitAppleCalendarAccess

/// TCC + EventKit read surface for Apple Calendar. The live store is wrapped
/// so tests can inject events without a Calendar grant.
enum CalendarAccessStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case granted
    case restricted
}

@MainActor
protocol AppleCalendarAccessing: AnyObject {
    func authorizationStatus() -> CalendarAccessStatus
    func requestAccess() async -> Bool
    func events(from: Date, to: Date) -> [CalendarEvent]
}

enum AppleCalendarAuthorization {
    static func status(from ek: EKAuthorizationStatus) -> CalendarAccessStatus {
        switch ek {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied, .writeOnly: .denied
        @unknown default: .denied
        }
    }
}

enum AppleCalendarMapper {
    // EventKit fields plus notes/location for join-link extraction.
    // swiftlint:disable:next function_parameter_count
    static func event(
        id: String,
        title: String?,
        start: Date?,
        end: Date?,
        isAllDay: Bool,
        url: URL?,
        notes: String?,
        location: String?,
        calendarName: String?,
        attendees: [CalendarAttendee] = [],
        isCancelled: Bool = false,
    ) -> CalendarEvent? {
        guard let start, let end else { return nil }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CalendarEvent(
            id: "apple:\(id)",
            title: trimmed.isEmpty ? "Busy" : trimmed,
            start: start,
            end: end,
            source: .apple,
            isAllDay: isAllDay,
            joinURL: MeetingLinkExtractor.url(from: [location, notes], explicit: url),
            calendarName: calendarName,
            attendees: attendees,
            isCancelled: isCancelled,
        )
    }

    static func attendees(from event: EKEvent) -> [CalendarAttendee] {
        let organizerURL = event.organizer?.url
        let people = event.attendees ?? []
        var mapped = people.compactMap { participant in
            attendee(from: participant, isOrganizer: participant.url == organizerURL && organizerURL != nil)
        }
        if let organizer = event.organizer {
            let organizerEmail = CalendarAttendee.email(fromMailto: organizer.url)
            let alreadyListed = mapped.contains { existing in
                if let organizerEmail, existing.email?.lowercased() == organizerEmail.lowercased() {
                    return true
                }
                return existing.isOrganizer
            }
            if !alreadyListed, let extra = attendee(from: organizer, isOrganizer: true) {
                mapped.insert(extra, at: 0)
            }
        }
        return mapped
    }

    static func attendee(from participant: EKParticipant, isOrganizer: Bool) -> CalendarAttendee? {
        CalendarAttendeeMapping.apple(
            name: participant.name,
            url: participant.url,
            isCurrentUser: participant.isCurrentUser,
            isOrganizer: isOrganizer,
            isResource: isResource(participant.participantType),
            status: status(participant.participantStatus),
            isGroup: isGroup(participant.participantType),
        )
    }

    static func isResource(_ type: EKParticipantType) -> Bool {
        switch type {
        case .room, .resource: true
        case .unknown, .person, .group: false
        @unknown default: false
        }
    }

    static func isGroup(_ type: EKParticipantType) -> Bool {
        switch type {
        case .group: true
        case .unknown, .person, .room, .resource: false
        @unknown default: false
        }
    }

    static func isCancelled(_ status: EKEventStatus) -> Bool {
        switch status {
        case .canceled: true
        case .none, .confirmed, .tentative: false
        @unknown default: false
        }
    }

    static func status(_ status: EKParticipantStatus) -> CalendarAttendeeStatus {
        switch status {
        case .accepted: .accepted
        case .declined: .declined
        case .tentative: .tentative
        case .pending: .needsAction
        case .unknown, .delegated, .completed, .inProcess: .unknown
        @unknown default: .unknown
        }
    }
}

@MainActor
final class EventKitAppleCalendarAccess: AppleCalendarAccessing {
    /// Created on first read/request so constructing `CalendarController` at
    /// launch (and in AppState tests) does not touch EventKit until the user
    /// opts into Apple Calendar.
    private lazy var store = EKEventStore()

    func authorizationStatus() -> CalendarAccessStatus {
        AppleCalendarAuthorization.status(from: EKEventStore.authorizationStatus(for: .event))
    }

    func requestAccess() async -> Bool {
        if authorizationStatus() == .granted { return true }
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    func events(from: Date, to: Date) -> [CalendarEvent] {
        guard authorizationStatus() == .granted else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate).compactMap { ek in
            AppleCalendarMapper.event(
                id: ek.eventIdentifier,
                title: ek.title,
                start: ek.startDate,
                end: ek.endDate,
                isAllDay: ek.isAllDay,
                url: ek.url,
                notes: ek.notes,
                location: ek.location,
                calendarName: ek.calendar?.title,
                attendees: AppleCalendarMapper.attendees(from: ek),
                isCancelled: AppleCalendarMapper.isCancelled(ek.status),
            )
        }
    }
}

@MainActor
final class StubAppleCalendarAccess: AppleCalendarAccessing {
    var status: CalendarAccessStatus
    var storedEvents: [CalendarEvent]
    var requestResult: Bool

    init(
        status: CalendarAccessStatus = .notDetermined,
        events: [CalendarEvent] = [],
        requestResult: Bool = true,
    ) {
        self.status = status
        storedEvents = events
        self.requestResult = requestResult
    }

    func authorizationStatus() -> CalendarAccessStatus {
        status
    }

    // Protocol requirement is async (EventKit's request is); the stub is sync.
    // swiftlint:disable:next async_without_await
    func requestAccess() async -> Bool {
        if requestResult {
            status = .granted
        } else {
            status = .denied
        }
        return requestResult
    }

    func events(from: Date, to: Date) -> [CalendarEvent] {
        storedEvents.filter { $0.end >= from && $0.start <= to }
    }
}
