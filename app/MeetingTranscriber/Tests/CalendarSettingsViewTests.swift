@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class CalendarSettingsViewTests: XCTestCase {
    private func makeSettings() throws -> AppSettings {
        let suiteName = "CalendarSettingsViewTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { DefaultsSuite.remove(suiteName) }
        return AppSettings(defaults: suite)
    }

    func testAppleToggleWritesSettings() throws {
        let settings = try makeSettings()
        let view = GeneralSettingsView(settings: settings, notificationVisibility: nil, calendar: nil)
        XCTAssertFalse(settings.appleCalendarEnabled)
        let toggle = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.appleCalendarToggle)
            .find(ViewType.Toggle.self)
        try toggle.tap()
        XCTAssertTrue(settings.appleCalendarEnabled)
    }

    func testConnectButtonPresentWhenDisconnected() throws {
        let settings = try makeSettings()
        settings.googleOAuthClientID = "cid.apps.googleusercontent.com"
        let view = GeneralSettingsView(settings: settings, notificationVisibility: nil, calendar: nil)
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.googleCalendarConnect))
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.googleOAuthClientIDField))
    }

    func testMeetingNotesShowsAgendaWhenIdle() throws {
        let settings = try makeSettings()
        let session = MeetingNotesSession()
        let event = CalendarEvent(
            id: "1",
            title: "1:1",
            start: Date().addingTimeInterval(1200),
            end: Date().addingTimeInterval(3000),
            source: .apple,
        )
        let view = MeetingNotesView(
            session: session,
            settings: settings,
            queue: PipelineQueue(),
            liveTranscriptionEnabled: false,
            upcomingEvents: [event],
        )
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.meetingNotesAgenda))
        XCTAssertNoThrow(try view.inspect().find(text: "1:1"))
    }
}
