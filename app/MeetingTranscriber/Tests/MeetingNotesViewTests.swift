@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class MeetingNotesViewTests: XCTestCase {
    func testShowsTitleAndTranscriptTab() throws {
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
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesTranscriptTab))
        XCTAssertNoThrow(try body.find(viewWithAccessibilityIdentifier: A11yID.meetingNotesSummaryTab))
        XCTAssertNoThrow(try body.find(text: "Alex: Let's look at the rate limits."))
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

    private func makeSettings() -> AppSettings {
        let suite = "MeetingNotesViewTests-\(getpid())-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        addTeardownBlock { DefaultsSuite.remove(suite) }
        return AppSettings(defaults: defaults)
    }
}
