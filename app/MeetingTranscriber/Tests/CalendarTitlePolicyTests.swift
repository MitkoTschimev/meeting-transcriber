@testable import MeetingTranscriber
import XCTest

final class CalendarTitlePolicyTests: XCTestCase {
    private let event = CalendarEvent(
        id: "e1",
        title: "Sprint Planning",
        start: Date(timeIntervalSince1970: 1_000_000),
        end: Date(timeIntervalSince1970: 1_003_600),
        source: .google,
    )

    func testGenericDetectedTitleUsesCalendar() {
        XCTAssertEqual(
            CalendarTitlePolicy.resolve(detectedTitle: "Zoom Meeting", event: event, appName: "Zoom"),
            "Sprint Planning",
        )
        XCTAssertEqual(
            CalendarTitlePolicy.resolve(detectedTitle: "", event: event),
            "Sprint Planning",
        )
        XCTAssertEqual(
            CalendarTitlePolicy.resolve(detectedTitle: "Zoom", event: event, appName: "Zoom"),
            "Sprint Planning",
        )
    }

    func testSpecificDetectedTitleIsKeptWhenUnrelated() {
        XCTAssertEqual(
            CalendarTitlePolicy.resolve(detectedTitle: "Jane Doe", event: event, appName: "Microsoft Teams"),
            "Jane Doe",
        )
    }

    func testOverlappingNamesPreferCalendar() {
        XCTAssertEqual(
            CalendarTitlePolicy.resolve(detectedTitle: "Sprint Planning | Microsoft Teams", event: event),
            "Sprint Planning",
        )
    }

    func testNilEventKeepsDetected() {
        XCTAssertEqual(CalendarTitlePolicy.resolve(detectedTitle: "Standup", event: nil), "Standup")
    }

    func testEmptyCalendarTitleKeepsDetected() {
        let untitled = CalendarEvent(
            id: "e2",
            title: "  ",
            start: event.start,
            end: event.end,
            source: .apple,
        )
        XCTAssertEqual(CalendarTitlePolicy.resolve(detectedTitle: "Standup", event: untitled), "Standup")
    }

    func testOverlappingEventSkipsAllDay() {
        let allDay = CalendarEvent(
            id: "all",
            title: "Holiday",
            start: event.start,
            end: event.end,
            source: .apple,
            isAllDay: true,
        )
        XCTAssertNil(CalendarTitlePolicy.overlappingEvent(in: [allDay], at: event.start.addingTimeInterval(60)))
        XCTAssertEqual(
            CalendarTitlePolicy.overlappingEvent(in: [event], at: event.start.addingTimeInterval(60))?.id,
            "e1",
        )
    }

    func testOverlappingGraceBeforeStart() {
        let early = event.start.addingTimeInterval(-60)
        XCTAssertEqual(CalendarTitlePolicy.overlappingEvent(in: [event], at: early)?.id, "e1")
    }

    func testIsGeneric() {
        XCTAssertTrue(CalendarTitlePolicy.isGeneric("Meeting"))
        XCTAssertTrue(CalendarTitlePolicy.isGeneric("zoom meeting"))
        XCTAssertTrue(CalendarTitlePolicy.isGeneric("Microsoft Teams", appName: "Microsoft Teams"))
        XCTAssertFalse(CalendarTitlePolicy.isGeneric("Q3 Review", appName: "Zoom"))
    }
}
