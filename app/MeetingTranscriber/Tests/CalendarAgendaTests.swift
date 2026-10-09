@testable import MeetingTranscriber
import XCTest

final class CalendarAgendaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_720_000_000)

    func testMergePrefersJoinLinkOnDuplicate() {
        let start = now.addingTimeInterval(3600)
        let apple = CalendarEvent(
            id: "a",
            title: "Standup",
            start: start,
            end: start.addingTimeInterval(1800),
            source: .apple,
        )
        let google = CalendarEvent(
            id: "g",
            title: "Standup",
            start: start,
            end: start.addingTimeInterval(1800),
            source: .google,
            joinURL: URL(string: "https://meet.google.com/abc"),
        )
        let merged = CalendarAgenda.merge([[apple], [google]])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.joinURL?.host, "meet.google.com")
    }

    func testMergeKeepsAttendeesFromTheCopyWithoutTheJoinLink() {
        let start = now.addingTimeInterval(3600)
        let apple = CalendarEvent(
            id: "a",
            title: "Standup",
            start: start,
            end: start.addingTimeInterval(1800),
            source: .apple,
            attendees: [CalendarAttendee(email: "alice@corp.com", displayName: "Alice")],
        )
        let google = CalendarEvent(
            id: "g",
            title: "Standup",
            start: start,
            end: start.addingTimeInterval(1800),
            source: .google,
            joinURL: URL(string: "https://meet.google.com/abc"),
        )
        let merged = CalendarAgenda.merge([[apple], [google]])
        XCTAssertEqual(merged.first?.joinURL?.host, "meet.google.com")
        XCTAssertEqual(merged.first?.attendees.map(\.pickerName), ["Alice"])
    }

    func testMergeCombinesAppleAndGoogleCopiesOfTheSamePersonByEmail() {
        let start = now.addingTimeInterval(3600)
        let apple = CalendarEvent(
            id: "a",
            title: "Standup",
            start: start,
            end: start.addingTimeInterval(1800),
            source: .apple,
            attendees: [
                CalendarAttendee(email: "alice@corp.com", displayName: "Alice Chen", status: .accepted),
                CalendarAttendee(email: "me@corp.com", displayName: "Mitko", isSelf: true),
            ],
        )
        let google = CalendarEvent(
            id: "g",
            title: "Standup",
            start: start,
            end: start.addingTimeInterval(1800),
            source: .google,
            joinURL: URL(string: "https://meet.google.com/abc"),
            attendees: [
                CalendarAttendee(email: "ALICE@corp.com", displayName: nil, status: .tentative),
                CalendarAttendee(email: "bob.lee@corp.com"),
            ],
        )
        let merged = CalendarAgenda.merge([[apple], [google]])
        let attendees = merged.first?.attendees ?? []
        XCTAssertEqual(attendees.count, 3)
        let alice = attendees.first { $0.normalizedEmail == "alice@corp.com" }
        XCTAssertEqual(alice?.displayName, "Alice Chen")
        XCTAssertEqual(alice?.status, .accepted)
        XCTAssertEqual(CalendarAttendeePicker.names(from: attendees), ["Alice Chen", "Bob Lee"])
    }

    func testMergeWithColleagueDeclinedCopyKeepsUsersAcceptedEvent() throws {
        let userEmails: Set = ["alice@corp.com"]
        let userCopy = try XCTUnwrap(Self.readCopy(
            calendar: "alice@corp.com",
            bobStatus: "declined",
            userEmails: userEmails,
        ))
        let bobCopy = try XCTUnwrap(Self.readCopy(
            calendar: "bob@corp.com",
            bobStatus: "declined",
            userEmails: userEmails,
        ))
        XCTAssertEqual(bobCopy.attendees.first { $0.normalizedEmail == "bob@corp.com" }?.isSelf, false)
        let merged = CalendarAgenda.merge([[userCopy], [bobCopy]])
            .map { $0.markingCurrentUser(emails: userEmails) }
        let event = CalendarTitlePolicy.overlappingEvent(
            in: merged,
            at: userCopy.start.addingTimeInterval(60),
            userEmails: userEmails,
        )
        XCTAssertEqual(event?.title, "Design review")
        let attendees = event?.attendees ?? []
        XCTAssertEqual(attendees.first { $0.normalizedEmail == "alice@corp.com" }?.isSelf, true)
        XCTAssertEqual(CalendarAttendeePicker.names(from: attendees), ["Bob"])
        XCTAssertFalse(event?.declinedByCurrentUser(emails: userEmails) ?? true)
    }

    func testMergeWithColleagueAcceptedCopyKeepsColleagueInPicker() throws {
        let userEmails: Set = ["alice@corp.com"]
        let userCopy = try XCTUnwrap(Self.readCopy(
            calendar: "alice@corp.com",
            bobStatus: "accepted",
            userEmails: userEmails,
        ))
        let bobCopy = try XCTUnwrap(Self.readCopy(
            calendar: "bob@corp.com",
            bobStatus: "accepted",
            userEmails: userEmails,
        ))
        XCTAssertEqual(bobCopy.attendees.first { $0.normalizedEmail == "bob@corp.com" }?.isSelf, false)
        let merged = CalendarAgenda.merge([[userCopy], [bobCopy]])
            .map { $0.markingCurrentUser(emails: userEmails) }
        let event = CalendarTitlePolicy.overlappingEvent(
            in: merged,
            at: userCopy.start.addingTimeInterval(60),
            userEmails: userEmails,
        )
        XCTAssertEqual(event?.title, "Design review")
        XCTAssertEqual(CalendarAttendeePicker.names(from: event?.attendees ?? []), ["Bob"])
    }

    private static func readCopy(
        calendar: String,
        bobStatus: String,
        userEmails: Set<String>,
    ) -> CalendarEvent? {
        let own = calendar == "alice@corp.com"
        let hangout = own ? "" : ",\"hangoutLink\":\"https://meet.google.com/xyz\""
        let json = Data("""
        {"items":[{
          "id":"g1","summary":"Design review"\(hangout),
          "start":{"dateTime":"2026-10-09T09:00:00Z"},
          "end":{"dateTime":"2026-10-09T09:30:00Z"},
          "attendees":[
            {"email":"alice@corp.com","displayName":"Alice","self":\(own),"responseStatus":"accepted"},
            {"email":"bob@corp.com","displayName":"Bob","self":\(!own),"responseStatus":"\(bobStatus)"}
          ]
        }]}
        """.utf8)
        return GoogleCalendarAPI.parseEvents(json, calendarName: calendar, userEmails: userEmails).first
    }

    func testUpcomingDropsPastAndCaps() {
        let past = CalendarEvent(
            id: "past",
            title: "Yesterday",
            start: now.addingTimeInterval(-7200),
            end: now.addingTimeInterval(-3600),
            source: .apple,
        )
        let next = CalendarEvent(
            id: "next",
            title: "Later",
            start: now.addingTimeInterval(1800),
            end: now.addingTimeInterval(3600),
            source: .google,
        )
        let upcoming = CalendarAgenda.upcoming([past, next], from: now, limit: 1)
        XCTAssertEqual(upcoming.map(\.id), ["next"])
    }

    func testInWindowKeepsEventsBeyondUpcomingLimit() {
        let dayStart = Calendar.current.startOfDay(for: now)
        var events: [CalendarEvent] = (0 ..< 12).map { index in
            CalendarEvent(
                id: "allday-\(index)",
                title: "Holiday \(index)",
                start: dayStart,
                end: dayStart.addingTimeInterval(86400),
                source: .apple,
                isAllDay: true,
            )
        }
        events.append(CalendarEvent(
            id: "live",
            title: "Live standup",
            start: now,
            end: now.addingTimeInterval(1800),
            source: .google,
        ))
        let upcoming = CalendarAgenda.upcoming(events, from: now, limit: 12)
        XCTAssertEqual(upcoming.count, 12)
        XCTAssertFalse(upcoming.contains { $0.id == "live" })
        let window = CalendarAgenda.inWindow(events, from: now)
        XCTAssertTrue(window.contains { $0.id == "live" })
        XCTAssertEqual(CalendarTitlePolicy.overlappingEvent(in: window, at: now)?.id, "live")
    }
}
