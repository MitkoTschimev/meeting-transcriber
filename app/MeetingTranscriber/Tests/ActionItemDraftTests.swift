@testable import MeetingTranscriber
import XCTest

final class ActionItemDraftTests: XCTestCase {
    func testExtractsEnglishCommitments() {
        let lines = [
            LiveCaptionLine(channel: .mic, text: "I'll send the deck tomorrow.", speaker: "Me"),
            LiveCaptionLine(channel: .app, text: "The weather is nice.", speaker: "Remote"),
            LiveCaptionLine(channel: .app, text: "Can you open the PR today?", speaker: "Alex"),
        ]
        let items = ActionItemDraft.items(from: lines)
        XCTAssertEqual(items, [
            "Me: I'll send the deck tomorrow.",
            "Alex: Can you open the PR today?",
        ])
    }

    func testExtractsGermanCommitments() {
        let lines = [
            LiveCaptionLine(channel: .mic, text: "Ich werde das Ticket anlegen.", speaker: "Me"),
            LiveCaptionLine(channel: .app, text: "Guten Morgen zusammen.", speaker: "Remote"),
        ]
        XCTAssertEqual(
            ActionItemDraft.items(from: lines),
            ["Me: Ich werde das Ticket anlegen."],
        )
    }

    func testIgnoresEmptyAndUnrelatedLines() {
        let lines = [
            LiveCaptionLine(channel: .mic, text: "   ", speaker: "Me"),
            LiveCaptionLine(channel: .app, text: "Sure, that sounds fine.", speaker: "Remote"),
        ]
        XCTAssertTrue(ActionItemDraft.items(from: lines).isEmpty)
    }

    func testPleaseAndBitteMatchWithTrailingPunctuation() {
        XCTAssertTrue(ActionItemDraft.matches("please, send the file"))
        XCTAssertTrue(ActionItemDraft.matches("Bitte. Öffne das Ticket."))
        XCTAssertFalse(ActionItemDraft.matches("skill issue"))
        XCTAssertFalse(ActionItemDraft.matches("sicher"))
    }
}
