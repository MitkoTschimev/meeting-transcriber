@testable import MeetingTranscriber
import XCTest

@MainActor
final class CalendarControllerDisconnectTests: XCTestCase {
    func testDisconnectClearsTokenThenRevokes() async throws {
        let settings = try CalendarControllerFixtures.makeSettings(in: self)
        let store = CalendarControllerFixtures.makeStore(in: self)
        let token = CalendarControllerFixtures.sampleToken()
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

    func testDisconnectDeletesKeychainBeforeRevokeSoReconnectSurvives() async throws {
        let settings = try CalendarControllerFixtures.makeSettings(in: self)
        let store = CalendarControllerFixtures.makeStore(in: self)
        try store.save(CalendarControllerFixtures.sampleToken(access: "old", refresh: "old-r"))
        settings.googleCalendarEnabled = true
        let oauth = StubGoogleOAuth()
        let calendar = CalendarController(
            settings: settings,
            tokenStore: store,
            apple: StubAppleCalendarAccess(),
            oauth: oauth,
        )
        let newToken = CalendarControllerFixtures.sampleToken(access: "new", refresh: "new-r")
        var emptyAtRevoke = false
        oauth.onRevoke = {
            emptyAtRevoke = store.read() == nil
            try store.save(newToken)
        }
        await calendar.disconnectGoogle()
        XCTAssertTrue(emptyAtRevoke)
        XCTAssertEqual(oauth.lastRevoked?.refreshToken, "old-r")
        XCTAssertEqual(store.read()?.accessToken, "new")
        XCTAssertTrue(calendar.googleConnected)
    }

    func testDisconnectClearsLastGoogleEvents() async throws {
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
        let calendar = CalendarController(
            settings: settings,
            tokenStore: store,
            apple: StubAppleCalendarAccess(),
            googleAPI: StubGoogleCalendarAPI(events: [live]),
            oauth: StubGoogleOAuth(),
        ) { now }
        await calendar.refresh()
        XCTAssertEqual(calendar.eventOverlapping(at: now)?.title, "Standup")
        await calendar.disconnectGoogle()
        XCTAssertNil(calendar.eventOverlapping(at: now))
        XCTAssertTrue(calendar.upcoming.isEmpty)
    }

    func testInFlightFetchAfterDisconnectDoesNotRestoreGoogleAgenda() async throws {
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
        let gate = AsyncGate()
        let google = StubGoogleCalendarAPI(events: [live], fetchGate: gate)
        let calendar = CalendarController(
            settings: settings,
            tokenStore: store,
            apple: StubAppleCalendarAccess(),
            googleAPI: google,
            oauth: StubGoogleOAuth(),
        ) { now }
        let refreshTask = Task { await calendar.refresh() }
        if await !CalendarControllerFixtures.waitForWaiter(gate) {
            XCTFail("Google fetch did not start")
            await gate.open()
            await refreshTask.value
            return
        }
        await calendar.disconnectGoogle()
        XCTAssertTrue(calendar.upcoming.isEmpty)
        XCTAssertNil(calendar.eventOverlapping(at: now))
        XCTAssertNil(store.read())
        await gate.open()
        await refreshTask.value
        XCTAssertTrue(calendar.upcoming.isEmpty)
        XCTAssertNil(calendar.eventOverlapping(at: now))
        XCTAssertNil(store.read())
        XCTAssertFalse(settings.googleCalendarEnabled)
        XCTAssertFalse(calendar.googleConnected)
    }

    func testInFlightOAuthRefreshDoesNotOverwriteReconnectToken() async throws {
        let settings = try CalendarControllerFixtures.makeSettings(in: self)
        settings.googleOAuthClientID = "cid.apps.googleusercontent.com"
        let store = CalendarControllerFixtures.makeStore(in: self)
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        try store.save(CalendarControllerFixtures.sampleToken(
            access: "old-a",
            refresh: "old-r",
            expiry: Date(timeIntervalSince1970: 1),
        ))
        settings.googleCalendarEnabled = true
        let newToken = CalendarControllerFixtures.sampleToken(
            access: "new-a",
            refresh: "new-r",
            expiry: now.addingTimeInterval(3600),
        )
        let gate = AsyncGate()
        let oauth = StubGoogleOAuth(
            authorizeToken: newToken,
            refreshResult: CalendarControllerFixtures.sampleToken(
                access: "old-a-refreshed",
                refresh: "old-r",
                expiry: now.addingTimeInterval(3600),
            ),
        )
        oauth.refreshGate = gate
        let live = CalendarEvent(
            id: "google:live",
            title: "Standup",
            start: now,
            end: now.addingTimeInterval(1800),
            source: .google,
        )
        let calendar = CalendarController(
            settings: settings,
            tokenStore: store,
            apple: StubAppleCalendarAccess(),
            googleAPI: StubGoogleCalendarAPI(events: [live]),
            oauth: oauth,
        ) { now }
        let refreshTask = Task { await calendar.refresh() }
        if await !CalendarControllerFixtures.waitForWaiter(gate) {
            XCTFail("OAuth refresh did not start")
            await gate.open()
            await refreshTask.value
            return
        }
        await calendar.disconnectGoogle()
        await calendar.connectGoogle()
        XCTAssertEqual(store.read()?.refreshToken, "new-r")
        await gate.open()
        await refreshTask.value
        XCTAssertEqual(store.read()?.refreshToken, "new-r")
        XCTAssertEqual(store.read()?.accessToken, "new-a")
        XCTAssertTrue(settings.googleCalendarEnabled)
        XCTAssertEqual(calendar.upcoming.first?.title, "Standup")
    }
}
