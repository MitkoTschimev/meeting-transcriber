@testable import MeetingTranscriber
import XCTest

final class MeetingLinkExtractorTests: XCTestCase {
    func testZoomURLFromNotes() {
        let url = MeetingLinkExtractor.url(from: [
            "Conference room 4",
            "Join: https://acme.zoom.us/j/123456789?pwd=abc",
        ])
        XCTAssertEqual(url?.host, "acme.zoom.us")
    }

    func testGoogleMeetPreferredOverGenericHTTPS() {
        let url = MeetingLinkExtractor.url(from: [
            "https://wiki.example.com/notes",
            "https://meet.google.com/abc-defg-hij",
        ])
        XCTAssertEqual(url?.host, "meet.google.com")
    }

    func testTeamsAndWebex() {
        XCTAssertEqual(
            MeetingLinkExtractor.firstURL(in: "https://teams.microsoft.com/l/meetup-join/19%3ameeting")?.host,
            "teams.microsoft.com",
        )
        XCTAssertEqual(
            MeetingLinkExtractor.firstURL(in: "https://acme.webex.com/meet/jane")?.host,
            "acme.webex.com",
        )
    }

    func testExplicitHTTPURLWinsWhenJoinable() throws {
        let explicit = try XCTUnwrap(URL(string: "https://meet.google.com/xyz"))
        XCTAssertEqual(
            MeetingLinkExtractor.url(from: ["https://example.com"], explicit: explicit),
            explicit,
        )
    }

    func testRejectsNonHTTP() {
        XCTAssertNil(MeetingLinkExtractor.url(from: [], explicit: URL(string: "webcal://calendar.google.com")))
        XCTAssertNil(MeetingLinkExtractor.firstURL(in: "No link here"))
    }
}
