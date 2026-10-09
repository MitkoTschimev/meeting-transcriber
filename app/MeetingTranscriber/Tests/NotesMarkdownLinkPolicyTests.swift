@testable import MeetingTranscriber
import XCTest

final class NotesMarkdownLinkPolicyTests: XCTestCase {
    func testAllowsHttpAndHttpsWithHost() {
        XCTAssertEqual(decision("https://example.com/notes"), .allow)
        XCTAssertEqual(decision("http://example.com"), .allow)
        XCTAssertEqual(decision("HTTPS://Example.COM/a"), .allow)
        XCTAssertEqual(decision("mailto:alice@example.com"), .allow)
    }

    func testRefusesFileCustomSchemesAndRelativeLinks() {
        XCTAssertEqual(decision("file:///tmp/evil.app"), .refuse)
        XCTAssertEqual(decision("file:///Applications/Safari.app"), .refuse)
        XCTAssertEqual(decision("file:///tmp/run.command"), .refuse)
        XCTAssertEqual(decision("zoommtg://zoom.us/join?confno=1"), .refuse)
        XCTAssertEqual(decision("x-apple.systempreferences:com.apple.preference.security"), .refuse)
        XCTAssertEqual(decision("smb://server/share"), .refuse)
        XCTAssertEqual(decision("ssh://host"), .refuse)
        XCTAssertEqual(decision("vnc://host"), .refuse)
        XCTAssertEqual(decision("javascript:alert(1)"), .refuse)
        XCTAssertEqual(decision("readme"), .refuse)
        XCTAssertEqual(decision("./relative.md"), .refuse)
        XCTAssertEqual(decision("/etc/passwd"), .refuse)
    }

    func testRefusesHttpWithoutHostAndEmptyMailto() {
        XCTAssertEqual(decision("https://"), .refuse)
        XCTAssertEqual(decision("http://"), .refuse)
        XCTAssertEqual(decision("mailto:"), .refuse)
        XCTAssertEqual(decision("mailto:?subject=hi"), .refuse)
    }

    private func decision(_ raw: String) -> NotesMarkdownLinkPolicy.Decision {
        guard let url = URL(string: raw) else { return .refuse }
        return NotesMarkdownLinkPolicy.decision(for: url)
    }
}
