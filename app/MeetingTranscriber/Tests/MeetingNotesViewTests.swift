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
        let pane = MeetingNotesTranscriptPane(
            turns: session.turns(micLabel: "Me"),
            palette: TranscriptTurn.palette(for: session.turns(micLabel: "Me"), micLabel: "Me"),
            micLabel: "Me",
            duration: 12,
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

    private func makeSettings() -> AppSettings {
        let suite = "MeetingNotesViewTests-\(getpid())-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        addTeardownBlock { DefaultsSuite.remove(suite) }
        return AppSettings(defaults: defaults)
    }
}
