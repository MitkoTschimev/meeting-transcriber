import MarkdownUI
@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

@MainActor
final class NotesMarkdownViewTests: XCTestCase {
    func testRawHTMLIsShownAsText() throws {
        let view = NotesMarkdownView(markdown: "Hello <script>alert(1)</script> world")
        let body = try view.inspect()
        XCTAssertNoThrow(try body.find(text: "Hello <script>alert(1)</script> world"))
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesMarkdownPreview))
    }

    func testBlockImageProviderIsEmptyView() throws {
        let view = NotesDisabledImageProvider().makeImage(url: URL(string: "https://example.com/a.png"))
        XCTAssertNoThrow(try view.inspect().emptyView())
    }

    func testInlineImageProviderRefusesLoad() async {
        guard let url = URL(string: "https://example.com/a.png") else {
            XCTFail("url")
            return
        }
        do {
            _ = try await NotesDisabledInlineImageProvider().image(with: url, label: "secret")
            XCTFail("inline images must not load")
        } catch is NotesMarkdownImageDisabled {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRemoteImageMarkdownDoesNotRenderAltAsLoadedImage() throws {
        let view = NotesMarkdownView(markdown: "![secret](https://example.com/a.png)\n\nAfter")
        let body = try view.inspect()
        XCTAssertNoThrow(try body.find(text: "After"))
        XCTAssertThrowsError(try body.find(text: "secret"))
    }

    func testMentionSourceStripsHeadingHashes() {
        let content = MarkdownContent("## Action items for Mitko")
        XCTAssertEqual(NotesMarkdownMentionSource.inlineMarkdown(from: content), "Action items for Mitko")
        XCTAssertEqual(
            NotesMarkdownMentionSource.inlineMarkdown(from: MarkdownContent("Ask @Mitko.")),
            "Ask @Mitko.",
        )
    }
}
