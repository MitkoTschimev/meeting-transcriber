import Foundation

/// Keychain operations used by `CalendarTokenStore`. Injectable so tests can
/// fail a save without touching the process Keychain.
protocol KeychainStoring: Sendable {
    func save(key: String, value: String) -> Bool
    func read(key: String) -> String?
    func exists(key: String) -> Bool
    func delete(key: String)
}

struct LiveKeychain: KeychainStoring {
    func save(key: String, value: String) -> Bool {
        KeychainHelper.save(key: key, value: value)
    }

    func read(key: String) -> String? {
        KeychainHelper.read(key: key)
    }

    func exists(key: String) -> Bool {
        KeychainHelper.exists(key: key)
    }

    func delete(key: String) {
        KeychainHelper.delete(key: key)
    }
}

/// Keychain-backed Google OAuth token. Account name is injectable so tests
/// never touch the production item (same reason as `AppSettings` API keys).
struct CalendarTokenStore: Sendable {
    let account: String
    let keychain: any KeychainStoring

    init(account: String = "googleCalendarOAuth", keychain: any KeychainStoring = LiveKeychain()) {
        self.account = account
        self.keychain = keychain
    }

    func save(_ token: GoogleOAuthToken) throws {
        let data = try JSONEncoder().encode(token)
        guard let value = String(data: data, encoding: .utf8) else {
            throw GoogleOAuthError.keychainSaveFailed
        }
        guard keychain.save(key: account, value: value),
              keychain.read(key: account) == value else {
            throw GoogleOAuthError.keychainSaveFailed
        }
    }

    func read() -> GoogleOAuthToken? {
        guard let value = keychain.read(key: account),
              let data = value.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(GoogleOAuthToken.self, from: data)
    }

    var hasToken: Bool {
        keychain.exists(key: account)
    }

    func delete() {
        keychain.delete(key: account)
    }
}
