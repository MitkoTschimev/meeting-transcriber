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
}
