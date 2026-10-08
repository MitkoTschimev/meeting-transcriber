@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// The Meeting Notes window's Stop Recording button: visible only while a
/// recording runs and something can stop it, and wired to that stop.
@MainActor
final class MeetingNotesStopButtonTests: XCTestCase {
    private func makeView(session: MeetingNotesSession, onStop: (() -> Void)?) -> MeetingNotesView {
        let suite = "MeetingNotesStopButtonTests-\(getpid())-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        addTeardownBlock { DefaultsSuite.remove(suite) }
        return MeetingNotesView(
            session: session,
            settings: AppSettings(defaults: defaults),
            queue: PipelineQueue(),
            liveTranscriptionEnabled: true,
            onStopRecording: onStop,
        )
    }

    func testStopButtonShowsWhileRecordingAndCallsTheStop() throws {
        let session = MeetingNotesSession()
        session.begin(title: "Standup", appName: "GatherV2")
        let stops = ManagedCounter()
        let view = makeView(session: session) { _ = stops.increment() }

        let button = try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.meetingNotesStopButton)
        try button.button().tap()

        XCTAssertEqual(stops.value, 1)
    }

    func testNoStopButtonWithoutAStopAction() throws {
        let session = MeetingNotesSession()
        session.begin(title: "Standup", appName: "GatherV2")
        let view = makeView(session: session, onStop: nil)

        XCTAssertThrowsError(try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.meetingNotesStopButton))
    }

    func testNoStopButtonOnceTheRecordingFinished() throws {
        let session = MeetingNotesSession()
        session.begin(title: "Standup", appName: "GatherV2")
        session.finishRecording()
        let view = makeView(session: session) {}

        XCTAssertThrowsError(try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.meetingNotesStopButton))
    }
}
