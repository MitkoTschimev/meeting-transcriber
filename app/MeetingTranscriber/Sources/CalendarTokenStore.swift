import Foundation

/// Keychain-backed Google OAuth token. Account name is injectable so tests
/// never touch the production item (same reason as `AppSettings` API keys).
struct CalendarTokenStore: Sendable {
    let account: String

    init(account: String = "googleCalendarOAuth") {
        self.account = account
    }

    func save(_ token: GoogleOAuthToken) throws {
        let data = try JSONEncoder().encode(token)
        guard let value = String(data: data, encoding: .utf8) else { return }
        KeychainHelper.save(key: account, value: value)
    }

    func read() -> GoogleOAuthToken? {
        guard let value = KeychainHelper.read(key: account),
              let data = value.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(GoogleOAuthToken.self, from: data)
    }

    var hasToken: Bool {
        KeychainHelper.exists(key: account)
    }

    func delete() {
        KeychainHelper.delete(key: account)
    }
}
