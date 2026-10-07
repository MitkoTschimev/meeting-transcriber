import CryptoKit
import Foundation

/// RFC 7636 S256 PKCE pair for the Google Desktop OAuth client.
struct PKCE: Equatable, Sendable {
    let verifier: String
    let challenge: String

    static func generate(byteCount: Int = 32) -> Self {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            bytes = (0 ..< byteCount).map { _ in UInt8.random(in: 0 ... 255) }
        }
        return fromVerifier(Data(bytes).base64URLEncodedString())
    }

    /// Deterministic constructor for tests that pin the challenge encoding.
    static func fromVerifier(_ verifier: String) -> Self {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Self(verifier: verifier, challenge: Data(hash).base64URLEncodedString())
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
