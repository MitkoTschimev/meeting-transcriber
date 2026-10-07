import Foundation

/// Google Desktop OAuth (PKCE + loopback redirect). Browser is opened via an
/// injected opener so tests never launch Safari.
protocol GoogleOAuthPerforming: Sendable {
    func authorize(clientID: String) async throws -> GoogleOAuthToken
    func refresh(_ token: GoogleOAuthToken, clientID: String) async throws -> GoogleOAuthToken
    func revoke(_ token: GoogleOAuthToken) async
}

struct GoogleOAuthClient: GoogleOAuthPerforming, Sendable {
    var session: URLSession
    var openURL: @Sendable (URL) -> Void
    var makePKCE: @Sendable () -> PKCE
    var makeState: @Sendable () -> String
    var startLoopback: @Sendable () throws -> any OAuthRedirectListening
    var timeout: TimeInterval

    init(
        openURL: @escaping @Sendable (URL) -> Void,
        session: URLSession = .shared,
        makePKCE: @escaping @Sendable () -> PKCE = { PKCE.generate() },
        makeState: @escaping @Sendable () -> String = { PKCE.generate().verifier },
        startLoopback: @escaping @Sendable () throws -> any OAuthRedirectListening = {
            try LoopbackRedirectServer.start()
        },
        timeout: TimeInterval = 180,
    ) {
        self.session = session
        self.openURL = openURL
        self.makePKCE = makePKCE
        self.makeState = makeState
        self.startLoopback = startLoopback
        self.timeout = timeout
    }

    func authorize(clientID: String) async throws -> GoogleOAuthToken {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GoogleOAuthError.missingClientID }

        let pkce = makePKCE()
        let state = makeState()
        let server = try startLoopback()
        defer { server.stop() }

        guard let authURL = authorizationURL(
            clientID: trimmed,
            redirectURI: server.redirectURI,
            state: state,
            challenge: pkce.challenge,
        ) else {
            throw GoogleOAuthError.server("Could not build the Google sign-in URL.")
        }
        openURL(authURL)

        let callback = try await server.waitForCallback(timeout: timeout)
        if callback.error == "access_denied" { throw GoogleOAuthError.denied }
        if let error = callback.error, !error.isEmpty {
            throw GoogleOAuthError.server(error)
        }
        guard callback.state == state else { throw GoogleOAuthError.stateMismatch }
        guard let code = callback.code, !code.isEmpty else { throw GoogleOAuthError.noCode }

        return try await exchangeCode(
            code,
            clientID: trimmed,
            redirectURI: server.redirectURI,
            verifier: pkce.verifier,
        )
    }

    func refresh(_ token: GoogleOAuthToken, clientID: String) async throws -> GoogleOAuthToken {
        let data = try await postForm(
            [
                "refresh_token": token.refreshToken,
                "client_id": clientID,
                "grant_type": "refresh_token",
            ],
            to: GoogleOAuthConfig.tokenEndpoint,
            tokenExchange: true,
        )
        var refreshed = try GoogleOAuthToken.parse(data, existingRefresh: token.refreshToken)
        refreshed.email = token.email
        return refreshed
    }

    /// Best-effort revoke at Google's token revocation endpoint. Disconnect
    /// still deletes the local Keychain item if this fails.
    func revoke(_ token: GoogleOAuthToken) async {
        let value = token.refreshToken.isEmpty ? token.accessToken : token.refreshToken
        guard !value.isEmpty else { return }
        _ = try? await postForm(
            ["token": value],
            to: GoogleOAuthConfig.revokeEndpoint,
            tokenExchange: false,
        )
    }

    func authorizationURL(clientID: String, redirectURI: String, state: String, challenge: String) -> URL? {
        var components = URLComponents(url: GoogleOAuthConfig.authorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleOAuthConfig.calendarReadonlyScope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components?.url
    }

    private func exchangeCode(
        _ code: String,
        clientID: String,
        redirectURI: String,
        verifier: String,
    ) async throws -> GoogleOAuthToken {
        let body = [
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ]
        let data = try await postForm(body, to: GoogleOAuthConfig.tokenEndpoint, tokenExchange: true)
        return try GoogleOAuthToken.parse(data)
    }

    private func postForm(_ fields: [String: String], to url: URL, tokenExchange: Bool) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormURLEncoder.encode(fields)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ... 299).contains(status) else {
            throw GoogleOAuthError.fromHTTP(status: status, data: data, tokenExchange: tokenExchange)
        }
        return data
    }
}
