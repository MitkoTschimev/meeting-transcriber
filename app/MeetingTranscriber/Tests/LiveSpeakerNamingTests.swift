@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// The naming menu's suggestions and the live transcript wiring.
@MainActor
final class LiveSpeakerNamingTests: XCTestCase {
    private func roster() -> LiveSpeakerRoster {
        var roster = LiveSpeakerRoster()
        _ = roster.resolve(LiveSpeakerSample(embedding: [1, 0, 0], matchedName: nil, duration: 3), channel: .mic, fallbackLabel: "Me")
        _ = roster.resolve(LiveSpeakerSample(embedding: [0, 1, 0], matchedName: "Alice", duration: 3), channel: .app, fallbackLabel: "Remote")
        _ = roster.resolve(LiveSpeakerSample(embedding: [0, 0, 1], matchedName: nil, duration: 3), channel: .app, fallbackLabel: "Remote")
        return roster
    }

    private func naming(saved: [String] = [], onAssign: @escaping @MainActor (Int, String) -> Void = { _, _ in }) -> LiveSpeakerNaming {
        LiveSpeakerNaming(
            speakers: roster().speakers,
            savedVoiceNames: saved,
            speakingNowID: nil,
            micLabel: "Me",
            onAssign: onAssign,
        )
    }

    private func id(of label: String, in naming: LiveSpeakerNaming) throws -> Int {
        try XCTUnwrap(naming.speakers.first { $0.label == label }?.id)
    }

    func testSuggestionsPutSessionNamesBeforeSavedVoicesWithoutDuplicates() throws {
        let naming = naming(saved: ["Bob", "alice", "Carol"])
        let placeholder = try id(of: "Speaker 1", in: naming)
        XCTAssertEqual(naming.suggestions(for: placeholder), ["Alice", "Bob", "Carol"])
    }

    func testMicVoiceOffersThatWasMeFirst() throws {
        let naming = naming(saved: ["Bob"])
        let alice = try id(of: "Alice", in: naming)
        XCTAssertFalse(naming.suggestions(for: alice).contains("Alice"))
        let me = try id(of: "Me", in: naming)
        XCTAssertEqual(naming.suggestions(for: me), ["Bob"])
    }

    func testSuggestionsAreCapped() throws {
        let naming = naming(saved: (1 ... 30).map { "Person \($0)" })
        let placeholder = try id(of: "Speaker 1", in: naming)
        XCTAssertEqual(naming.suggestions(for: placeholder).count, LiveSpeakerNaming.maxSuggestions)
    }

    func testDraftNameIsEmptyForPlaceholders() throws {
        let naming = naming()
        let placeholder = try id(of: "Speaker 1", in: naming)
        let alice = try id(of: "Alice", in: naming)
        XCTAssertEqual(naming.draftName(for: placeholder), "")
        XCTAssertEqual(naming.draftName(for: alice), "Alice")
    }

    func testTranscriptShowsTheNamingMenuOnlyWithNaming() throws {
        let session = MeetingNotesSession()
        session.begin(title: "Sync", appName: "Gather")
        let resolved = session.resolveLiveSpeaker(
            LiveSpeakerSample(embedding: [1, 0, 0], matchedName: nil, duration: 3), channel: .app, fallbackLabel: "Remote",
        )
        session.applyFinalized("Hello", channel: .app, speaker: resolved.label, speakerID: resolved.speakerID)
        let turns = session.turns(micLabel: "Me")
        let naming = LiveSpeakerNaming(
            speakers: session.speakerRoster.speakers,
            savedVoiceNames: [],
            speakingNowID: resolved.speakerID,
            micLabel: "Me",
        ) { _, _ in }

        func pane(_ naming: LiveSpeakerNaming?) -> MeetingNotesTranscriptPane {
            MeetingNotesTranscriptPane(
                turns: turns,
                palette: TranscriptTurn.palette(for: turns, micLabel: "Me"),
                micLabel: "Me",
                startedAt: Date(),
                endedAt: nil,
                liveTranscriptionEnabled: true,
                phase: .recording,
                emptyHint: "Listening",
                naming: naming,
            )
        }

        let named = try pane(naming).inspect()
        XCTAssertNoThrow(try named.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesSpeakerMenu))
        XCTAssertNoThrow(try named.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesSpeakerChips))
        XCTAssertNoThrow(try named.find(text: "Hello"))

        let plain = try pane(nil).inspect()
        XCTAssertThrowsError(try plain.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesSpeakerMenu))
        XCTAssertNoThrow(try plain.find(text: "Speaker 1"))
    }
}
