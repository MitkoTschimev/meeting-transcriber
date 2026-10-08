@testable import MeetingTranscriber
import XCTest

final class ProtocolNotesFailureTests: XCTestCase {
    func testStripsFullTranscriptAppendix() {
        let markdown = """
        chat completion failed

        ---

        ## Full Transcript

        [00:27] Mitko: Hey
        """
        XCTAssertEqual(ProtocolNotesFailure.notesBody(from: markdown), "chat completion failed")
    }

    func testDetectsSavedChatCompletionFailedWithTranscript() {
        let markdown = """
        chat completion failed
        ---
        ## Full Transcript

        [00:27] Mitko: Hey Ähm, hast du das in Google Meetup oder hier?
        """
        XCTAssertEqual(
            ProtocolNotesFailure.detectingSavedContent(markdown),
            .chatCompletionFailed,
        )
    }

    func testDetectsBareChatCompletionFailed() {
        XCTAssertEqual(
            ProtocolNotesFailure.detectingSavedContent("chat completion failed"),
            .chatCompletionFailed,
        )
    }

    func testRealNotesAreNotFailures() {
        let notes = """
        # Gather Tray Menu
        **Date:** 2026-10-08

        ---

        The team discussed the tray menu. We will retry failed summaries.

        ## Action items
        - Mitko: ship retry

        ---

        ## Full Transcript

        [00:27] Mitko: timeout on the old model
        """
        XCTAssertNil(ProtocolNotesFailure.detectingSavedContent(notes))
    }

    func testShortLegitimateNotesMentioningTimeoutAreNotFailures() {
        XCTAssertNil(
            ProtocolNotesFailure.detectingSavedContent("We discussed the timeout."),
        )
    }

    func testEmptyNotesBodyIsEmptyFailure() {
        XCTAssertEqual(ProtocolNotesFailure.detectingSavedContent("   \n"), .empty)
    }

    func testClassifiesThrownErrors() {
        XCTAssertEqual(ProtocolNotesFailure.classifying(ProtocolError.generationTimedOut(30)), .timedOut)
        XCTAssertEqual(ProtocolNotesFailure.classifying(ProtocolError.protocolTruncated), .truncated)
        XCTAssertEqual(ProtocolNotesFailure.classifying(ProtocolError.emptyProtocol), .empty)
        XCTAssertEqual(
            ProtocolNotesFailure.classifying(ProtocolError.httpError(401, "invalid_api_key")),
            .unauthorized,
        )
        XCTAssertEqual(
            ProtocolNotesFailure.classifying(ProtocolError.httpError(404, "model_not_found")),
            .modelUnavailable,
        )
        XCTAssertEqual(
            ProtocolNotesFailure.classifying(ProtocolError.httpError(400, "maximum context length exceeded")),
            .contextTooLong,
        )
        XCTAssertEqual(
            ProtocolNotesFailure.classifying(ProtocolError.httpError(500, "chat completion failed")),
            .chatCompletionFailed,
        )
        XCTAssertEqual(
            ProtocolNotesFailure.classifying(ProtocolError.httpError(502, "upstream")),
            .httpStatus(502),
        )
        XCTAssertEqual(
            ProtocolNotesFailure.classifying(ProtocolError.connectionFailed("The request timed out.")),
            .timedOut,
        )
        XCTAssertEqual(
            ProtocolNotesFailure.classifying(ProtocolError.connectionFailed("offline")),
            .connection,
        )
    }

    func testDetectsLegacyAndNewWarnings() {
        XCTAssertEqual(
            ProtocolNotesFailure.detecting(warnings: ["Protocol generation failed — transcript saved"]),
            .unknown,
        )
        XCTAssertEqual(
            ProtocolNotesFailure.detecting(
                warnings: ["Notes could not be generated (timeout). The transcript was saved."],
            ),
            .timedOut,
        )
        XCTAssertNil(
            ProtocolNotesFailure.detecting(warnings: ["Protocol generation skipped"]),
        )
    }

    func testUserMessageIncludesShortReason() {
        XCTAssertEqual(
            ProtocolNotesFailure.chatCompletionFailed.userMessage,
            "Notes could not be generated (chat completion failed). The transcript was saved.",
        )
        XCTAssertTrue(ProtocolNotesFailure.chatCompletionFailed.suggestsContextPressure)
        XCTAssertFalse(ProtocolNotesFailure.unauthorized.suggestsContextPressure)
    }
}
