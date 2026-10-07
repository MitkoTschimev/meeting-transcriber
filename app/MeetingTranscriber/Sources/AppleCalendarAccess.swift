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
        )
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
