@testable import MeetingTranscriber
import XCTest

final class StubGoogleCalendarAPI: GoogleCalendarFetching, @unchecked Sendable {
    var events: [CalendarEvent]
    var email: String?
    var fetchError: (any Error)?
    var fetchGate: AsyncGate?

    init(
        events: [CalendarEvent] = [],
        email: String? = nil,
        fetchError: (any Error)? = nil,
        fetchGate: AsyncGate? = nil,
    ) {
        self.events = events
        self.email = email
        self.fetchError = fetchError
        self.fetchGate = fetchGate
    }

    func fetchEvents(accessToken _: String, from: Date, to: Date) async throws -> [CalendarEvent] {
        if let fetchGate {
            await fetchGate.wait()
        }
        if let fetchError { throw fetchError }
        return events.filter { $0.end >= from && $0.start <= to }
    }

    // swiftlint:disable:next async_without_await
    func primaryEmail(accessToken _: String) async -> String? {
        email
    }
}

final class StubGoogleOAuth: GoogleOAuthPerforming, @unchecked Sendable {
    var authorizeToken: GoogleOAuthToken?
    var authorizeError: GoogleOAuthError?
    var refreshResult: GoogleOAuthToken?
    var refreshError: GoogleOAuthError?
    var revokeCount = 0
    var lastRevoked: GoogleOAuthToken?
    var onRevoke: (() async throws -> Void)?

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

    func revoke(_ token: GoogleOAuthToken) async {
        revokeCount += 1
        lastRevoked = token
        try? await onRevoke?()
    }
}

struct FailingKeychain: KeychainStoring {
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

enum CalendarControllerFixtures {
    static func makeSettings(in test: XCTestCase) throws -> AppSettings {
        let suiteName = "CalendarControllerTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        test.addTeardownBlock { DefaultsSuite.remove(suiteName) }
        return AppSettings(defaults: suite)
    }

    static func makeStore(in test: XCTestCase) -> CalendarTokenStore {
        let account = "CalendarControllerTests-token-\(UUID().uuidString)"
        test.addTeardownBlock { KeychainHelper.delete(key: account) }
        return CalendarTokenStore(account: account)
    }

    static func sampleToken(
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
}
