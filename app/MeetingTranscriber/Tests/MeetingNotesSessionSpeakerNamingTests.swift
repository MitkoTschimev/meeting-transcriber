@testable import MeetingTranscriber
import XCTest

/// In-memory stand-in for `speakers.json`.
@MainActor
private final class FakeVoiceProfileStore: VoiceProfileStoring {
    var names: [String]
    private(set) var enrolled: [VoiceEnrollment] = []
    private(set) var renames: [(from: String, to: String)] = []

    init(names: [String] = []) {
        self.names = names
    }

    func savedVoiceNames() -> [String] {
        names
    }

    func enroll(_ enrollment: VoiceEnrollment) {
        enrolled.append(enrollment)
        if !names.contains(enrollment.name) { names.insert(enrollment.name, at: 0) }
    }

    func renameProfile(from: String, to: String) {
        guard from != to else { return }
        renames.append((from, to))
        names.removeAll { $0 == from }
        if !names.contains(to) { names.insert(to, at: 0) }
    }
}

/// Naming speakers on the fly in the live transcript.
@MainActor
final class MeetingNotesSessionSpeakerNamingTests: XCTestCase {
    private let alice: [Float] = [1, 0, 0, 0]
    private let bob: [Float] = [0, 1, 0, 0]
    private let carol: [Float] = [0, 0, 1, 0]

    private func sample(_ embedding: [Float], matched: String? = nil) -> LiveSpeakerSample {
        LiveSpeakerSample(embedding: embedding, matchedName: matched, duration: 4)
    }

    /// Mirror of `LiveTranscriptionController`: resolve, then append.
    @discardableResult
    private func hear(
        _ text: String,
        _ embedding: [Float],
        in session: MeetingNotesSession,
        channel: LiveCaptionChannel = .app,
        matched: String? = nil,
    ) -> LiveSpeakerRoster.Resolution {
        let fallback = channel == .mic ? "Me" : "Remote"
        let resolved = session.resolveLiveSpeaker(sample(embedding, matched: matched), channel: channel, fallbackLabel: fallback)
        session.applyFinalized(text, channel: channel, speaker: resolved.label, speakerID: resolved.speakerID)
        return resolved
    }

    func testRenameRelabelsEveryLineOfThatVoiceAndLaterLines() throws {
        let session = MeetingNotesSession()
        session.begin(title: "Sync", appName: "Gather")
        let first = hear("Hi all", alice, in: session)
        hear("Hello", bob, in: session)
        hear("Shall we start?", alice, in: session)
        let id = try XCTUnwrap(first.speakerID)

        session.renameLiveSpeaker(id: id, to: "Alice")

        XCTAssertEqual(session.lines.map(\.speaker), ["Alice", "Speaker 2", "Alice"])
        XCTAssertEqual(hear("Next item", alice, in: session).label, "Alice")
        XCTAssertTrue(session.turns(micLabel: "Me").contains { $0.speakerRaw == "Alice" })
    }

    func testNamingAfterAnotherVoiceMergesThem() throws {
        let session = MeetingNotesSession()
        session.begin(title: "Sync", appName: "Gather")
        let one = try XCTUnwrap(hear("One", alice, in: session).speakerID)
        let two = try XCTUnwrap(hear("Two", carol, in: session).speakerID)
        session.renameLiveSpeaker(id: one, to: "Alice")

        session.renameLiveSpeaker(id: two, to: "Alice")

        XCTAssertEqual(session.lines.map(\.speaker), ["Alice", "Alice"])
        XCTAssertEqual(Set(session.lines.compactMap(\.speakerID)).count, 1)
        XCTAssertEqual(session.speakerRoster.speakers.count { $0.channel == .app }, 1)
    }

    func testNamingSavesTheVoiceProfileOnceTheRecordingFinishes() throws {
        let store = FakeVoiceProfileStore(names: ["Dana"])
        let session = MeetingNotesSession(voiceProfiles: store)
        session.begin(title: "Sync", appName: "Gather")
        let id = try XCTUnwrap(hear("Hi", alice, in: session).speakerID)

        session.renameLiveSpeaker(id: id, to: "  Alice ")
        XCTAssertTrue(store.enrolled.isEmpty, "a live typo must not hit speakers.json yet")
        XCTAssertEqual(session.savedVoiceNames, ["Dana"])

        session.finishRecording()
        XCTAssertEqual(store.enrolled.map(\.name), ["Alice"], "names known at Stop must be in speakers.json for the pipeline")
        XCTAssertEqual(store.enrolled.first?.embedding, alice)
        XCTAssertEqual(session.savedVoiceNames, ["Alice", "Dana"])

        session.retireLiveRoster()
        XCTAssertEqual(store.enrolled.map(\.name), ["Alice"], "retire must not enroll a second copy")
        XCTAssertTrue(store.renames.isEmpty)
    }

    func testCorrectingANameEnrollsOnlyTheFinalOne() throws {
        let store = FakeVoiceProfileStore()
        let session = MeetingNotesSession(voiceProfiles: store)
        session.begin(title: "Sync", appName: "Gather")
        let id = try XCTUnwrap(hear("Hi", alice, in: session).speakerID)

        session.renameLiveSpeaker(id: id, to: "Aice")
        session.renameLiveSpeaker(id: id, to: "Bob")
        session.finishRecording()
        XCTAssertEqual(store.enrolled.map(\.name), ["Bob"], "a pre-Stop correction enrolls only the final name")
        session.retireLiveRoster()

        XCTAssertEqual(store.enrolled.map(\.name), ["Bob"])
        XCTAssertTrue(store.renames.isEmpty)
        XCTAssertEqual(session.lines.map(\.speaker), ["Bob"])
    }

    /// The live transcript stays nameable after Stop until a pipeline
    /// transcript replaces it. A name given then must still be enrolled,
    /// and a correction then must not leave the typo in speakers.json.
    func testNamingAfterStopEnrollsTheFinalName() throws {
        let store = FakeVoiceProfileStore()
        let session = MeetingNotesSession(voiceProfiles: store)
        session.begin(title: "Sync", appName: "Gather")
        let id = try XCTUnwrap(hear("Hi", alice, in: session).speakerID)

        session.renameLiveSpeaker(id: id, to: "Aice")
        session.finishRecording()
        XCTAssertTrue(session.canNameLiveSpeakers, "the live transcript is still on screen")
        XCTAssertEqual(store.enrolled.map(\.name), ["Aice"])

        session.renameLiveSpeaker(id: id, to: "Bob")
        session.retireLiveRoster()

        XCTAssertEqual(store.enrolled.map(\.name), ["Aice"], "the stored profile is renamed, not enrolled twice")
        XCTAssertEqual(store.renames.map { "\($0.from)->\($0.to)" }, ["Aice->Bob"])
        XCTAssertEqual(session.savedVoiceNames, ["Bob"])
        XCTAssertEqual(session.lines.map(\.speaker), ["Bob"])
        session.retireLiveRoster()
        XCTAssertEqual(store.enrolled.count, 1, "exactly once")
        XCTAssertEqual(store.renames.count, 1)
    }

    func testGenericNamesAreNotSaved() throws {
        let store = FakeVoiceProfileStore()
        let session = MeetingNotesSession(voiceProfiles: store)
        session.begin(title: "Sync", appName: "Gather")
        let id = try XCTUnwrap(hear("Hi", alice, in: session, channel: .mic).speakerID)

        session.renameLiveSpeaker(id: id, to: "me")
        session.finishRecording()
        session.retireLiveRoster()

        XCTAssertTrue(store.enrolled.isEmpty)
    }

    func testProfileMatchRelabelsEarlierLinesOfThatVoice() {
        let session = MeetingNotesSession()
        session.begin(title: "Sync", appName: "Gather")
        hear("Hi", alice, in: session)
        XCTAssertEqual(session.lines.last?.speaker, "Speaker 1")

        let matched = hear("It's me again", alice, in: session, matched: "Alice")

        XCTAssertEqual(matched.label, "Alice")
        XCTAssertEqual(session.lines.map(\.speaker), ["Alice", "Alice"])
    }

    func testSecondPersonOnTheMicIsNotYouOnceNamed() throws {
        let session = MeetingNotesSession()
        session.begin(title: "Room", appName: "Gather")
        hear("I'm the user", alice, in: session, channel: .mic)
        let guest = try XCTUnwrap(hear("I'm sitting next to them", bob, in: session, channel: .mic).speakerID)

        session.renameLiveSpeaker(id: guest, to: "Bob")

        let turns = session.turns(micLabel: "Me")
        XCTAssertEqual(turns.first { $0.speakerRaw == "Bob" }?.isYou, false)
        XCTAssertEqual(turns.first { $0.speakerRaw == "Me" }?.isYou, true)
    }

    func testCanNameOnlyLiveVoicesBeforeThePipelineTranscript() {
        let session = MeetingNotesSession()
        session.begin(title: "Sync", appName: "Gather")
        XCTAssertFalse(session.canNameLiveSpeakers)
        let id = hear("Hi", alice, in: session).speakerID
        XCTAssertTrue(session.canNameLiveSpeakers)
        XCTAssertEqual(session.lastLiveSpeakerID, id)
    }

    func testStartingANewSessionEnrollsThePreviousMeetingsNames() throws {
        let store = FakeVoiceProfileStore()
        let session = MeetingNotesSession(voiceProfiles: store)
        session.begin(title: "One", appName: "Gather")
        let id = try XCTUnwrap(hear("Hi", alice, in: session).speakerID)
        session.renameLiveSpeaker(id: id, to: "Alice")
        session.finishRecording()

        session.begin(title: "Two", appName: "Gather")

        XCTAssertEqual(store.enrolled.map(\.name), ["Alice"])
        XCTAssertTrue(session.speakerRoster.speakers.isEmpty)
    }

    func testANewSessionForgetsTheVoices() {
        let session = MeetingNotesSession()
        session.begin(title: "One", appName: "Gather")
        hear("Hi", alice, in: session)
        session.finishRecording()
        session.begin(title: "Two", appName: "Gather")
        XCTAssertTrue(session.speakerRoster.speakers.isEmpty)
    }

    func testLinesWithoutEmbeddingKeepTheirLabel() {
        let session = MeetingNotesSession()
        session.begin(title: "Sync", appName: "Gather")
        let resolved = session.resolveLiveSpeaker(nil, channel: .app, fallbackLabel: "Remote")
        XCTAssertNil(resolved.speakerID)
        XCTAssertEqual(resolved.label, "Remote")
    }

    // MARK: - LiveCaptionsState

    func testCaptionsResolveThroughTheNotesSession() {
        let session = MeetingNotesSession()
        let captions = LiveCaptionsState()
        captions.notes = session

        let resolved = captions.resolveSpeaker(sample(alice), channel: .app)

        XCTAssertEqual(resolved.label, "Speaker 1")
        XCTAssertNotNil(resolved.speakerID)
    }

    func testCaptionsRelabelRecentFinalsWhenAVoiceIsNamed() throws {
        let session = MeetingNotesSession()
        let captions = LiveCaptionsState()
        captions.attachNotes(session)

        let resolved = captions.resolveSpeaker(sample(alice), channel: .app)
        captions.applyFinalized("Hello", channel: .app, speaker: resolved.label, speakerID: resolved.speakerID)
        XCTAssertEqual(captions.recentFinals.map(\.speaker), ["Speaker 1"])

        try session.renameLiveSpeaker(id: XCTUnwrap(resolved.speakerID), to: "Alice")
        XCTAssertEqual(captions.recentFinals.map(\.speaker), ["Alice"])
    }

    func testCaptionsWithoutNotesFallBackToMatchOrChannelLabel() {
        let captions = LiveCaptionsState()
        XCTAssertEqual(captions.resolveSpeaker(sample(alice, matched: "Alice"), channel: .app).label, "Alice")
        XCTAssertEqual(captions.resolveSpeaker(nil, channel: .mic).label, "Me")
        XCTAssertNil(captions.resolveSpeaker(sample(alice), channel: .app).speakerID)
    }

    /// `SpeakerNamingSession.matchVerbose` reads `speakers.json` before the
    /// pipeline transcript is adopted. Names given live must already be there
    /// at Stop, or the final transcript and summary keep "Speaker N".
    func testFinishRecordingEnrollsALiveNameThePipelineMatcherSees() throws {
        let dbPath = try makeTempDirectory(prefix: "LiveNamePipeline").appendingPathComponent("speakers.json")
        let store = SpeakerDBVoiceProfileStore(dbPath: dbPath)
        let session = MeetingNotesSession(voiceProfiles: store)
        session.begin(title: "Sync", appName: "Gather")
        let id = try XCTUnwrap(hear("Hi", alice, in: session).speakerID)
        session.renameLiveSpeaker(id: id, to: "Alice")

        session.finishRecording()

        let verbose = SpeakerMatcher(dbPath: dbPath).matchVerbose(embeddings: ["SPEAKER_00": alice])
        XCTAssertEqual(verbose["SPEAKER_00"]?.assignedName, "Alice")
    }

    func testAdoptingThePipelineTranscriptRetiresAPostStopCorrection() throws {
        let store = FakeVoiceProfileStore()
        let session = MeetingNotesSession(voiceProfiles: store)
        session.begin(title: "Standup", appName: "Zoom")
        let id = try XCTUnwrap(hear("Hi", alice, in: session).speakerID)
        session.renameLiveSpeaker(id: id, to: "Aice")
        session.finishRecording()
        session.renameLiveSpeaker(id: id, to: "Bob")

        let dir = try makeTempDirectory(prefix: "notes-adopt-retire")
        let transcriptURL = dir.appendingPathComponent("t.txt")
        try "Bob: Hi".write(to: transcriptURL, atomically: true, encoding: .utf8)
        var job = PipelineJob(
            meetingTitle: "Standup",
            appName: "Zoom",
            mixPath: nil,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
            enqueuedAt: Date(),
        )
        job.state = .done
        job.transcriptPath = transcriptURL
        let queue = PipelineQueue()
        queue.jobs = [job]
        session.sync(from: queue)

        XCTAssertEqual(store.renames.map { "\($0.from)->\($0.to)" }, ["Aice->Bob"])
        XCTAssertNotNil(session.pipelineTranscript)
    }

    func testQuitRetiresANameGivenAfterStop() throws {
        let store = FakeVoiceProfileStore()
        let session = MeetingNotesSession(voiceProfiles: store)
        session.begin(title: "Sync", appName: "Gather")
        let id = try XCTUnwrap(hear("Hi", alice, in: session).speakerID)
        session.renameLiveSpeaker(id: id, to: "Aice")
        session.finishRecording()

        session.renameLiveSpeaker(id: id, to: "Bob")
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

        XCTAssertEqual(store.renames.map { "\($0.from)->\($0.to)" }, ["Aice->Bob"])
        XCTAssertEqual(store.enrolled.count, 1)
    }
}
