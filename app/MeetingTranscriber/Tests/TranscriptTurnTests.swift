@testable import MeetingTranscriber
import XCTest

final class TranscriptTurnTests: XCTestCase {
    func testMergesConsecutiveLinesFromTheSameSpeaker() {
        let lines = [
            LiveCaptionLine(channel: .mic, text: "First.", speaker: "Me"),
            LiveCaptionLine(channel: .mic, text: "Second.", speaker: "Me"),
            LiveCaptionLine(channel: .app, text: "Other.", speaker: "Alex"),
            LiveCaptionLine(channel: .mic, text: "Back.", speaker: "Me"),
        ]
        let turns = TranscriptTurn.build(
            liveLines: lines,
            hypothesisMic: "",
            hypothesisApp: "",
            pipelineTranscript: nil,
            micLabel: "Me",
        )
        XCTAssertEqual(turns.count, 3)
        XCTAssertEqual(turns[0].paragraphs, ["First.", "Second."])
        XCTAssertTrue(turns[0].isYou)
        XCTAssertEqual(turns[1].speakerRaw, "Alex")
        XCTAssertFalse(turns[1].isYou)
        XCTAssertEqual(turns[2].paragraphs, ["Back."])
        XCTAssertTrue(turns[2].isYou)
    }

    func testMicChannelIsYouEvenWhenMatcherNamedTheVoice() {
        let lines = [
            LiveCaptionLine(channel: .mic, text: "Hello.", speaker: "Mitko"),
        ]
        let turns = TranscriptTurn.build(
            liveLines: lines,
            hypothesisMic: "",
            hypothesisApp: "",
            pipelineTranscript: nil,
            micLabel: "Me",
        )
        XCTAssertEqual(turns.count, 1)
        XCTAssertTrue(turns[0].isYou)
        XCTAssertEqual(
            SpeakerAccent.displayName(turns[0].speakerRaw, micLabel: "Me", isYou: true),
            "Mitko (You)",
        )
    }

    func testParsesPipelineFormattedLines() {
        let text = """
        Echo note

        [00:00] Me: Hello there.
        [00:04] Me: Still me.
        [00:12] SPEAKER_0: Remote side.
        [00:20] unlabeled words
        """
        let turns = TranscriptTurn.parsePipeline(text, micLabel: "Me")
        XCTAssertEqual(turns.count, 4)
        XCTAssertEqual(turns[0].speakerRaw, "")
        XCTAssertEqual(turns[0].paragraphs, ["Echo note"])
        XCTAssertEqual(turns[1].paragraphs, ["Hello there.", "Still me."])
        XCTAssertTrue(turns[1].isYou)
        XCTAssertEqual(turns[2].speakerRaw, "SPEAKER_0")
        XCTAssertFalse(turns[2].isYou)
        XCTAssertEqual(SpeakerAccent.pretty(turns[2].speakerRaw), "Speaker 1")
        XCTAssertEqual(turns[3].paragraphs, ["unlabeled words"])
    }

    func testPipelineTranscriptWinsOverLiveLines() {
        let lines = [
            LiveCaptionLine(channel: .mic, text: "live", speaker: "Me"),
        ]
        let turns = TranscriptTurn.build(
            liveLines: lines,
            hypothesisMic: "",
            hypothesisApp: "",
            pipelineTranscript: "[00:00] Alex: from file",
            micLabel: "Me",
        )
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].speakerRaw, "Alex")
        XCTAssertEqual(turns[0].paragraphs, ["from file"])
    }

    func testChromeFormatsSpeakerCountAndClock() {
        XCTAssertEqual(TranscriptTurn.chrome(speakerCount: 1, duration: 0), "1 SPEAKER")
        XCTAssertEqual(TranscriptTurn.chrome(speakerCount: 2, duration: 871), "2 SPEAKERS · 14:31")
        XCTAssertEqual(formattedClockDuration(3661), "1:01:01")
    }

    func testPaletteKeepsFirstSeenOrderAcrossLiveToPipelineHandoff() {
        let live = TranscriptTurn.build(
            liveLines: [
                LiveCaptionLine(channel: .mic, text: "a", speaker: "Me"),
                LiveCaptionLine(channel: .app, text: "b", speaker: "Alex"),
            ],
            hypothesisMic: "",
            hypothesisApp: "",
            pipelineTranscript: nil,
            micLabel: "Me",
        )
        let seeded = TranscriptTurn.palette(for: live, micLabel: "Me")
        XCTAssertEqual(seeded.order, [SpeakerAccent.youKey, "alex"])

        let pipeline = TranscriptTurn.build(
            liveLines: [],
            hypothesisMic: "",
            hypothesisApp: "",
            pipelineTranscript: """
            [00:00] Alex: from file
            [00:04] Me: later
            """,
            micLabel: "Me",
        )
        let handedOff = TranscriptTurn.palette(for: pipeline, micLabel: "Me", existing: seeded)
        XCTAssertEqual(handedOff.order, seeded.order)
        XCTAssertEqual(
            handedOff.othersIndex(for: "alex"),
            seeded.othersIndex(for: "alex"),
        )
    }
}
