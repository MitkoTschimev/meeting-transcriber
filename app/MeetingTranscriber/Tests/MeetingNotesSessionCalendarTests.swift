@testable import MeetingTranscriber
import XCTest

@MainActor
final class MeetingNotesSessionCalendarTests: XCTestCase {
    func testBeginStoresCalendarAttendeesAndRetitleFillsThemIn() {
        let attendees = [
            CalendarAttendee(email: "alice@corp.com", displayName: "Alice"),
        ]
        let session = MeetingNotesSession()
        session.begin(title: "Meeting", appName: "")
        XCTAssertEqual(session.calendarPickerNames, [])
        session.begin(title: "Standup", appName: "Zoom", calendarAttendees: attendees)
        XCTAssertEqual(session.calendarPickerNames, ["Alice"])
        session.finishRecording()
        session.begin(title: "Next", appName: "Zoom")
        XCTAssertEqual(session.calendarAttendees, [])
    }
}
