@testable import MeetingTranscriber
import XCTest

final class PKCEAndLoopbackTests: XCTestCase {
    func testS256ChallengeIsStableForKnownVerifier() {
        let pkce = PKCE.fromVerifier("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testParseCallbackExtractsCodeAndState() {
        let callback = LoopbackRedirectServer.parseCallback(from: "/?code=4/0A&state=abc")
        XCTAssertEqual(callback.code, "4/0A")
        XCTAssertEqual(callback.state, "abc")
        XCTAssertNil(callback.error)
    }

    func testParseCallbackDenied() {
        let callback = LoopbackRedirectServer.parseCallback(from: "/?error=access_denied&state=abc")
        XCTAssertEqual(callback.error, "access_denied")
        XCTAssertNil(callback.code)
    }

    func testAuthorizationURLContainsPKCEAndOfflineAccess() throws {
        let client = GoogleOAuthClient { _ in }
        let url = try XCTUnwrap(client.authorizationURL(
            clientID: "cid.apps.googleusercontent.com",
            redirectURI: "http://127.0.0.1:54321",
            state: "st",
            challenge: "ch",
        ))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        XCTAssertEqual(value("client_id"), "cid.apps.googleusercontent.com")
        XCTAssertEqual(value("redirect_uri"), "http://127.0.0.1:54321")
        XCTAssertEqual(value("code_challenge"), "ch")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("access_type"), "offline")
        XCTAssertEqual(value("prompt"), "consent")
        XCTAssertEqual(value("scope")?.contains("calendar.readonly"), true)
    }
}
