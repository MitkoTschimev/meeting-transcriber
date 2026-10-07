import EventKit
@testable import MeetingTranscriber
import XCTest

final class CalendarMappingTests: XCTestCase {
    func testAppleMapperExtractsJoinLinkFromNotes() throws {
        let start = Date(timeIntervalSince1970: 50)
        let mapped = try XCTUnwrap(AppleCalendarMapper.event(
            id: "ek-1",
            title: "Design Review",
            start: start,
            end: start.addingTimeInterval(1800),
            isAllDay: false,
            url: nil,
            notes: "https://zoom.us/j/999",
            location: "Zoom",
            calendarName: "Work",
        ))
        XCTAssertEqual(mapped.id, "apple:ek-1")
        XCTAssertEqual(mapped.source, .apple)
        XCTAssertEqual(mapped.joinURL?.host, "zoom.us")
        XCTAssertEqual(mapped.calendarName, "Work")
    }

    func testAppleMapperDropsEventsWithoutDates() {
        XCTAssertNil(AppleCalendarMapper.event(
            id: "x",
            title: "Nope",
            start: nil,
            end: nil,
            isAllDay: false,
            url: nil,
            notes: nil,
            location: nil,
            calendarName: nil,
        ))
    }

    func testGoogleEventsJSON() {
        let json = Data(#"""
        {"items":[{"id":"g1","summary":"Standup","hangoutLink":"https://meet.google.com/abc","start":{"dateTime":"2026-10-07T09:00:00Z"},"end":{"dateTime":"2026-10-07T09:30:00Z"}}]}
        """#.utf8)
        let events = GoogleCalendarAPI.parseEvents(json, calendarName: "primary")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.title, "Standup")
        XCTAssertEqual(events.first?.source, .google)
        XCTAssertEqual(events.first?.joinURL?.host, "meet.google.com")
        XCTAssertEqual(events.first?.isAllDay, false)
    }

    func testGoogleAllDayEvent() throws {
        let json = Data(#"{"items":[{"id":"g2","summary":"Holiday","start":{"date":"2026-10-07"},"end":{"date":"2026-10-08"}}]}"#.utf8)
        let events = GoogleCalendarAPI.parseEvents(json, calendarName: "primary")
        XCTAssertEqual(events.first?.isAllDay, true)
        XCTAssertEqual(events.first?.title, "Holiday")
        let start = try XCTUnwrap(events.first?.start)
        let end = try XCTUnwrap(events.first?.end)
        let calendar = Calendar.current
        XCTAssertEqual(start, calendar.startOfDay(for: start))
        var startParts = DateComponents()
        startParts.year = 2026
        startParts.month = 10
        startParts.day = 7
        XCTAssertEqual(start, calendar.date(from: startParts).map { calendar.startOfDay(for: $0) })
        var endParts = DateComponents()
        endParts.year = 2026
        endParts.month = 10
        endParts.day = 8
        XCTAssertEqual(end, calendar.date(from: endParts).map { calendar.startOfDay(for: $0) })
    }

    func testGoogleAllDayDateIsLocalMidnightNotGMT() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let start = try XCTUnwrap(GoogleCalendarAPI.parseAllDay("2026-10-07", calendar: calendar))
        let local = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        XCTAssertEqual(local.year, 2026)
        XCTAssertEqual(local.month, 10)
        XCTAssertEqual(local.day, 7)
        XCTAssertEqual(local.hour, 0)
        XCTAssertEqual(local.minute, 0)
        XCTAssertEqual(local.second, 0)
        var gmtCalendar = Calendar(identifier: .gregorian)
        gmtCalendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let gmt = gmtCalendar.dateComponents([.day, .hour], from: start)
        XCTAssertEqual(gmt.day, 7)
        XCTAssertEqual(gmt.hour, 7)
    }

    func testEventsURLEncodesCalendarIDWithoutFlatteningPath() throws {
        let from = Date(timeIntervalSince1970: 1000)
        let to = Date(timeIntervalSince1970: 2000)
        let url = try XCTUnwrap(GoogleCalendarAPI.eventsURL(
            calendarID: "user@gmail.com",
            from: from,
            to: to,
        ))
        XCTAssertEqual(url.path, "/calendar/v3/calendars/user@gmail.com/events")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        XCTAssertEqual(value("singleEvents"), "true")
        XCTAssertEqual(value("conferenceDataVersion"), "1")
        XCTAssertEqual(value("orderBy"), "startTime")
    }

    func testAuthorizationStatusMapping() {
        XCTAssertEqual(AppleCalendarAuthorization.status(from: .fullAccess), .granted)
        XCTAssertEqual(AppleCalendarAuthorization.status(from: .notDetermined), .notDetermined)
        XCTAssertEqual(AppleCalendarAuthorization.status(from: .denied), .denied)
        XCTAssertEqual(AppleCalendarAuthorization.status(from: .writeOnly), .denied)
        XCTAssertEqual(AppleCalendarAuthorization.status(from: .restricted), .restricted)
    }
}
