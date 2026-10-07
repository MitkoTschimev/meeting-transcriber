@testable import MeetingTranscriber
import XCTest

final class CalendarTokenStoreTests: XCTestCase {
    func testSaveThrowsWhenKeychainWriteFails() {
        let store = CalendarTokenStore(account: "token-store-fail", keychain: FailingKeychain())
        let token = GoogleOAuthToken(
            accessToken: "ya29",
            refreshToken: "1//r",
            expiry: Date().addingTimeInterval(60),
            tokenType: "Bearer",
        )
        XCTAssertThrowsError(try store.save(token)) { error in
            XCTAssertEqual(error as? GoogleOAuthError, .keychainSaveFailed)
        }
        XCTAssertFalse(store.hasToken)
        XCTAssertNil(store.read())
    }

    func testSaveThrowsWhenReadBackDoesNotMatch() {
        let store = CalendarTokenStore(account: "token-store-mismatch", keychain: WriteWithoutReadbackKeychain())
        let token = GoogleOAuthToken(
            accessToken: "ya29",
            refreshToken: "1//r",
            expiry: Date().addingTimeInterval(60),
            tokenType: "Bearer",
        )
        XCTAssertThrowsError(try store.save(token)) { error in
            XCTAssertEqual(error as? GoogleOAuthError, .keychainSaveFailed)
        }
    }
}

private struct WriteWithoutReadbackKeychain: KeychainStoring {
    func save(key _: String, value _: String) -> Bool {
        true
    }

    func read(key _: String) -> String? {
        nil
    }

    func exists(key _: String) -> Bool {
        false
    }

    func delete(key _: String) {}
}
