import Foundation

/// Access + refresh tokens from Google's OAuth token endpoint.
///
/// Stored as JSON in the Keychain via `CalendarTokenStore`. `refresh_token` is
/// only present on the first consent; later refresh responses keep the stored
/// one. `email` is filled from calendarList after connect, not from the token
/// payload — it is display-only and lives next to the tokens so Disconnect
/// clears it in one Keychain delete.
struct GoogleOAuthToken: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiry: Date
    var tokenType: String
    var scope: String?
    var email: String?

    func isExpired(at now: Date = Date(), skew: TimeInterval = 60) -> Bool {
        expiry <= now.addingTimeInterval(skew)
    }

    static func parse(_ data: Data, at now: Date = Date(), existingRefresh: String? = nil) throws -> Self {
        let payload = try JSONDecoder().decode(TokenPayload.self, from: data)
        let refresh = payload.refreshToken ?? existingRefresh ?? ""
        guard !payload.accessToken.isEmpty else {
            throw GoogleOAuthError.tokenExchangeFailed("Google did not return an access token.")
        }
        guard !refresh.isEmpty else {
            throw GoogleOAuthError.tokenExchangeFailed("Google did not return a refresh token. Disconnect and connect again.")
        }
        return Self(
            accessToken: payload.accessToken,
            refreshToken: refresh,
            expiry: now.addingTimeInterval(TimeInterval(payload.expiresIn)),
            tokenType: payload.tokenType ?? "Bearer",
            scope: payload.scope,
            email: nil,
        )
    }
}

private struct TokenPayload: Decodable {
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String?
    let tokenType: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case scope
    }
}

enum GoogleOAuthError: Error, Equatable, LocalizedError {
    case missingClientID
    case denied
    case stateMismatch
    case timeout
    case noCode
    case keychainSaveFailed
    case unauthorized
    case tokenExchangeFailed(String)
    case server(String)

    var isAuthFailure: Bool {
        switch self {
        case .unauthorized:
            true

        case let .tokenExchangeFailed(message), let .server(message):
            message.contains("invalid_grant")

        default:
            false
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            "Add a Google OAuth client ID in Settings before connecting Google Calendar."

        case .denied:
            "Google Calendar access was cancelled."

        case .stateMismatch:
            "Google Calendar sign-in could not be verified. Try connecting again."

        case .timeout:
            "Google Calendar sign-in timed out. Try connecting again."

        case .noCode:
            "Google Calendar did not return an authorization code."

        case .keychainSaveFailed:
            "Could not store the Google Calendar token in the Keychain. Connect again."

        case .unauthorized:
            "Google Calendar sign-in expired. Connect again in Settings."

        case let .tokenExchangeFailed(message), let .server(message):
            message
        }
    }

    static func fromHTTP(status: Int, data: Data, tokenExchange: Bool = false) -> Self {
        let text = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
        if status == 401 || text.contains("invalid_grant") {
            return .unauthorized
        }
        return tokenExchange ? .tokenExchangeFailed(text) : .server(text)
    }
}
