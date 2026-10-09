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

    func testPickerNameHumanizesEmailLocalPart() {
        let dotted = CalendarAttendee(email: "john.smith@corp.com")
        XCTAssertEqual(dotted.pickerName, "John Smith")
        let plus = CalendarAttendee(email: "alice+tag@corp.com")
        XCTAssertEqual(plus.pickerName, "Alice")
        let compact = CalendarAttendee(email: "jsmith@corp.com")
        XCTAssertEqual(compact.pickerName, "Jsmith")
        XCTAssertEqual(CalendarAttendee(displayName: "John smith").pickerName, "John Smith")
    }

    func testDisplayNameThatIsAnEmailCountsAsMissing() throws {
        let apple = try XCTUnwrap(CalendarAttendeeMapping.apple(
            name: "jane@corp.com",
            url: URL(string: "mailto:jane@corp.com"),
            isCurrentUser: false,
            isOrganizer: false,
            isResource: false,
            status: .accepted,
        ))
        XCTAssertNil(apple.displayName)
        XCTAssertEqual(apple.pickerName, "Jane")
        XCTAssertFalse(apple.pickerName.contains("@"))

        let google = try XCTUnwrap(CalendarAttendeeMapping.google(
            email: "jane@corp.com",
            displayName: "jane@corp.com",
            isSelf: false,
            isOrganizer: false,
            isResource: false,
            responseStatus: "accepted",
        ))
        XCTAssertNil(google.displayName)
        XCTAssertEqual(google.pickerName, "Jane")
        XCTAssertFalse(CalendarAttendeePicker.names(from: [apple, google]).contains { $0.contains("@") })
    }

    func testJunkLocalPartsAreNotOfferedAsNames() {
        let junk = [
            CalendarAttendee(email: "noreply@corp.com"),
            CalendarAttendee(email: "calendar-notification@corp.com"),
            CalendarAttendee(email: "j123@corp.com"),
            CalendarAttendee(email: "12345@corp.com"),
            CalendarAttendee(email: "a@corp.com"),
            CalendarAttendee(email: "bounce+abc=x.com@corp.com"),
            CalendarAttendee(email: "calendar-noreply@corp.com"),
            CalendarAttendee(email: "support@corp.com"),
            CalendarAttendee(email: "info@corp.com"),
            CalendarAttendee(email: "admin@corp.com"),
            CalendarAttendee(email: "team@corp.com"),
            CalendarAttendee(email: "\"quoted\"@corp.com", displayName: "\"Jane Doe\""),
        ]
        for index in 0 ..< 11 {
            XCTAssertEqual(junk[index].pickerName, "")
        }
        XCTAssertEqual(junk[11].pickerName, "Jane Doe")
        XCTAssertEqual(CalendarAttendeePicker.names(from: junk), ["Jane Doe"])
        let long = String(repeating: "n", count: 80)
        XCTAssertLessThanOrEqual(
            CalendarAttendee(displayName: long).pickerName.count,
            CalendarAttendee.maxPickerNameLength,
        )
    }

    func testPickerNeverEmitsEmailAddresses() {
        let attendees = [
            CalendarAttendee(email: "raw@corp.com", displayName: "raw@corp.com"),
            CalendarAttendee(email: "bob.lee@corp.com"),
        ]
        let names = CalendarAttendeePicker.names(from: attendees)
        XCTAssertEqual(names, ["Bob Lee", "Raw"])
        XCTAssertFalse(names.contains { $0.contains("@") })
    }

    func testMailtoURLExtractsEmail() throws {
        let url = try XCTUnwrap(URL(string: "mailto:jane@example.com"))
        XCTAssertEqual(CalendarAttendee.email(fromMailto: url), "jane@example.com")
        XCTAssertNil(CalendarAttendee.email(fromMailto: URL(string: "https://example.com")))
    }

    func testAppleMappingSkipsNamelessResources() throws {
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

    func testPickerNamesSkipGroups() {
        let group = CalendarAttendee(
            email: "eng@corp.com",
            displayName: "Engineering",
            isGroup: true,
        )
        XCTAssertTrue(CalendarAttendeePicker.names(from: [group]).isEmpty)
        XCTAssertTrue(AppleCalendarMapper.isGroup(.group))
        XCTAssertFalse(AppleCalendarMapper.isGroup(.person))
        XCTAssertTrue(CalendarAttendeeMapping.looksLikeGroup(
            email: "list@corp.com", displayName: "Eng Mailing List",
        ))
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

    func testPickerMarksSelfFromAccountEmails() {
        let attendees = [
            CalendarAttendee(email: "me@corp.com", displayName: "Mitko"),
            CalendarAttendee(email: "amy@corp.com", displayName: "Amy"),
        ]
        XCTAssertEqual(
            CalendarAttendeePicker.names(from: attendees, selfEmails: ["me@corp.com"]),
            ["Amy"],
        )
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

    func testMergeDropsEmailAddressesFromTeamsAndCalendar() {
        let attendees = [
            CalendarAttendee(email: "cara@corp.com", displayName: "cara@corp.com"),
        ]
        XCTAssertEqual(
            CalendarAttendeePicker.merge(teams: ["xavier.y@corp.com", "Bob"], attendees: attendees),
            ["Bob", "Cara"],
        )
        XCTAssertFalse(
            CalendarAttendeePicker.merge(teams: ["xavier.y@corp.com"], attendees: attendees)
                .contains { $0.contains("@") },
        )
    }

    func testMergeOmitsDeclinedAttendeesFromPersistedNames() {
        let attendees = [
            CalendarAttendee(email: "zoe@corp.com", displayName: "Zoe", status: .declined),
            CalendarAttendee(email: "amy@corp.com", displayName: "Amy", status: .accepted),
        ]
        XCTAssertEqual(CalendarAttendeePicker.merge(teams: ["Bob"], attendees: attendees), ["Bob", "Amy"])
        XCTAssertEqual(CalendarAttendeePicker.names(from: attendees), ["Amy", "Zoe"])
    }

    func testMergeWithoutEventLeavesTeamsNamesUnchanged() {
        XCTAssertEqual(CalendarAttendeePicker.merge(teams: ["Bob"], attendees: []), ["Bob"])
        XCTAssertEqual(CalendarAttendeePicker.merge(teams: [], attendees: []), [])
    }

    func testPreferredSpellingUsesSavedVoiceCase() {
        XCTAssertEqual(
            CalendarAttendeePicker.preferredSpelling("alice", among: ["Alice", "Bob"]),
            "Alice",
        )
        XCTAssertEqual(
            CalendarAttendeePicker.preferredSpellings(["alice", "Cara"], among: ["Alice"]),
            ["Alice", "Cara"],
        )
    }

    func testSamePersonMergesByEmailAndCombinesFlags() {
        let apple = CalendarAttendee(
            email: "alice@corp.com",
            displayName: "Alice Chen",
            isSelf: false,
            isResource: false,
            status: .accepted,
        )
        let google = CalendarAttendee(
            email: "Alice@corp.com",
            displayName: nil,
            isSelf: true,
            isResource: false,
            status: .declined,
        )
        let merged = apple.merging(google)
        XCTAssertEqual(merged.displayName, "Alice Chen")
        XCTAssertFalse(merged.isSelf)
        XCTAssertEqual(merged.status, .declined)
        XCTAssertTrue(apple.isSamePerson(as: google))
        XCTAssertTrue(merged.markingSelf(ifEmailIn: ["alice@corp.com"]).isSelf)
    }

    func testMarkingSelfOnlyAddsNeverClears() {
        let apple = CalendarAttendee(
            email: "mitko@work.com",
            displayName: "Mitko T",
            isSelf: true,
            status: .accepted,
        )
        let marked = apple.markingSelf(ifEmailIn: ["mitko@gmail.com"])
        XCTAssertTrue(marked.isSelf)
        XCTAssertEqual(CalendarAttendeePicker.names(from: [marked], selfEmails: ["mitko@gmail.com"]), [])
        let declined = CalendarEvent(
            id: "d",
            title: "Skip this",
            start: Date(timeIntervalSince1970: 1_000_000),
            end: Date(timeIntervalSince1970: 1_003_600),
            source: .apple,
            attendees: [
                CalendarAttendee(
                    email: "mitko@work.com",
                    displayName: "Mitko T",
                    isSelf: true,
                    status: .declined,
                ),
            ],
        )
        let googleEmails: Set = ["mitko@gmail.com"]
        XCTAssertTrue(declined.markingCurrentUser(emails: googleEmails).declinedByCurrentUser(emails: googleEmails))
        XCTAssertNil(CalendarTitlePolicy.overlappingEvent(
            in: [declined.markingCurrentUser(emails: googleEmails)],
            at: declined.start.addingTimeInterval(60),
            userEmails: googleEmails,
        ))
    }

    func testAppleStatusAndResourceMapping() {
        XCTAssertEqual(AppleCalendarMapper.status(.accepted), .accepted)
        XCTAssertEqual(AppleCalendarMapper.status(.declined), .declined)
        XCTAssertEqual(AppleCalendarMapper.status(.tentative), .tentative)
        XCTAssertEqual(AppleCalendarMapper.status(.pending), .needsAction)
        XCTAssertTrue(AppleCalendarMapper.isResource(.room))
        XCTAssertTrue(AppleCalendarMapper.isResource(.resource))
        XCTAssertFalse(AppleCalendarMapper.isResource(.person))
        XCTAssertTrue(AppleCalendarMapper.isCancelled(.canceled))
        XCTAssertFalse(AppleCalendarMapper.isCancelled(.confirmed))
    }
}
