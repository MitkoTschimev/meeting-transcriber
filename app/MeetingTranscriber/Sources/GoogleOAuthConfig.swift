import Foundation

/// Resolves the Google OAuth Desktop client ID for this install.
///
/// Open-source builds cannot ship a shared client secret, and a Desktop client
/// is a public client (PKCE, no secret). The ID is looked up in this order:
/// 1. Settings (user-pasted)
/// 2. `MEETINGTRANSCRIBER_GOOGLE_OAUTH_CLIENT_ID` (packagers / local env)
/// 3. Info.plist `GoogleOAuthClientID` (optional bundled ID)
enum GoogleOAuthConfig {
    static let environmentKey = "MEETINGTRANSCRIBER_GOOGLE_OAUTH_CLIENT_ID"
    static let infoPlistKey = "GoogleOAuthClientID"
    static let calendarReadonlyScope = "https://www.googleapis.com/auth/calendar.readonly"
    // Known-constant Google endpoints; `URL(string:)` cannot fail on these.
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    static let calendarListEndpoint = URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
    static let eventsEndpoint = URL(string: "https://www.googleapis.com/calendar/v3/calendars")!

    static func clientID(
        settingsValue: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundled: String? = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String,
    ) -> String {
        let sources = [settingsValue, environment[environmentKey] ?? "", bundled ?? ""]
        for source in sources {
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}
