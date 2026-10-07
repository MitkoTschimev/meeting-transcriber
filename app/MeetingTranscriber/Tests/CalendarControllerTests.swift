@testable import MeetingTranscriber
import XCTest

@MainActor
final class CalendarControllerTests: XCTestCase {
    private func makeSettings() throws -> AppSettings {
        let suiteName = "CalendarControllerTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { DefaultsSuite.remove(suiteName) }
        return AppSettings(defaults: suite)
    }

    private func makeStore() -> CalendarTokenStore {
        let account = "CalendarControllerTests-token-\(UUID().uuidString)"
        addTeardownBlock { KeychainHelper.delete(key: account) }
        return CalendarTokenStore(account: account)
    }

    private func sampleToken(
        access: String = "ya29.test",
        refresh: String = "1//r",
        expiry: Date = Date().addingTimeInterval(3600),
        email: String? = "user@example.com",
    ) -> GoogleOAuthToken {
        GoogleOAuthToken(
            accessToken: access,
            refreshToken: refresh,
            expiry: expiry,
            tokenType: "Bearer",
            email: email,
        )
    }

    func testAppleGrantEnablesAndListsEvents() async throws {
        let settings = try makeSettings()
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
            tokenStore: makeStore(),
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
        let settings = try makeSettings()
        let apple = StubAppleCalendarAccess(status: .notDetermined, requestResult: false)
        let calendar = CalendarController(
            settings: settings,
            tokenStore: makeStore(),
            apple: apple,
            oauth: StubGoogleOAuth(),
        )
        settings.appleCalendarEnabled = true
        await calendar.requestAppleAccess()
        XCTAssertFalse(settings.appleCalendarEnabled)
        XCTAssertEqual(calendar.appleStatus, .denied)
        XCTAssertTrue(calendar.upcoming.isEmpty)
    }

    func testDisconnectRevokesThenClearsTokenAndToggle() async throws {
        let settings = try makeSettings()
        let store = makeStore()
        let token = sampleToken()
        try store.save(token)
        settings.googleCalendarEnabled = true
        let oauth = StubGoogleOAuth()
        let calendar = CalendarController(
            settings: settings,
            tokenStore: store,
            apple: StubAppleCalendarAccess(),
            oauth: oauth,
        )
        XCTAssertTrue(calendar.googleConnected)
        await calendar.disconnectGoogle()
        XCTAssertEqual(oauth.revokeCount, 1)
        XCTAssertEqual(oauth.lastRevoked?.refreshToken, token.refreshToken)
        XCTAssertFalse(calendar.googleConnected)
        XCTAssertFalse(settings.googleCalendarEnabled)
        XCTAssertNil(store.read())
    }

    func testGoogleRefreshRestoresEmailAndListsEvents() async throws {
        let settings = try makeSettings()
        let store = makeStore()
        try store.save(sampleToken(expiry: Date(timeIntervalSince1970: 1_720_003_600)))
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
        let settings = try makeSettings()
        settings.googleOAuthClientID = "cid.apps.googleusercontent.com"
        let store = CalendarTokenStore(account: "failing-\(UUID().uuidString)", keychain: FailingKeychain())
        let oauth = StubGoogleOAuth(authorizeToken: sampleToken())
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
        let settings = try makeSettings()
        settings.googleOAuthClientID = ""
        let store = makeStore()
        try store.save(sampleToken(expiry: Date(timeIntervalSince1970: 1)))
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
        let settings = try makeSettings()
        settings.googleOAuthClientID = "cid.apps.googleusercontent.com"
        let store = makeStore()
        try store.save(sampleToken(expiry: Date(timeIntervalSince1970: 1)))
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
        let settings = try makeSettings()
        settings.googleOAuthClientID = "cid.apps.googleusercontent.com"
        let store = makeStore()
        try store.save(sampleToken())
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
        let settings = try makeSettings()
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
            tokenStore: makeStore(),
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
        let settings = try makeSettings()
        settings.googleOAuthClientID = "cid.apps.googleusercontent.com"
        let store = makeStore()
        try store.save(sampleToken(access: "old", expiry: Date(timeIntervalSince1970: 1)))
        settings.googleCalendarEnabled = true
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let start = now.addingTimeInterval(60)
        let oauth = StubGoogleOAuth(refreshResult: sampleToken(access: "new", expiry: now.addingTimeInterval(3600)))
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
}

private struct StubGoogleCalendarAPI: GoogleCalendarFetching {
    var events: [CalendarEvent] = []
    var email: String?
    var fetchError: (any Error)?

    // Protocol requirement is async (live client hits the network).
    // swiftlint:disable:next async_without_await
    func fetchEvents(accessToken _: String, from: Date, to: Date) async throws -> [CalendarEvent] {
        if let fetchError { throw fetchError }
        return events.filter { $0.end >= from && $0.start <= to }
    }

    // swiftlint:disable:next async_without_await
    func primaryEmail(accessToken _: String) async -> String? {
        email
    }
}

private final class StubGoogleOAuth: GoogleOAuthPerforming, @unchecked Sendable {
    var authorizeToken: GoogleOAuthToken?
    var authorizeError: GoogleOAuthError?
    var refreshResult: GoogleOAuthToken?
    var refreshError: GoogleOAuthError?
    var revokeCount = 0
    var lastRevoked: GoogleOAuthToken?

    init(
        authorizeToken: GoogleOAuthToken? = nil,
        authorizeError: GoogleOAuthError? = nil,
        refreshResult: GoogleOAuthToken? = nil,
        refreshError: GoogleOAuthError? = nil,
    ) {
        self.authorizeToken = authorizeToken
        self.authorizeError = authorizeError
        self.refreshResult = refreshResult
        self.refreshError = refreshError
    }

    // swiftlint:disable:next async_without_await
    func authorize(clientID _: String) async throws -> GoogleOAuthToken {
        if let authorizeError { throw authorizeError }
        guard let authorizeToken else {
            throw GoogleOAuthError.server("no stub token")
        }
        return authorizeToken
    }

    // swiftlint:disable:next async_without_await
    func refresh(_ token: GoogleOAuthToken, clientID _: String) async throws -> GoogleOAuthToken {
        if let refreshError { throw refreshError }
        if let refreshResult { return refreshResult }
        return token
    }

    // swiftlint:disable:next async_without_await
    func revoke(_ token: GoogleOAuthToken) async {
        revokeCount += 1
        lastRevoked = token
    }
}

private struct FailingKeychain: KeychainStoring {
    func save(key _: String, value _: String) -> Bool {
        false
    }

    func read(key _: String) -> String? {
        nil
    }

    func exists(key _: String) -> Bool {
        false
    }

    func delete(key _: String) {}
}
