import EventKit
@testable import MeetingTranscriber
import XCTest

final class CalendarAttendeeTests: XCTestCase {
    func testPickerNamePrefersDisplayNameOverEmail() {
        let attendee = CalendarAttendee(
            email: "alice.smith@corp.com",
            displayName: "Alice Smith",
        )
        XCTAssertEqual(attendee.pickerName, "Alice Smith")
    }

    func testPickerNameFallsBackToEmailLocalPart() {
        let attendee = CalendarAttendee(email: "bob.lee@corp.com")
        XCTAssertEqual(attendee.pickerName, "bob.lee")
    }

    func testMailtoURLExtractsEmail() throws {
        let url = try XCTUnwrap(URL(string: "mailto:jane@example.com"))
        XCTAssertEqual(CalendarAttendee.email(fromMailto: url), "jane@example.com")
        XCTAssertNil(CalendarAttendee.email(fromMailto: URL(string: "https://example.com")))
    }

    func testAppleMappingSkipsNamelessResources() {
        XCTAssertNil(CalendarAttendeeMapping.apple(
            name: nil,
            url: nil,
            isCurrentUser: false,
            isOrganizer: false,
            isResource: true,
            status: .accepted,
        ))
        let room = try XCTUnwrap(CalendarAttendeeMapping.apple(
            name: "Boardroom",
            url: nil,
            isCurrentUser: false,
            isOrganizer: false,
            isResource: true,
            status: .accepted,
        ))
        XCTAssertTrue(room.isResource)
        XCTAssertTrue(CalendarAttendeePicker.names(from: [room]).isEmpty)
    }

    func testGoogleMappingReadsSelfOrganizerAndStatus() throws {
        let selfOrganizer = try XCTUnwrap(CalendarAttendeeMapping.google(
            email: "me@corp.com",
            displayName: "Me Person",
            isSelf: true,
            isOrganizer: true,
            isResource: false,
            responseStatus: "accepted",
        ))
        XCTAssertTrue(selfOrganizer.isSelf)
        XCTAssertTrue(selfOrganizer.isOrganizer)
        XCTAssertEqual(selfOrganizer.status, .accepted)

        let declined = try XCTUnwrap(CalendarAttendeeMapping.google(
            email: "skip@corp.com",
            displayName: "Skip",
            isSelf: false,
            isOrganizer: false,
            isResource: false,
            responseStatus: "declined",
        ))
        XCTAssertEqual(declined.status, .declined)
        XCTAssertEqual(CalendarAttendeeMapping.googleStatus("needsAction"), .needsAction)
        XCTAssertEqual(CalendarAttendeeMapping.googleStatus("tentative"), .tentative)
    }

    func testPickerNamesDropSelfAndListDeclinedLast() {
        let attendees = [
            CalendarAttendee(email: "me@corp.com", displayName: "Mitko", isSelf: true, status: .accepted),
            CalendarAttendee(email: "zoe@corp.com", displayName: "Zoe", status: .declined),
            CalendarAttendee(email: "amy@corp.com", displayName: "Amy", isOrganizer: true, status: .accepted),
            CalendarAttendee(email: "dan@corp.com", displayName: "Dan", status: .tentative),
        ]
        XCTAssertEqual(CalendarAttendeePicker.names(from: attendees), ["Amy", "Dan", "Zoe"])
    }

    func testPickerNamesDeduplicateCaseInsensitively() {
        let attendees = [
            CalendarAttendee(email: "a@corp.com", displayName: "Alice"),
            CalendarAttendee(email: "a2@corp.com", displayName: "alice"),
        ]
        XCTAssertEqual(CalendarAttendeePicker.names(from: attendees), ["Alice"])
    }

    func testMergePutsTeamsNamesBeforeCalendarAndDedupes() {
        let attendees = [
            CalendarAttendee(email: "alice@corp.com", displayName: "Alice"),
            CalendarAttendee(email: "cara@corp.com", displayName: "Cara"),
        ]
        XCTAssertEqual(
            CalendarAttendeePicker.merge(teams: ["Bob", "alice"], attendees: attendees),
            ["Bob", "alice", "Cara"],
        )
    }

    func testMergeWithoutEventLeavesTeamsNamesUnchanged() {
        XCTAssertEqual(CalendarAttendeePicker.merge(teams: ["Bob"], attendees: []), ["Bob"])
        XCTAssertEqual(CalendarAttendeePicker.merge(teams: [], attendees: []), [])
    }

    func testAppleStatusAndResourceMapping() {
        XCTAssertEqual(AppleCalendarMapper.status(.accepted), .accepted)
        XCTAssertEqual(AppleCalendarMapper.status(.declined), .declined)
        XCTAssertEqual(AppleCalendarMapper.status(.tentative), .tentative)
        XCTAssertEqual(AppleCalendarMapper.status(.pending), .needsAction)
        XCTAssertTrue(AppleCalendarMapper.isResource(.room))
        XCTAssertTrue(AppleCalendarMapper.isResource(.resource))
        XCTAssertFalse(AppleCalendarMapper.isResource(.person))
    }
}
