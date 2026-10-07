@testable import MeetingTranscriber
import XCTest

@MainActor
final class CalendarControllerTests: XCTestCase {
    private func makeSettings() throws -> (AppSettings, String) {
        let suiteName = "CalendarControllerTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { DefaultsSuite.remove(suiteName) }
        return (AppSettings(defaults: suite), suiteName)
    }

    func testAppleGrantEnablesAndListsEvents() async throws {
        let (settings, _) = try makeSettings()
        let start = Date().addingTimeInterval(600)
        let event = CalendarEvent(
            id: "apple:1",
            title: "Interview",
            start: start,
            end: start.addingTimeInterval(1800),
            source: .apple,
            joinURL: URL(string: "https://meet.google.com/int"),
        )
        let apple = StubAppleCalendarAccess(status: .notDetermined, events: [event], requestResult: true)
        let account = "CalendarControllerTests-token-\(UUID().uuidString)"
        addTeardownBlock { KeychainHelper.delete(key: account) }
        let calendar = CalendarController(
            settings: settings,
            tokenStore: CalendarTokenStore(account: account),
            apple: apple,
            oauth: GoogleOAuthClient { _ in },
        )
        settings.appleCalendarEnabled = true
        await calendar.requestAppleAccess()
        XCTAssertTrue(settings.appleCalendarEnabled)
        XCTAssertEqual(calendar.appleStatus, .granted)
        XCTAssertEqual(calendar.upcoming.first?.title, "Interview")
        XCTAssertEqual(calendar.eventOverlapping(at: start.addingTimeInterval(10))?.title, "Interview")
    }

    func testAppleDenialClearsToggle() async throws {
        let (settings, _) = try makeSettings()
        let apple = StubAppleCalendarAccess(status: .notDetermined, requestResult: false)
        let account = "CalendarControllerTests-token-\(UUID().uuidString)"
        addTeardownBlock { KeychainHelper.delete(key: account) }
        let calendar = CalendarController(
            settings: settings,
            tokenStore: CalendarTokenStore(account: account),
            apple: apple,
            oauth: GoogleOAuthClient { _ in },
        )
        settings.appleCalendarEnabled = true
        await calendar.requestAppleAccess()
        XCTAssertFalse(settings.appleCalendarEnabled)
        XCTAssertEqual(calendar.appleStatus, .denied)
        XCTAssertTrue(calendar.upcoming.isEmpty)
    }

    func testDisconnectClearsTokenAndToggle() throws {
        let (settings, _) = try makeSettings()
        let account = "CalendarControllerTests-token-\(UUID().uuidString)"
        addTeardownBlock { KeychainHelper.delete(key: account) }
        let store = CalendarTokenStore(account: account)
        try store.save(GoogleOAuthToken(
            accessToken: "a",
            refreshToken: "r",
            expiry: Date().addingTimeInterval(3600),
            tokenType: "Bearer",
            email: "user@example.com",
        ))
        settings.googleCalendarEnabled = true
        let calendar = CalendarController(
            settings: settings,
            tokenStore: store,
            apple: StubAppleCalendarAccess(),
            oauth: GoogleOAuthClient { _ in },
        )
        XCTAssertTrue(calendar.googleConnected)
        calendar.disconnectGoogle()
        XCTAssertFalse(calendar.googleConnected)
        XCTAssertFalse(settings.googleCalendarEnabled)
        XCTAssertNil(store.read())
    }

    func testGoogleRefreshRestoresEmailAndListsEvents() async throws {
        let (settings, _) = try makeSettings()
        let account = "CalendarControllerTests-token-\(UUID().uuidString)"
        addTeardownBlock { KeychainHelper.delete(key: account) }
        let store = CalendarTokenStore(account: account)
        try store.save(GoogleOAuthToken(
            accessToken: "ya29.test",
            refreshToken: "1//r",
            expiry: Date(timeIntervalSince1970: 1_720_003_600),
            tokenType: "Bearer",
            email: "user@example.com",
        ))
        settings.googleCalendarEnabled = true
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let start = now.addingTimeInterval(3600)
        let google = StubGoogleCalendarAPI(
            events: [
                CalendarEvent(
                    id: "google:g1",
                    title: "Standup",
                    start: start,
                    end: start.addingTimeInterval(1800),
                    source: .google,
                    joinURL: URL(string: "https://meet.google.com/aaa-bbbb-ccc"),
                ),
            ],
            email: "user@example.com",
        )
        let calendar = CalendarController(
            settings: settings,
            tokenStore: store,
            apple: StubAppleCalendarAccess(),
            googleAPI: google,
            oauth: GoogleOAuthClient { _ in },
        ) { now }
        await calendar.refresh()
        XCTAssertEqual(calendar.googleEmail, "user@example.com")
        XCTAssertEqual(calendar.upcoming.first?.title, "Standup")
        XCTAssertEqual(calendar.upcoming.first?.source, .google)
        XCTAssertEqual(calendar.upcoming.first?.joinURL?.host, "meet.google.com")
    }
}

private struct StubGoogleCalendarAPI: GoogleCalendarFetching {
    var events: [CalendarEvent] = []
    var email: String?

    // Protocol requirement is async (live client hits the network).
    // swiftlint:disable:next async_without_await
    func fetchEvents(accessToken _: String, from: Date, to: Date) async -> [CalendarEvent] {
        events.filter { $0.end >= from && $0.start <= to }
    }

    // swiftlint:disable:next async_without_await
    func primaryEmail(accessToken _: String) async -> String? {
        email
    }
}
