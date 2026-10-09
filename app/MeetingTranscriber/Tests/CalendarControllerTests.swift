@testable import MeetingTranscriber
import XCTest

@MainActor
final class CalendarControllerTests: XCTestCase {
    func testAppleGrantEnablesAndListsEvents() async throws {
        let settings = try CalendarControllerFixtures.makeSettings(in: self)
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
        let calendar = CalendarController(
            settings: settings,
            tokenStore: CalendarControllerFixtures.makeStore(in: self),
            apple: apple,
            oauth: StubGoogleOAuth(),
        )
        settings.appleCalendarEnabled = true
        await calendar.requestAppleAccess()
        XCTAssertTrue(settings.appleCalendarEnabled)
        XCTAssertEqual(calendar.appleStatus, .granted)
        XCTAssertEqual(calendar.upcoming.first?.title, "Interview")
        XCTAssertEqual(calendar.eventOverlapping(at: start.addingTimeInterval(10))?.title, "Interview")
    }

    func testAppleDenialClearsToggle() async throws {
        let settings = try CalendarControllerFixtures.makeSettings(in: self)
        let apple = StubAppleCalendarAccess(status: .notDetermined, requestResult: false)
        let calendar = CalendarController(
            settings: settings,
            tokenStore: CalendarControllerFixtures.makeStore(in: self),
            apple: apple,
            oauth: StubGoogleOAuth(),
        )
        settings.appleCalendarEnabled = true
        await calendar.requestAppleAccess()
        XCTAssertFalse(settings.appleCalendarEnabled)
        XCTAssertEqual(calendar.appleStatus, .denied)
        XCTAssertTrue(calendar.upcoming.isEmpty)
    }

    func testGoogleRefreshRestoresEmailAndListsEvents() async throws {
        let settings = try CalendarControllerFixtures.makeSettings(in: self)
        let store = CalendarControllerFixtures.makeStore(in: self)
        try store.save(CalendarControllerFixtures.sampleToken(expiry: Date(timeIntervalSince1970: 1_720_003_600)))
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
            oauth: StubGoogleOAuth(),
        ) { now }
        await calendar.refresh()
        XCTAssertEqual(calendar.googleEmail, "user@example.com")
        XCTAssertEqual(calendar.upcoming.first?.title, "Standup")
        XCTAssertEqual(calendar.upcoming.first?.source, .google)
        XCTAssertEqual(calendar.upcoming.first?.joinURL?.host, "meet.google.com")
    }

    func testConnectAbortsWhenKeychainSaveFails() async throws {
        let settings = try CalendarControllerFixtures.makeSettings(in: self)
        settings.googleOAuthClientID = "cid.apps.googleusercontent.com"
        let store = CalendarTokenStore(account: "failing-\(UUID().uuidString)", keychain: FailingKeychain())
        let oauth = StubGoogleOAuth(authorizeToken: CalendarControllerFixtures.sampleToken())
        let calendar = CalendarController(
            settings: settings,
            tokenStore: store,
            apple: StubAppleCalendarAccess(),
            googleAPI: StubGoogleCalendarAPI(email: "user@example.com"),
            oauth: oauth,
        )
        await calendar.connectGoogle()
        XCTAssertEqual(calendar.lastError, GoogleOAuthError.keychainSaveFailed.errorDescription)
        XCTAssertFalse(settings.googleCalendarEnabled)
        XCTAssertFalse(calendar.googleConnected)
        XCTAssertNil(store.read())
        XCTAssertNil(calendar.googleEmail)
    }

    func testExpiredTokenWithoutClientIDSurfacesErrorAndKeepsToken() async throws {
        let settings = try CalendarControllerFixtures.makeSettings(in: self)
        settings.googleOAuthClientID = ""
        let store = CalendarControllerFixtures.makeStore(in: self)
        try store.save(CalendarControllerFixtures.sampleToken(expiry: Date(timeIntervalSince1970: 1)))
        settings.googleCalendarEnabled = true
        let calendar = CalendarController(
            settings: settings,
            tokenStore: store,
            apple: StubAppleCalendarAccess(),
            oauth: StubGoogleOAuth(),
        )
        await calendar.refresh()
        XCTAssertEqual(calendar.lastError, GoogleOAuthError.missingClientID.errorDescription)
        XCTAssertTrue(store.hasToken)
        XCTAssertTrue(settings.googleCalendarEnabled)
    }

    func testInvalidGrantOnRefreshDeletesToken() async throws {
        let settings = try CalendarControllerFixtures.makeSettings(in: self)
        settings.googleOAuthClientID = "cid.apps.googleusercontent.com"
        let store = CalendarControllerFixtures.makeStore(in: self)
        try store.save(CalendarControllerFixtures.sampleToken(expiry: Date(timeIntervalSince1970: 1)))
        settings.googleCalendarEnabled = true
        let oauth = StubGoogleOAuth(refreshError: .unauthorized)
        let calendar = CalendarController(
            settings: settings,
            tokenStore: store,
            apple: StubAppleCalendarAccess(),
            oauth: oauth,
        )
        await calendar.refresh()
        XCTAssertEqual(calendar.lastError, GoogleOAuthError.unauthorized.errorDescription)
        XCTAssertFalse(store.hasToken)
        XCTAssertFalse(settings.googleCalendarEnabled)
        XCTAssertNil(calendar.googleEmail)
    }

    func testUnauthorizedFetchDeletesToken() async throws {
        let settings = try CalendarControllerFixtures.makeSettings(in: self)
        settings.googleOAuthClientID = "cid.apps.googleusercontent.com"
        let store = CalendarControllerFixtures.makeStore(in: self)
        try store.save(CalendarControllerFixtures.sampleToken())
        settings.googleCalendarEnabled = true
        let google = StubGoogleCalendarAPI(fetchError: GoogleOAuthError.unauthorized)
        let calendar = CalendarController(
            settings: settings,
            tokenStore: store,
            apple: StubAppleCalendarAccess(),
            googleAPI: google,
            oauth: StubGoogleOAuth(),
        )
        await calendar.refresh()
        XCTAssertEqual(calendar.lastError, GoogleOAuthError.unauthorized.errorDescription)
        XCTAssertFalse(store.hasToken)
        XCTAssertFalse(settings.googleCalendarEnabled)
    }

    func testOverlapFindsLiveMeetingBeyondUpcomingLimit() async throws {
        let settings = try CalendarControllerFixtures.makeSettings(in: self)
        let now = Date(timeIntervalSince1970: 1_720_000_000)
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
            source: .apple,
        ))
        let apple = StubAppleCalendarAccess(status: .granted, events: events)
        let calendar = CalendarController(
            settings: settings,
            tokenStore: CalendarControllerFixtures.makeStore(in: self),
            apple: apple,
            oauth: StubGoogleOAuth(),
        ) { now }
        settings.appleCalendarEnabled = true
        await calendar.refresh()
        XCTAssertEqual(calendar.upcoming.count, 12)
        XCTAssertFalse(calendar.upcoming.contains { $0.id == "live" })
        XCTAssertEqual(calendar.eventOverlapping(at: now)?.id, "live")
        XCTAssertEqual(calendar.eventOverlapping(at: now)?.title, "Live standup")
    }

    func testExpiredTokenRefreshesThenFetches() async throws {
        let settings = try CalendarControllerFixtures.makeSettings(in: self)
        settings.googleOAuthClientID = "cid.apps.googleusercontent.com"
        let store = CalendarControllerFixtures.makeStore(in: self)
        try store.save(CalendarControllerFixtures.sampleToken(access: "old", expiry: Date(timeIntervalSince1970: 1)))
        settings.googleCalendarEnabled = true
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let start = now.addingTimeInterval(60)
        let oauth = StubGoogleOAuth(
            refreshResult: CalendarControllerFixtures.sampleToken(access: "new", expiry: now.addingTimeInterval(3600)),
        )
        let google = StubGoogleCalendarAPI(
            events: [
                CalendarEvent(
                    id: "g",
                    title: "Standup",
                    start: start,
                    end: start.addingTimeInterval(1800),
                    source: .google,
                ),
            ],
        )
        let calendar = CalendarController(
            settings: settings,
            tokenStore: store,
            apple: StubAppleCalendarAccess(),
            googleAPI: google,
            oauth: oauth,
        ) { now }
        await calendar.refresh()
        XCTAssertEqual(store.read()?.accessToken, "new")
        XCTAssertEqual(calendar.upcoming.first?.title, "Standup")
        XCTAssertNil(calendar.lastError)
    }

    func testTransientGoogleFailureKeepsLastEventsForEnrichment() async throws {
        let settings = try CalendarControllerFixtures.makeSettings(in: self)
        let store = CalendarControllerFixtures.makeStore(in: self)
        try store.save(CalendarControllerFixtures.sampleToken())
        settings.googleCalendarEnabled = true
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let live = CalendarEvent(
            id: "google:live",
            title: "Standup",
            start: now,
            end: now.addingTimeInterval(1800),
            source: .google,
        )
        let google = StubGoogleCalendarAPI(events: [live])
        let calendar = CalendarController(
            settings: settings,
            tokenStore: store,
            apple: StubAppleCalendarAccess(),
            googleAPI: google,
            oauth: StubGoogleOAuth(),
        ) { now }
        await calendar.refresh()
        XCTAssertEqual(calendar.eventOverlapping(at: now)?.title, "Standup")
        google.fetchError = GoogleOAuthError.server("500")
        await calendar.refresh()
        XCTAssertEqual(calendar.lastError, "500")
        XCTAssertTrue(settings.googleCalendarEnabled)
        XCTAssertTrue(store.hasToken)
        XCTAssertEqual(calendar.eventOverlapping(at: now)?.title, "Standup")
        XCTAssertEqual(calendar.upcoming.first?.title, "Standup")
    }

    func testAuthFailureClearsLastGoogleEvents() async throws {
        let settings = try CalendarControllerFixtures.makeSettings(in: self)
        let store = CalendarControllerFixtures.makeStore(in: self)
        try store.save(CalendarControllerFixtures.sampleToken())
        settings.googleCalendarEnabled = true
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let live = CalendarEvent(
            id: "google:live",
            title: "Standup",
            start: now,
            end: now.addingTimeInterval(1800),
            source: .google,
        )
        let google = StubGoogleCalendarAPI(events: [live])
        let calendar = CalendarController(
            settings: settings,
            tokenStore: store,
            apple: StubAppleCalendarAccess(),
            googleAPI: google,
            oauth: StubGoogleOAuth(),
        ) { now }
        await calendar.refresh()
        XCTAssertEqual(calendar.eventOverlapping(at: now)?.title, "Standup")
        google.fetchError = GoogleOAuthError.unauthorized
        await calendar.refresh()
        XCTAssertEqual(calendar.lastError, GoogleOAuthError.unauthorized.errorDescription)
        XCTAssertFalse(store.hasToken)
        XCTAssertFalse(settings.googleCalendarEnabled)
        XCTAssertNil(calendar.eventOverlapping(at: now))
        XCTAssertTrue(calendar.upcoming.isEmpty)
    }

    func testConnectedGoogleEmailMarksMatchingAttendeeAsSelf() async throws {
        let settings = try CalendarControllerFixtures.makeSettings(in: self)
        let store = CalendarControllerFixtures.makeStore(in: self)
        try store.save(CalendarControllerFixtures.sampleToken(email: "user@example.com"))
        settings.googleCalendarEnabled = true
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let live = CalendarEvent(
            id: "google:live",
            title: "Standup",
            start: now,
            end: now.addingTimeInterval(1800),
            source: .google,
            attendees: [
                CalendarAttendee(email: "user@example.com", displayName: "Me Person"),
                CalendarAttendee(email: "alice@corp.com", displayName: "Alice"),
            ],
        )
        let google = StubGoogleCalendarAPI(events: [live], email: "user@example.com")
        let calendar = CalendarController(
            settings: settings,
            tokenStore: store,
            apple: StubAppleCalendarAccess(),
            googleAPI: google,
            oauth: StubGoogleOAuth(),
        ) { now }
        await calendar.refresh()
        let overlapping = try XCTUnwrap(calendar.eventOverlapping(at: now))
        XCTAssertEqual(
            overlapping.attendees.first { $0.normalizedEmail == "user@example.com" }?.isSelf,
            true,
        )
        XCTAssertEqual(CalendarAttendeePicker.names(from: overlapping.attendees), ["Alice"])
    }
}
