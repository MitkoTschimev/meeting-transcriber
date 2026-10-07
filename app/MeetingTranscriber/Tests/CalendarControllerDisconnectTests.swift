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
        let deadline = Date().addingTimeInterval(1)
        while await !(gate.hasWaiter) {
            if Date() > deadline {
                XCTFail("Google fetch did not start")
                await gate.open()
                await refreshTask.value
                return
            }
            await Task.yield()
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
}
