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

        let session = MeetingNotesSession()
        session.begin(title: "Standup", appName: "Zoom")
        session.finishRecording()

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
        job.protocolPath = notesURL

        let queue = PipelineQueue()
        queue.jobs = [job]
        session.sync(from: queue)

        XCTAssertEqual(session.transcriptText, "Full transcript")
        XCTAssertEqual(session.notesMarkdown, "# Notes\n- ship it")
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.jobID, job.id)
    }

    func testSyncMapsGeneratingProtocolToGeneratingNotes() {
        let session = MeetingNotesSession()
        session.begin(title: "Standup", appName: "Zoom")
        session.finishRecording()

        var job = PipelineJob(
            meetingTitle: "Standup",
            appName: "Zoom",
            mixPath: nil,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
            enqueuedAt: Date(),
        )
        job.state = .generatingProtocol
        let queue = PipelineQueue()
        queue.jobs = [job]
        session.sync(from: queue)

        XCTAssertEqual(session.phase, .generatingNotes)
    }

    func testSyncDoesNotBindOlderSameTitleJobWhileRecording() throws {
        let dir = try makeTempDirectory(prefix: "notes-recording-isolation")
        let oldTranscript = dir.appendingPathComponent("old.txt")
        let oldNotes = dir.appendingPathComponent("old.md")
        try "Yesterday's standup".write(to: oldTranscript, atomically: true, encoding: .utf8)
        try "# Old notes".write(to: oldNotes, atomically: true, encoding: .utf8)

        var oldJob = PipelineJob(
            meetingTitle: "Standup",
            appName: "Zoom",
            mixPath: nil,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
            enqueuedAt: Date().addingTimeInterval(-3600),
        )
        oldJob.state = .done
        oldJob.transcriptPath = oldTranscript
        oldJob.protocolPath = oldNotes

        let queue = PipelineQueue()
        queue.jobs = [oldJob]

        let session = MeetingNotesSession()
        session.begin(title: "Standup", appName: "Zoom")
        session.applyFinalized("live line from this meeting", channel: .mic, speaker: "Me")
        session.sync(from: queue)

        XCTAssertEqual(session.phase, .recording)
        XCTAssertNil(session.jobID)
        XCTAssertNil(session.pipelineTranscript)
        XCTAssertNil(session.notesMarkdown)
        XCTAssertEqual(session.lines.map(\.text), ["live line from this meeting"])
        XCTAssertTrue(session.transcriptText.contains("live line from this meeting"))
        XCTAssertFalse(session.transcriptText.contains("Yesterday's standup"))
    }

    func testSyncAfterFinishIgnoresOlderSameTitleJob() throws {
        let dir = try makeTempDirectory(prefix: "notes-old-after-finish")
        let oldTranscript = dir.appendingPathComponent("old.txt")
        try "Yesterday's standup".write(to: oldTranscript, atomically: true, encoding: .utf8)

        var oldJob = PipelineJob(
            meetingTitle: "Standup",
            appName: "Zoom",
            mixPath: nil,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
            enqueuedAt: Date().addingTimeInterval(-3600),
        )
        oldJob.state = .done
        oldJob.transcriptPath = oldTranscript

        let session = MeetingNotesSession()
        session.begin(title: "Standup", appName: "Zoom")
        session.applyFinalized("this meeting", channel: .mic, speaker: "Me")
        session.finishRecording()

        let queue = PipelineQueue()
        queue.jobs = [oldJob]
        session.sync(from: queue)

        XCTAssertNil(session.jobID)
        XCTAssertNil(session.pipelineTranscript)
        XCTAssertEqual(session.phase, .processing)
        XCTAssertEqual(session.lines.map(\.text), ["this meeting"])
    }

    func testDoneJobWithNilProtocolPathEndsReadyAndSurfacesWarnings() {
        let session = MeetingNotesSession()
        session.begin(title: "Standup", appName: "Zoom")
        session.finishRecording()

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
        job.warnings = ["Protocol generation skipped"]
        let queue = PipelineQueue()
        queue.jobs = [job]
        session.sync(from: queue)

        XCTAssertEqual(session.phase, .ready)
        XCTAssertNil(session.notesMarkdown)
        XCTAssertEqual(session.warnings, ["Protocol generation skipped"])
        XCTAssertNotEqual(session.phase, .processing)
        XCTAssertNotEqual(session.phase, .failed)
    }

    func testThoughtsPersistBesideJobTranscript() throws {
        let dir = try makeTempDirectory(prefix: "thoughts-store")
        let store = MeetingThoughtsStore(directory: dir.appendingPathComponent("scratch", isDirectory: true))
        let transcriptURL = dir.appendingPathComponent("standup.txt")
        try "transcript".write(to: transcriptURL, atomically: true, encoding: .utf8)

        let session = MeetingNotesSession(thoughtsStore: store)
        let start = Date(timeIntervalSince1970: 1_700_000_100)
        session.begin(title: "Standup", appName: "Zoom", startTime: start)
        session.thoughts = "private scratch"
        session.finishRecording()

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

        let sibling = transcriptURL.deletingPathExtension().appendingPathExtension("thoughts.md")
        XCTAssertEqual(try String(contentsOf: sibling, encoding: .utf8), "private scratch")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.inProgressURL(startedAt: start).path),
        )

        let reloaded = MeetingNotesSession(thoughtsStore: store)
        reloaded.begin(title: "Standup", appName: "Zoom", startTime: start)
        reloaded.finishRecording()
        reloaded.sync(from: queue)
        XCTAssertEqual(reloaded.thoughts, "private scratch")
        XCTAssertEqual(reloaded.phase, .ready)
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

    func testSpeakerPaletteKeepsLiveOrderAfterPipelineTranscript() throws {
        let session = MeetingNotesSession()
        session.begin(title: "Call", appName: "Zoom")
        session.applyFinalized("hi", channel: .mic, speaker: "Me")
        session.applyFinalized("there", channel: .app, speaker: "Alex")
        let liveOrder = session.palette(for: session.turns(micLabel: "Me"), micLabel: "Me").order
        XCTAssertEqual(liveOrder, [SpeakerAccent.youKey, "alex"])

        let dir = try makeTempDirectory(prefix: "notes-palette")
        let transcriptURL = dir.appendingPathComponent("t.txt")
        try "[00:00] Alex: from file\n[00:04] Me: later\n".write(
            to: transcriptURL,
            atomically: true,
            encoding: .utf8,
        )
        session.finishRecording()
        var job = PipelineJob(
            meetingTitle: "Call",
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

        let after = session.palette(for: session.turns(micLabel: "Me"), micLabel: "Me")
        XCTAssertEqual(after.order, liveOrder)
        XCTAssertEqual(after.othersIndex(for: "alex"), 0)
    }
}
