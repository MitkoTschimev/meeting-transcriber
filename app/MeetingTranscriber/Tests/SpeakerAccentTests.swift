@testable import MeetingTranscriber
import XCTest

final class SpeakerAccentTests: XCTestCase {
    func testMeAndMicLabelAreYou() {
        XCTAssertTrue(SpeakerAccent.isYou("Me", micLabel: "Me"))
        XCTAssertTrue(SpeakerAccent.isYou("me", micLabel: "Mitko"))
        XCTAssertTrue(SpeakerAccent.isYou("Mitko", micLabel: "Mitko"))
        XCTAssertFalse(SpeakerAccent.isYou("Kirill", micLabel: "Mitko"))
        XCTAssertFalse(SpeakerAccent.isYou("Remote", micLabel: "Me"))
    }

    func testMicTrackPrefixIsYou() {
        XCTAssertTrue(SpeakerAccent.isYou("M_SPEAKER_0", micLabel: "Me"))
        XCTAssertFalse(SpeakerAccent.isYou("R_SPEAKER_0", micLabel: "Me"))
        XCTAssertFalse(SpeakerAccent.isYou("SPEAKER_0", micLabel: "Me"))
        XCTAssertFalse(SpeakerAccent.isYou("R_Mitko", micLabel: "Mitko"))
        XCTAssertTrue(SpeakerAccent.isYou("M_Mitko", micLabel: "Me"))
    }

    func testSpeakerNumbersAreOneBasedDisplay() {
        XCTAssertEqual(SpeakerAccent.speakerNumber("SPEAKER_0"), 0)
        XCTAssertEqual(SpeakerAccent.speakerNumber("SPEAKER_00"), 0)
        XCTAssertEqual(SpeakerAccent.speakerNumber("SPEAKER_1"), 1)
        XCTAssertNil(SpeakerAccent.speakerNumber("Speaker 1"))
        XCTAssertEqual(SpeakerAccent.pretty("SPEAKER_0"), "Speaker 1")
        XCTAssertEqual(SpeakerAccent.pretty("R_SPEAKER_1"), "Speaker 2")
    }

    func testYouDisplayUsesMicLabelForGenericRaw() {
        XCTAssertEqual(
            SpeakerAccent.displayName("Me", micLabel: "Mitko", isYou: true),
            "Mitko (You)",
        )
        XCTAssertEqual(
            SpeakerAccent.displayName("M_SPEAKER_0", micLabel: "Me", isYou: true),
            "Me (You)",
        )
        XCTAssertEqual(
            SpeakerAccent.displayName("Alex", micLabel: "Me", isYou: false),
            "Alex",
        )
    }

    func testYouIdentityCollapsesAcrossLabels() {
        XCTAssertEqual(
            SpeakerAccent.identityKey("Me", micLabel: "Mitko"),
            SpeakerAccent.youKey,
        )
        XCTAssertEqual(
            SpeakerAccent.identityKey("Mitko", micLabel: "Mitko"),
            SpeakerAccent.youKey,
        )
        XCTAssertNotEqual(
            SpeakerAccent.identityKey("Kirill", micLabel: "Mitko"),
            SpeakerAccent.youKey,
        )
    }

    func testHashedColorIsStableForIdentityKey() {
        XCTAssertEqual(
            SpeakerAccent.hashedColor(for: "alex"),
            SpeakerAccent.hashedColor(for: "alex"),
        )
        XCTAssertNotEqual(
            SpeakerAccent.hashedColor(for: "alex"),
            SpeakerAccent.hashedColor(for: "kirill"),
        )
    }

    func testUnknownKeyUsesHashedColorInsteadOfFirstSpeaker() {
        var palette = SpeakerAccent.Palette()
        palette.register(SpeakerAccent.youKey)
        palette.register("alex")
        XCTAssertEqual(palette.othersIndex(for: "alex"), 0)
        XCTAssertNil(palette.othersIndex(for: "unknown"))
        XCTAssertNotEqual(
            palette.color(forKey: "unknown", isYou: false),
            palette.color(forKey: "alex", isYou: false),
        )
        XCTAssertEqual(
            palette.color(forKey: "unknown", isYou: false),
            SpeakerAccent.hashedColor(for: "unknown"),
        )
    }
}
