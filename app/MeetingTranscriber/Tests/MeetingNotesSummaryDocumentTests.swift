@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

@MainActor
final class MeetingNotesSummaryDocumentTests: XCTestCase {
    func testPreviewRendersHeadingAndListWithoutMarkup() throws {
        let view = MeetingNotesSummaryDocument(
            markdown: """
            # Ship the notes window

            ## Action items
            - [ ] Review the PR
            """,
        )
        let body = try view.inspect()
        XCTAssertNoThrow(try body.find(text: "Ship the notes window"))
        XCTAssertNoThrow(try body.find(text: "Action items"))
        XCTAssertNoThrow(try body.find(text: "Review the PR"))
        XCTAssertThrowsError(try body.find(text: "# Ship the notes window"))
        XCTAssertThrowsError(try body.find(text: "## Action items"))
        XCTAssertThrowsError(try body.find(text: "- [ ] Review the PR"))
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesMarkdownPreview))
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesDisplayMode))
    }

    func testSourceShowsRawMarkdown() throws {
        let markdown = """
        # Ship the notes window

        - [ ] Review the PR
        """
        let view = MeetingNotesSummaryDocument(markdown: markdown, initialMode: .source)
        let body = try view.inspect()
        XCTAssertNoThrow(try body.find(text: markdown))
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesMarkdownSource))
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesMarkdownPreview))
    }

    func testDisplayModePickerIsSelectable() throws {
        let view = MeetingNotesSummaryDocument(markdown: "# Title")
        let picker = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.meetingNotesDisplayMode)
            .find(ViewType.Picker.self)
        XCTAssertEqual(try picker.labelView().text().string(), "Notes display")
        XCTAssertNoThrow(try picker.select(value: NotesMarkdownMode.source))
    }

    func testFullTranscriptStartsCollapsed() throws {
        let view = MeetingNotesSummaryDocument(markdown: Self.notesWithTranscript)
        let body = try view.inspect()
        XCTAssertNoThrow(try body.find(text: "Hello"))
        XCTAssertNoThrow(
            try body.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesFullTranscriptDisclosure),
        )
        XCTAssertThrowsError(try body.find(text: "[00:27] Mitko: Hey"))
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesFullTranscript))
    }

    func testExpandedTranscriptShowsLazyLines() throws {
        let view = MeetingNotesSummaryDocument(
            markdown: Self.notesWithTranscript,
            transcriptExpanded: true,
        )
        let body = try view.inspect()
        XCTAssertNoThrow(try body.find(text: "[00:27] Mitko: Hey"))
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesFullTranscript))
        XCTAssertEqual(
            NotesTranscriptAppendix.rows(from: "[00:27] Mitko: Hey\n\n[00:32] Alex: Hi").count,
            3,
        )
    }

    func testCopyTranscriptButtonCopiesCollapsedAppendix() throws {
        let box = CopyBox()
        let view = MeetingNotesSummaryDocument(markdown: Self.notesWithTranscript) { box.text = $0 }
        let body = try view.inspect()
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesCopyTranscript))
        try body.find(button: "Copy transcript").tap()
        XCTAssertEqual(box.text, "[00:27] Mitko: Hey")
        XCTAssertThrowsError(try body.find(text: "[00:27] Mitko: Hey"))
    }

    func testPreviewKeepsAssigneeMentions() throws {
        let view = MeetingNotesSummaryDocument(
            markdown: "Ask @Mitko to ship it.",
            mentions: [SpeakerMentionText.Mention(names: ["Mitko"], color: .red)],
        )
        let body = try view.inspect()
        XCTAssertNoThrow(try body.find(text: "Ask @Mitko to ship it."))
        var attributed = AttributedString("Ask @Mitko to ship it.")
        SpeakerMentionText.applyMentions(
            &attributed,
            mentions: [SpeakerMentionText.Mention(names: ["Mitko"], color: .red)],
        )
        XCTAssertNotNil(Self.backgroundColor(of: "@Mitko", in: attributed))
    }

    func testRetryUIAndDocumentAreBothFindable() throws {
        let stack = VStack {
            MeetingNotesSummaryFailure(
                message: "Notes could not be generated (timeout). The transcript was saved.",
                hint: nil,
                retryEnabled: true,
            ) {}
            MeetingNotesSummaryDocument(markdown: "# Hello")
        }
        let body = try stack.inspect()
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesSummaryError))
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesRetryButton))
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesMarkdownPreview))
        XCTAssertNoThrow(try body.find(text: "Hello"))
    }

    func testPreviewStripsInlineMarkers() throws {
        let view = MeetingNotesSummaryDocument(
            markdown: "Use **bold** and `code` and *italic*.",
        )
        let body = try view.inspect()
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesMarkdownPreview))
        XCTAssertThrowsError(try body.find(text: "Use **bold** and `code` and *italic*."))
    }

    private static func backgroundColor(of snippet: String, in attributed: AttributedString) -> Color? {
        let plain = String(attributed.characters)
        guard let stringRange = plain.range(of: snippet),
              let attrRange = Range(stringRange, in: attributed) else { return nil }
        return attributed[attrRange].backgroundColor
    }

    private static let notesWithTranscript = """
    # Notes

    Hello

    ---

    ## Full Transcript

    [00:27] Mitko: Hey
    """
}

private final class CopyBox {
    var text: String?
}
