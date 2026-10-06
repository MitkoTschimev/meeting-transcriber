@testable import MeetingTranscriber
import XCTest

@MainActor
final class MeetingNotesSessionTests: XCTestCase {
    func testBeginSetsRecordingMetadata() {
        let session = MeetingNotesSession()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        session.begin(title: "Standup", appName: "Zoom", startTime: start)

        XCTAssertEqual(session.title, "Standup")
        XCTAssertEqual(session.appName, "Zoom")
        XCTAssertEqual(session.startedAt, start)
        XCTAssertEqual(session.phase, .recording)
        XCTAssertTrue(session.hasSession)
    }

    func testSecondBeginWhileRecordingRetitlesWithoutWipingLines() {
        let session = MeetingNotesSession()
        session.begin(title: "Meeting", appName: "")
        session.thoughts = "keep this"
        session.applyFinalized("hello", channel: .mic, speaker: "Me")
        session.begin(title: "Standup", appName: "Teams")

        XCTAssertEqual(session.title, "Standup")
        XCTAssertEqual(session.appName, "Teams")
        XCTAssertEqual(session.lines.map(\.text), ["hello"])
        XCTAssertEqual(session.thoughts, "keep this")
        XCTAssertEqual(session.phase, .recording)
    }

    func testNewBeginAfterFinishStartsFreshSession() {
        let session = MeetingNotesSession()
        session.begin(title: "One", appName: "Zoom")
        session.applyFinalized("first", channel: .mic, speaker: "Me")
        session.thoughts = "scratch"
        session.finishRecording()
        session.begin(title: "Two", appName: "Teams")

        XCTAssertEqual(session.title, "Two")
        XCTAssertTrue(session.lines.isEmpty)
        XCTAssertEqual(session.thoughts, "")
        XCTAssertEqual(session.phase, .recording)
    }

    func testApplyPartialAndFinalizedBuildLiveTranscript() {
        let session = MeetingNotesSession()
        session.begin(title: "Call", appName: "Meet")
        session.applyPartial("hello the", channel: .app)
        session.applyFinalized("hello there", channel: .app, speaker: "Alex")
        session.applyPartial("I am", channel: .mic)

        XCTAssertEqual(session.lines, [
            LiveCaptionLine(channel: .app, text: "hello there", speaker: "Alex"),
        ])
        XCTAssertEqual(session.hypothesisApp, "")
        XCTAssertEqual(session.hypothesisMic, "I am")
        XCTAssertTrue(session.liveTranscriptText.contains("Alex: hello there"))
        XCTAssertTrue(session.liveTranscriptText.contains("Me: I am"))
    }

    func testFinishRecordingClearsHypothesesAndMarksProcessing() {
        let session = MeetingNotesSession()
        session.begin(title: "Call", appName: "Meet", startTime: Date().addingTimeInterval(-5))
        session.applyPartial("partial", channel: .mic)
        session.finishRecording()

        XCTAssertEqual(session.phase, .processing)
        XCTAssertEqual(session.hypothesisMic, "")
        XCTAssertNotNil(session.endedAt)
        XCTAssertGreaterThanOrEqual(session.duration(), 4)
    }

    func testCaptionsBeforeBeginAutoStartASession() {
        let session = MeetingNotesSession()
        session.applyFinalized("early line", channel: .mic, speaker: "Me")
        XCTAssertEqual(session.phase, .recording)
        XCTAssertEqual(session.displayTitle, "Meeting")
        XCTAssertEqual(session.lines.map(\.text), ["early line"])
    }

    func testSyncLoadsTranscriptAndNotesFromMatchingJob() throws {
        let dir = try makeTempDirectory(prefix: "notes-sync")
        let transcriptURL = dir.appendingPathComponent("t.txt")
        let notesURL = dir.appendingPathComponent("n.md")
        try "Full transcript".write(to: transcriptURL, atomically: true, encoding: .utf8)
        try "# Notes\n- ship it".write(to: notesURL, atomically: true, encoding: .utf8)

        var job = PipelineJob(
            meetingTitle: "Standup",
            appName: "Zoom",
            mixPath: nil,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        job.state = .done
        job.transcriptPath = transcriptURL
        job.protocolPath = notesURL

        let queue = PipelineQueue()
        queue.jobs = [job]

        let session = MeetingNotesSession()
        session.begin(title: "Standup", appName: "Zoom")
        session.finishRecording()
        session.sync(from: queue)

        XCTAssertEqual(session.transcriptText, "Full transcript")
        XCTAssertEqual(session.notesMarkdown, "# Notes\n- ship it")
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.jobID, job.id)
    }

    func testSyncMapsGeneratingProtocolToGeneratingNotes() {
        var job = PipelineJob(
            meetingTitle: "Standup",
            appName: "Zoom",
            mixPath: nil,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        job.state = .generatingProtocol
        let queue = PipelineQueue()
        queue.jobs = [job]

        let session = MeetingNotesSession()
        session.begin(title: "Standup", appName: "Zoom")
        session.finishRecording()
        session.sync(from: queue)

        XCTAssertEqual(session.phase, .generatingNotes)
    }

    func testLiveCaptionsForwardIntoNotesWithoutClearingSession() {
        let session = MeetingNotesSession()
        let captions = LiveCaptionsState()
        captions.notes = session

        captions.applyFinalized("keep me", channel: .mic, speaker: "Me")
        XCTAssertEqual(session.lines.map(\.text), ["keep me"])

        captions.clear()
        XCTAssertTrue(captions.recentFinals.isEmpty)
        XCTAssertEqual(session.lines.map(\.text), ["keep me"])
    }
}
