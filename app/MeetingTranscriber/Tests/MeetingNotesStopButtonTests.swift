@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// The Meeting Notes window's Stop Recording button: visible only while a
/// recording runs and something can stop it. A press (or ⌘.) asks for
/// confirmation so an accidental shortcut while typing notes does not
/// finalize the recording.
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

    func testStopButtonShowsWhileRecording() throws {
        let session = MeetingNotesSession()
        session.begin(title: "Standup", appName: "GatherV2")
        let view = makeView(session: session) {}

        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.meetingNotesStopButton))
    }

    func testFirstPressArmsConfirmWithoutStopping() throws {
        let stops = ManagedCounter()
        var confirmStop = false
        let view = MeetingNotesStopButton(
            onStop: { _ = stops.increment() },
            confirmStop: Binding(get: { confirmStop }, set: { confirmStop = $0 }),
        )

        try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.meetingNotesStopButton).button().tap()

        XCTAssertTrue(confirmStop)
        XCTAssertEqual(stops.value, 0, "the first press only asks; it must not finalize")
    }

    func testConfirmingStops() throws {
        let stops = ManagedCounter()
        var confirmStop = true
        let view = MeetingNotesStopButton(
            onStop: { _ = stops.increment() },
            confirmStop: Binding(get: { confirmStop }, set: { confirmStop = $0 }),
        )

        try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.meetingNotesConfirmStopButton).button().tap()
        XCTAssertEqual(stops.value, 1)
    }

    func testKeepRecordingDismissesWithoutStopping() throws {
        let stops = ManagedCounter()
        var confirmStop = true
        let view = MeetingNotesStopButton(
            onStop: { _ = stops.increment() },
            confirmStop: Binding(get: { confirmStop }, set: { confirmStop = $0 }),
        )

        try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.meetingNotesKeepRecordingButton).button().tap()
        XCTAssertFalse(confirmStop)
        XCTAssertEqual(stops.value, 0)
    }

    func testConfirmDisarmsAfterTimeoutIfStillArmed() async {
        var armed = true
        await MeetingNotesStopButton.disarmIfStillArmed(
            timeout: 0,
            sleep: { _ in },
            isStillArmed: { armed },
            disarm: { armed = false },
        )
        XCTAssertFalse(armed)
    }

    func testConfirmDoesNotDisarmAfterKeepRecording() async {
        let armed = false
        var disarmed = false
        await MeetingNotesStopButton.disarmIfStillArmed(
            timeout: 0,
            sleep: { _ in },
            isStillArmed: { armed },
            disarm: { disarmed = true },
        )
        XCTAssertFalse(disarmed)
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
