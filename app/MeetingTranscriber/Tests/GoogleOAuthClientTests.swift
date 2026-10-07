@testable import MeetingTranscriber
import XCTest

final class GoogleOAuthClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        clearMocks()
    }

    override func tearDown() {
        clearMocks()
        super.tearDown()
    }

    private func clearMocks() {
        MockURLProtocol.handler = nil
        MockURLProtocol.errorHandler = nil
        MockURLProtocol.rawResponseHandler = nil
        MockURLProtocol.hangHandler = nil
    }

    func testFormEncodingEscapesPlusAmpersandAndEquals() {
        let encoded = FormURLEncoder.encodeString(["code": "a+b=c&d", "client_id": "x"])
        XCTAssertEqual(encoded, "client_id=x&code=a%2Bb%3Dc%26d")
        XCTAssertEqual(FormURLEncoder.escape("a+b"), "a%2Bb")
        XCTAssertEqual(FormURLEncoder.escape("a=b"), "a%3Db")
        XCTAssertEqual(FormURLEncoder.escape("a&b"), "a%26b")
    }

    func testAuthorizeExchangesCodeWithPlusInBody() async throws {
        let captured = OSAllocatedUnfairLock<String>(initialState: "")
        MockURLProtocol.handler = { request in
            captured.withLock { $0 = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "" }
            return Self.ok(request, json: Self.tokenJSON)
        }
        let client = GoogleOAuthClient(
            openURL: { _ in },
            session: Self.mockSession(),
            makePKCE: { PKCE.fromVerifier("verifier") },
            makeState: { "st" },
            startLoopback: {
                StubOAuthRedirect(callback: .init(code: "a+b=c&d", state: "st"))
            },
        )
        let token = try await client.authorize(clientID: "cid.apps.googleusercontent.com")
        XCTAssertEqual(token.accessToken, "ya29.a")
        XCTAssertEqual(token.refreshToken, "1//r")
        let body = captured.withLock(\.self)
        XCTAssertTrue(body.contains("code=a%2Bb%3Dc%26d"), body)
        XCTAssertTrue(body.contains("grant_type=authorization_code"), body)
        XCTAssertTrue(body.contains("code_verifier=verifier"), body)
        XCTAssertTrue(body.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A9"), body)
    }

    func testRefreshPostsFormAndKeepsRefreshToken() async throws {
        let captured = OSAllocatedUnfairLock<(url: String, body: String)>(initialState: ("", ""))
        MockURLProtocol.handler = { request in
            captured.withLock { state in
                state = (
                    request.url?.absoluteString ?? "",
                    String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "",
                )
            }
            return Self.ok(request, json: #"{"access_token":"new","expires_in":60,"token_type":"Bearer"}"#)
        }
        let client = GoogleOAuthClient(openURL: { _ in }, session: Self.mockSession())
        let existing = GoogleOAuthToken(
            accessToken: "old",
            refreshToken: "keep+me",
            expiry: Date(timeIntervalSince1970: 1),
            tokenType: "Bearer",
            email: "user@example.com",
        )
        let refreshed = try await client.refresh(existing, clientID: "cid")
        XCTAssertEqual(refreshed.accessToken, "new")
        XCTAssertEqual(refreshed.refreshToken, "keep+me")
        XCTAssertEqual(refreshed.email, "user@example.com")
        let capturedRequest = captured.withLock(\.self)
        XCTAssertEqual(capturedRequest.url, GoogleOAuthConfig.tokenEndpoint.absoluteString)
        XCTAssertTrue(capturedRequest.body.contains("grant_type=refresh_token"), capturedRequest.body)
        XCTAssertTrue(capturedRequest.body.contains("refresh_token=keep%2Bme"), capturedRequest.body)
    }

    func testRefreshInvalidGrantThrowsUnauthorized() async throws {
        MockURLProtocol.handler = { request in
            Self.http(request, status: 400, json: #"{"error":"invalid_grant"}"#)
        }
        let client = GoogleOAuthClient(openURL: { _ in }, session: Self.mockSession())
        let existing = GoogleOAuthToken(
            accessToken: "old",
            refreshToken: "r",
            expiry: Date(timeIntervalSince1970: 1),
            tokenType: "Bearer",
        )
        do {
            _ = try await client.refresh(existing, clientID: "cid")
            XCTFail("expected unauthorized")
        } catch let error as GoogleOAuthError {
            XCTAssertEqual(error, .unauthorized)
            XCTAssertTrue(error.isAuthFailure)
        }
    }

    func testRevokePostsTokenToRevokeEndpoint() async {
        let captured = OSAllocatedUnfairLock<(url: String, body: String)>(initialState: ("", ""))
        MockURLProtocol.handler = { request in
            captured.withLock { state in
                state = (
                    request.url?.absoluteString ?? "",
                    String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "",
                )
            }
            return Self.ok(request, json: "")
        }
        let client = GoogleOAuthClient(openURL: { _ in }, session: Self.mockSession())
        await client.revoke(GoogleOAuthToken(
            accessToken: "ya29",
            refreshToken: "1//r+v",
            expiry: Date().addingTimeInterval(60),
            tokenType: "Bearer",
        ))
        let capturedRequest = captured.withLock(\.self)
        XCTAssertEqual(capturedRequest.url, GoogleOAuthConfig.revokeEndpoint.absoluteString)
        XCTAssertEqual(capturedRequest.body, "token=1%2F%2Fr%2Bv")
    }

    private static func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    private static func ok(_ request: URLRequest, json: String) -> (HTTPURLResponse, Data) {
        http(request, status: 200, json: json)
    }

    private static func http(_ request: URLRequest, status: Int, json: String) -> (HTTPURLResponse, Data) {
        let url = request.url ?? GoogleOAuthConfig.tokenEndpoint
        // swiftlint:disable:next force_unwrapping
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (response, Data(json.utf8))
    }

    private static let tokenJSON =
        #"{"access_token":"ya29.a","expires_in":3600,"refresh_token":"1//r","token_type":"Bearer"}"#
}

private struct StubOAuthRedirect: OAuthRedirectListening {
    var redirectURI = "http://127.0.0.1:9"
    var callback: LoopbackRedirectServer.Callback

    // swiftlint:disable:next async_without_await
    func waitForCallback(timeout _: TimeInterval) async -> LoopbackRedirectServer.Callback {
        callback
    }

    func stop() {}
}
