@testable import MeetingTranscriber
import XCTest

final class NotesMarkdownSplitTests: XCTestCase {
    func testNotesWithoutAppendixStayIntact() {
        let markdown = """
        # Planning
        **Date:** 2026-10-08

        ## Action items
        - Ship the renderer
        """
        let split = NotesMarkdownSplit.parse(markdown)
        XCTAssertEqual(split.notes, markdown)
        XCTAssertNil(split.transcript)
    }

    func testSplitsNotesFromFullTranscriptAppendix() {
        let markdown = """
        # Gather Tray Menu
        **Date:** 2026-10-08

        ---

        The team discussed the tray menu.

        ## Action items
        - Mitko: ship retry

        ---

        ## Full Transcript

        [00:27] Mitko: Hey
        [00:32] Alex: Let's retry failed summaries.
        """
        let split = NotesMarkdownSplit.parse(markdown)
        XCTAssertTrue(split.notes.contains("# Gather Tray Menu"))
        XCTAssertTrue(split.notes.contains("The team discussed the tray menu."))
        XCTAssertFalse(split.notes.contains("## Full Transcript"))
        XCTAssertFalse(split.notes.hasSuffix("---"))
        XCTAssertEqual(
            split.transcript,
            "[00:27] Mitko: Hey\n[00:32] Alex: Let's retry failed summaries.",
        )
    }

    func testEmptyAppendixIsOmitted() {
        let markdown = """
        # Notes

        Hello

        ## Full Transcript

        """
        let split = NotesMarkdownSplit.parse(markdown)
        XCTAssertEqual(split.notes, "# Notes\n\nHello")
        XCTAssertNil(split.transcript)
    }
}
