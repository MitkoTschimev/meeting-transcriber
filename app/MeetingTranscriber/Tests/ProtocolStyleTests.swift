@testable import MeetingTranscriber
import XCTest

final class ProtocolStyleTests: XCTestCase {
    func testPreferredDefaultIsActionItems() {
        XCTAssertEqual(ProtocolStyle.preferred, .actionItems)
        XCTAssertEqual(ProtocolStyle.preferred.rawValue, "action_items")
    }

    func testAllCasesHaveDistinctPrompts() {
        let prompts = ProtocolStyle.allCases.map(\.prompt)
        XCTAssertEqual(Set(prompts).count, ProtocolStyle.allCases.count)
    }

    func testActionItemsPromptAsksForActionTable() {
        let prompt = ProtocolStyle.actionItems.prompt
        XCTAssertTrue(prompt.contains("## Action items"))
        XCTAssertTrue(prompt.contains("{LANGUAGE}"))
        XCTAssertTrue(prompt.contains("{MEETING_DATE}"))
        XCTAssertTrue(prompt.hasSuffix("Transcript:\n") || prompt.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("Transcript:"))
    }

    func testMeetingProtocolPromptIsTheLegacyBuiltIn() {
        XCTAssertEqual(ProtocolStyle.meetingProtocol.prompt, ProtocolGenerator.protocolPrompt)
    }

    func testBriefPromptAsksForShortWriteUp() {
        let prompt = ProtocolStyle.brief.prompt
        XCTAssertTrue(prompt.contains("two-minute read"))
        XCTAssertTrue(prompt.contains("## Action items"))
    }

    func testProgressCaptionsAreReadable() {
        XCTAssertEqual(ProtocolStyle.actionItems.progressCaption, "action items")
        XCTAssertEqual(ProtocolStyle.meetingProtocol.progressCaption, "a meeting protocol")
        XCTAssertEqual(ProtocolStyle.brief.progressCaption, "a two-minute read")
    }
}
