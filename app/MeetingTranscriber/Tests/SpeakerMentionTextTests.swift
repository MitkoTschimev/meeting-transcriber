@testable import MeetingTranscriber
import SwiftUI
import XCTest

final class SpeakerMentionTextTests: XCTestCase {
    func testInlineMentionDoesNotTintNameInsideLongerWord() {
        var attributed = AttributedString("Annual review with Ann")
        SpeakerMentionText.applyMentions(
            &attributed,
            mentions: [SpeakerMentionText.Mention(names: ["Ann"], color: .red)],
        )

        XCTAssertNil(foregroundColor(of: "Annual", in: attributed))
        XCTAssertNotNil(foregroundColor(of: "Ann", in: attributed, options: .backwards))
    }

    func testLongestNameWinsOverShorterPrefix() {
        var attributed = AttributedString("Talk to Annabelle and Ann")
        SpeakerMentionText.applyMentions(
            &attributed,
            mentions: [
                SpeakerMentionText.Mention(names: ["Ann", "Annabelle"], color: .blue),
            ],
        )

        XCTAssertNotNil(foregroundColor(of: "Annabelle", in: attributed))
        XCTAssertNotNil(foregroundColor(of: "Ann", in: attributed, options: .backwards))
    }

    private func foregroundColor(
        of snippet: String,
        in attributed: AttributedString,
        options: String.CompareOptions = [],
    ) -> Color? {
        let plain = String(attributed.characters)
        guard let stringRange = plain.range(of: snippet, options: options),
              let attrRange = Range(stringRange, in: attributed) else { return nil }
        return attributed[attrRange].foregroundColor
    }
}
