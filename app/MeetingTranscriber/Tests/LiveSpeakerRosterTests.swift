@testable import MeetingTranscriber
import XCTest

/// Session-local voice clustering, profile carry-over and user naming for
/// the live transcript.
final class LiveSpeakerRosterTests: XCTestCase {
    private let alice: [Float] = [1, 0, 0, 0]
    private let aliceAgain: [Float] = [0.95, 0.08, 0.02, 0]
    private let bob: [Float] = [0, 1, 0, 0]
    private let carol: [Float] = [0, 0, 1, 0]

    private func sample(_ embedding: [Float], matched: String? = nil, duration: TimeInterval = 3) -> LiveSpeakerSample {
        LiveSpeakerSample(embedding: embedding, matchedName: matched, duration: duration)
    }

    // MARK: - Clustering

    func testFirstMicVoiceIsTheLocalUser() {
        var roster = LiveSpeakerRoster()
        let first = roster.resolve(sample(alice), channel: .mic, fallbackLabel: "Me")
        XCTAssertEqual(first.label, "Me")
        XCTAssertEqual(roster.speaker(id: first.speakerID ?? -1)?.isYou, true)
        XCTAssertTrue(roster.notYouSpeakerIDs.isEmpty)
    }

    func testSameVoiceJoinsAndANewVoiceGetsTheNextNumber() {
        var roster = LiveSpeakerRoster()
        let first = roster.resolve(sample(alice), channel: .app, fallbackLabel: "Remote")
        let again = roster.resolve(sample(aliceAgain), channel: .app, fallbackLabel: "Remote")
        let other = roster.resolve(sample(bob), channel: .app, fallbackLabel: "Remote")

        XCTAssertEqual(first.label, "Speaker 1")
        XCTAssertEqual(again.speakerID, first.speakerID)
        XCTAssertEqual(other.label, "Speaker 2")
        XCTAssertNotEqual(other.speakerID, first.speakerID)
        XCTAssertEqual(roster.speaker(id: first.speakerID ?? -1)?.centroidSampleCount, 2)
    }

    func testChannelsNeverShareAVoice() {
        var roster = LiveSpeakerRoster()
        let mic = roster.resolve(sample(alice), channel: .mic, fallbackLabel: "Me")
        let app = roster.resolve(sample(alice), channel: .app, fallbackLabel: "Remote")
        XCTAssertNotEqual(mic.speakerID, app.speakerID)
        XCTAssertEqual(app.label, "Speaker 1", "the mic default does not use up a number")
    }

    func testShortUtteranceJoinsTheClosestVoiceInsteadOfFoundingOne() {
        var roster = LiveSpeakerRoster()
        let first = roster.resolve(sample(alice), channel: .app, fallbackLabel: "Remote")
        let short = roster.resolve(sample(bob, duration: 0.4), channel: .app, fallbackLabel: "Remote")
        XCTAssertEqual(short.speakerID, first.speakerID)
        XCTAssertEqual(roster.speakers.count, 1)
        XCTAssertEqual(roster.speaker(id: first.speakerID ?? -1)?.centroid, alice, "a short sample must not move the centroid")
    }

    func testNoEmbeddingFallsBackToTheMatchOrChannelLabel() {
        var roster = LiveSpeakerRoster()
        XCTAssertEqual(
            roster.resolve(nil, channel: .app, fallbackLabel: "Remote"),
            .init(speakerID: nil, label: "Remote"),
        )
        XCTAssertEqual(
            roster.resolve(sample([], matched: "Alice"), channel: .app, fallbackLabel: "Remote"),
            .init(speakerID: nil, label: "Alice"),
        )
        XCTAssertTrue(roster.speakers.isEmpty)
    }

    func testChannelVoiceCapAbsorbsInsteadOfFounding() {
        var roster = LiveSpeakerRoster()
        for index in 0 ..< LiveSpeakerRoster.maxSpeakersPerChannel {
            var vector = [Float](repeating: 0, count: 16)
            vector[index] = 1
            _ = roster.resolve(sample(vector), channel: .app, fallbackLabel: "Remote")
        }
        var extra = [Float](repeating: 0, count: 16)
        extra[15] = 1
        let overflow = roster.resolve(sample(extra), channel: .app, fallbackLabel: "Remote")
        XCTAssertEqual(roster.speakers.count, LiveSpeakerRoster.maxSpeakersPerChannel)
        XCTAssertNotNil(overflow.speakerID)
    }

    // MARK: - Saved profiles

    func testProfileMatchRelabelsAnUnnamedVoice() {
        var roster = LiveSpeakerRoster()
        let first = roster.resolve(sample(alice), channel: .app, fallbackLabel: "Remote")
        let matched = roster.resolve(sample(aliceAgain, matched: "Alice"), channel: .app, fallbackLabel: "Remote")

        XCTAssertEqual(matched.speakerID, first.speakerID)
        XCTAssertEqual(matched.label, "Alice")
        XCTAssertEqual(matched.relabeledSpeakerID, first.speakerID, "earlier lines must follow the new name")
        XCTAssertEqual(roster.speaker(id: first.speakerID ?? -1)?.source, .profile)
    }

    func testProfileMatchJoinsTheVoiceAlreadyCarryingThatName() {
        var roster = LiveSpeakerRoster()
        let first = roster.resolve(sample(alice, matched: "Alice"), channel: .app, fallbackLabel: "Remote")
        // An off-centre sample the matcher still recognises.
        let later = roster.resolve(sample(carol, matched: "Alice"), channel: .app, fallbackLabel: "Remote")
        XCTAssertEqual(later.speakerID, first.speakerID)
        XCTAssertNil(later.relabeledSpeakerID)
    }

    func testUserNameWinsOverAConflictingProfileMatch() {
        var roster = LiveSpeakerRoster()
        let first = roster.resolve(sample(alice), channel: .app, fallbackLabel: "Remote")
        _ = roster.rename(id: first.speakerID ?? -1, to: "Bob", micLabel: "Me")
        let later = roster.resolve(sample(aliceAgain, matched: "Alice"), channel: .app, fallbackLabel: "Remote")
        XCTAssertEqual(later.label, "Bob")
        XCTAssertEqual(later.speakerID, first.speakerID)
    }

    // MARK: - Naming

    func testRenameProducesAnEnrollmentFromTheVoiceCentroid() throws {
        var roster = LiveSpeakerRoster()
        let first = roster.resolve(sample(alice, duration: 2), channel: .app, fallbackLabel: "Remote")
        _ = roster.resolve(sample(alice, duration: 4), channel: .app, fallbackLabel: "Remote")

        let outcome = try XCTUnwrap(roster.rename(id: first.speakerID ?? -1, to: "  Alice  ", micLabel: "Me"))
        XCTAssertEqual(outcome.label, "Alice")
        XCTAssertEqual(outcome.affectedIDs, [first.speakerID ?? -1])
        XCTAssertEqual(outcome.enrollment, VoiceEnrollment(name: "Alice", embedding: alice, speakingTime: 6))
        XCTAssertEqual(roster.speaker(id: first.speakerID ?? -1)?.source, .user)
    }

    func testGenericNamesAreNotEnrolled() {
        var roster = LiveSpeakerRoster()
        let first = roster.resolve(sample(alice), channel: .mic, fallbackLabel: "Me")
        let outcome = roster.rename(id: first.speakerID ?? -1, to: "mitko", micLabel: "Mitko")
        XCTAssertNil(outcome?.enrollment, "the user's own mic label is a role, not a saved voice")
        XCTAssertEqual(roster.speaker(id: first.speakerID ?? -1)?.isYou, true)
    }

    func testNamingAMicVoiceAsSomeoneElseStopsItBeingYou() {
        var roster = LiveSpeakerRoster()
        let first = roster.resolve(sample(alice), channel: .mic, fallbackLabel: "Me")
        _ = roster.rename(id: first.speakerID ?? -1, to: "Anna", micLabel: "Me")
        XCTAssertEqual(roster.notYouSpeakerIDs, [first.speakerID ?? -1])
    }

    func testRenamingToAnotherSessionVoiceMergesThem() throws {
        var roster = LiveSpeakerRoster()
        let alicesVoice = roster.resolve(sample(alice, matched: "Alice"), channel: .app, fallbackLabel: "Remote")
        let split = roster.resolve(sample(bob), channel: .app, fallbackLabel: "Remote")

        let outcome = try XCTUnwrap(roster.rename(id: split.speakerID ?? -1, to: "Alice", micLabel: "Me"))
        XCTAssertEqual(outcome.speakerID, alicesVoice.speakerID)
        XCTAssertEqual(Set(outcome.affectedIDs), Set([split.speakerID ?? -1, alicesVoice.speakerID ?? -1]))
        XCTAssertEqual(roster.speakers.count, 1)
        XCTAssertNil(roster.speaker(id: split.speakerID ?? -1))
        XCTAssertEqual(roster.speaker(id: alicesVoice.speakerID ?? -1)?.speakingTime, 6)
    }

    func testRenameRejectsBlankNamesAndUnknownIDs() {
        var roster = LiveSpeakerRoster()
        let first = roster.resolve(sample(alice), channel: .app, fallbackLabel: "Remote")
        XCTAssertNil(roster.rename(id: first.speakerID ?? -1, to: "   ", micLabel: "Me"))
        XCTAssertNil(roster.rename(id: 999, to: "Alice", micLabel: "Me"))
    }
}
