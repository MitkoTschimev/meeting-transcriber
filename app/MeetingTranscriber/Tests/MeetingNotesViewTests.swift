@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class MeetingNotesViewTests: XCTestCase {
    func testShowsTitleAndThreeTabs() throws {
        let session = MeetingNotesSession()
        session.begin(title: "Hyperliquid API Integration Challenges", appName: "Zoom")
        session.applyFinalized("Let's look at the rate limits.", channel: .app, speaker: "Alex")

        let view = MeetingNotesView(
            session: session,
            settings: makeSettings(),
            queue: PipelineQueue(),
            liveTranscriptionEnabled: true,
        )
        let body = try view.inspect()
        XCTAssertNoThrow(try body.find(text: "Hyperliquid API Integration Challenges"))
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesThoughtsTab))
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesTranscriptTab))
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesSummaryTab))
        XCTAssertNoThrow(try body.find(text: "Alex"))
        XCTAssertNoThrow(try body.find(text: "Let's look at the rate limits."))
        XCTAssertNoThrow(try body.find(text: "1 SPEAKER"))
    }

    func testTranscriptLabelsLocalSpeakerAsYou() throws {
        let session = MeetingNotesSession()
        session.begin(title: "Call", appName: "Zoom")
        session.applyFinalized("I'll take it.", channel: .mic, speaker: "Me")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let pane = MeetingNotesTranscriptPane(
            turns: session.turns(micLabel: "Me"),
            palette: TranscriptTurn.palette(for: session.turns(micLabel: "Me"), micLabel: "Me"),
            micLabel: "Me",
            startedAt: start,
            endedAt: start.addingTimeInterval(12),
            liveTranscriptionEnabled: true,
            phase: .recording,
            emptyHint: "Listening",
        )
        let body = try pane.inspect()
        XCTAssertNoThrow(try body.find(text: "Me (You)"))
        XCTAssertNoThrow(try body.find(text: "I'll take it."))
        XCTAssertNoThrow(try body.find(text: "1 SPEAKER · 0:12"))
    }

    func testThoughtsTabShowsPrivacyHint() throws {
        let session = MeetingNotesSession()
        session.begin(title: "Call", appName: "Zoom")
        let view = MeetingNotesView(
            session: session,
            settings: makeSettings(),
            queue: PipelineQueue(),
            liveTranscriptionEnabled: true,
            initialTab: .thoughts,
        )
        let body = try view.inspect()
        XCTAssertNoThrow(try body.find(text: MeetingNotesView.thoughtsPrivacyHint))
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesThoughts))
    }

    func testSummaryTabShowsDraftActionItemsWhileRecording() throws {
        let session = MeetingNotesSession()
        session.begin(title: "Planning", appName: "Meet")
        session.applyFinalized("I'll send the deck tomorrow.", channel: .mic, speaker: "Me")

        let view = MeetingNotesView(
            session: session,
            settings: makeSettings(),
            queue: PipelineQueue(),
            liveTranscriptionEnabled: true,
            initialTab: .summary,
        )
        let body = try view.inspect()
        XCTAssertNoThrow(try body.find(text: "Likely action items"))
        XCTAssertNoThrow(try body.find(text: "• Me: I'll send the deck tomorrow."))
    }

    func testSummaryTabShowsGeneratedNotes() throws {
        let session = MeetingNotesSession()
        session.begin(title: "Planning", appName: "Meet")
        session.finishRecording()
        session.applyGeneratedNotes("Ship the notes window")

        let view = MeetingNotesView(
            session: session,
            settings: makeSettings(),
            queue: PipelineQueue(),
            liveTranscriptionEnabled: false,
            initialTab: .summary,
        )
        let body = try view.inspect()
        XCTAssertNoThrow(try body.find(text: "Ship the notes window"))
    }

    func testGeneratingPlaceholderUsesPreferredStyleCaption() throws {
        let placeholder = NotesGeneratingPlaceholder(style: .actionItems)
        let body = try placeholder.inspect()
        XCTAssertNoThrow(try body.find(text: "Turning this meeting into action items"))
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesGenerating))
    }

    func testLiveTranscriptionHintWhenDisabledDuringRecording() throws {
        let session = MeetingNotesSession()
        session.begin(title: "Call", appName: "Zoom")
        let view = MeetingNotesView(
            session: session,
            settings: makeSettings(),
            queue: PipelineQueue(),
            liveTranscriptionEnabled: false,
        )
        let body = try view.inspect()
        XCTAssertNoThrow(try body.find(text: MeetingNotesView.liveTranscriptionHint))
    }

    func testAskBarStubIsPresent() throws {
        let session = MeetingNotesSession()
        let view = MeetingNotesView(
            session: session,
            settings: makeSettings(),
            queue: PipelineQueue(),
            liveTranscriptionEnabled: false,
        )
        XCTAssertNoThrow(
            try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.meetingNotesAskBar),
        )
    }

    func testTabAfterPhaseChangeLeavesTranscriptWhenUserPickedIt() {
        XCTAssertEqual(
            MeetingNotesView.tabAfterPhaseChange(
                phase: .ready,
                current: .transcript,
                userPickedTab: true,
            ),
            .transcript,
        )
        XCTAssertEqual(
            MeetingNotesView.tabAfterPhaseChange(
                phase: .generatingNotes,
                current: .thoughts,
                userPickedTab: false,
            ),
            .thoughts,
        )
        XCTAssertEqual(
            MeetingNotesView.tabAfterPhaseChange(
                phase: .ready,
                current: .transcript,
                userPickedTab: false,
            ),
            .summary,
        )
        XCTAssertEqual(
            MeetingNotesView.tabAfterPhaseChange(
                phase: .recording,
                current: .transcript,
                userPickedTab: false,
            ),
            .transcript,
        )
    }

    func testStylePickerDisablesOnceNotesExist() throws {
        let session = MeetingNotesSession()
        session.begin(title: "Planning", appName: "Meet")
        session.finishRecording()
        session.applyGeneratedNotes("Ship it")

        let view = MeetingNotesView(
            session: session,
            settings: makeSettings(),
            queue: PipelineQueue(),
            liveTranscriptionEnabled: false,
            initialTab: .summary,
        )
        let body = try view.inspect()
        XCTAssertTrue(
            try body.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesStylePicker).isDisabled(),
        )
        XCTAssertNoThrow(try body.find(text: "applies to next meeting"))
    }

    func testSummaryShowsWarningsWhenReadyWithoutNotes() throws {
        let session = MeetingNotesSession()
        session.begin(title: "Planning", appName: "Meet")
        session.finishRecording()
        var job = PipelineJob(
            meetingTitle: "Planning",
            appName: "Meet",
            mixPath: nil,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
            enqueuedAt: Date(),
        )
        job.state = .done
        job.warnings = ["Protocol generation skipped"]
        let queue = PipelineQueue()
        queue.jobs = [job]
        session.sync(from: queue)

        let view = MeetingNotesView(
            session: session,
            settings: makeSettings(),
            queue: queue,
            liveTranscriptionEnabled: false,
            initialTab: .summary,
        )
        let body = try view.inspect()
        XCTAssertNoThrow(try body.find(text: "Protocol generation skipped"))
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesGenerating))
    }

    func testRecordOnlyFinishDoesNotShowGeneratingPlaceholder() throws {
        let session = MeetingNotesSession()
        session.begin(title: "Planning", appName: "Meet")
        session.applyFinalized("hello", channel: .mic, speaker: "Me")
        session.finishRecording(recordOnly: true)
        session.sync(from: PipelineQueue())

        let settings = makeSettings()
        settings.recordOnly = true
        let view = MeetingNotesView(
            session: session,
            settings: settings,
            queue: PipelineQueue(),
            liveTranscriptionEnabled: true,
            initialTab: .summary,
        )
        let body = try view.inspect()
        XCTAssertEqual(session.phase, .ready)
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesGenerating))
        XCTAssertNoThrow(try body.find(text: "Record-only is on — notes are not generated."))
    }

    func testSummaryShowsRetryForSavedChatCompletionFailure() throws {
        let dir = try makeTempDirectory(prefix: "notes-view-retry")
        let transcriptURL = dir.appendingPathComponent("t.txt")
        let notesURL = dir.appendingPathComponent("n.md")
        try "[00:27] Mitko: Hey".write(to: transcriptURL, atomically: true, encoding: .utf8)
        try """
        chat completion failed

        ---

        ## Full Transcript

        [00:27] Mitko: Hey Ähm, hast du das in Google Meetup oder hier?
        """.write(to: notesURL, atomically: true, encoding: .utf8)

        let session = MeetingNotesSession()
        session.begin(title: "Gather Tray Menu", appName: "GatherV2")
        session.finishRecording()
        var job = PipelineJob(
            meetingTitle: "Gather Tray Menu",
            appName: "GatherV2",
            mixPath: nil,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
            enqueuedAt: Date(),
        )
        job.state = .done
        job.transcriptPath = transcriptURL
        job.protocolPath = notesURL
        let queue = PipelineQueue()
        queue.jobs = [job]
        session.sync(from: queue)

        let view = MeetingNotesView(
            session: session,
            settings: makeSettings(),
            queue: queue,
            liveTranscriptionEnabled: false,
            initialTab: .summary,
        )
        let body = try view.inspect()
        XCTAssertNoThrow(try body.find(text: "Notes could not be generated (chat completion failed). The transcript was saved."))
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesSummaryError))
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesRetryButton))
        XCTAssertNoThrow(try body.find(button: "Retry"))
        XCTAssertThrowsError(try body.find(text: "Hey Ähm, hast du das in Google Meetup oder hier?"))
        XCTAssertFalse(
            try body.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesStylePicker).isDisabled(),
        )
    }

    private func makeSettings() -> AppSettings {
        let suite = "MeetingNotesViewTests-\(getpid())-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        addTeardownBlock { DefaultsSuite.remove(suite) }
        return AppSettings(defaults: defaults)
    }
}
