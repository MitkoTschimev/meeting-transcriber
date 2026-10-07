@testable import MeetingTranscriber
import XCTest

final class GoogleOAuthTokenTests: XCTestCase {
    func testParseAccessAndRefresh() throws {
        let json = Data(#"{"access_token":"ya29.a","expires_in":3600,"refresh_token":"1//r","token_type":"Bearer","scope":"https://www.googleapis.com/auth/calendar.readonly"}"#.utf8)
        let now = Date(timeIntervalSince1970: 1000)
        let token = try GoogleOAuthToken.parse(json, at: now)
        XCTAssertEqual(token.accessToken, "ya29.a")
        XCTAssertEqual(token.refreshToken, "1//r")
        XCTAssertEqual(token.expiry, Date(timeIntervalSince1970: 4600))
        XCTAssertFalse(token.isExpired(at: now))
        XCTAssertTrue(token.isExpired(at: now.addingTimeInterval(3600)))
    }

    func testRefreshKeepsExistingRefreshToken() throws {
        let json = Data(#"{"access_token":"new","expires_in":60,"token_type":"Bearer"}"#.utf8)
        let token = try GoogleOAuthToken.parse(json, existingRefresh: "keep-me")
        XCTAssertEqual(token.accessToken, "new")
        XCTAssertEqual(token.refreshToken, "keep-me")
    }

    func testMissingAccessTokenThrows() {
        let json = Data(#"{"access_token":"","expires_in":60,"refresh_token":"r"}"#.utf8)
        XCTAssertThrowsError(try GoogleOAuthToken.parse(json))
    }

    func testClientIDResolutionOrder() {
        XCTAssertEqual(
            GoogleOAuthConfig.clientID(
                settingsValue: " from-settings ",
                environment: [GoogleOAuthConfig.environmentKey: "from-env"],
                bundled: "from-plist",
            ),
            "from-settings",
        )
        XCTAssertEqual(
            GoogleOAuthConfig.clientID(
                settingsValue: "  ",
                environment: [GoogleOAuthConfig.environmentKey: "from-env"],
                bundled: "from-plist",
            ),
            "from-env",
        )
        XCTAssertEqual(
            GoogleOAuthConfig.clientID(settingsValue: "", environment: [:], bundled: "from-plist"),
            "from-plist",
        )
        XCTAssertEqual(GoogleOAuthConfig.clientID(settingsValue: "", environment: [:], bundled: nil), "")
    }
}
