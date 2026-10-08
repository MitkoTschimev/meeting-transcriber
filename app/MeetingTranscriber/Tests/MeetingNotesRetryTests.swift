@testable import MeetingTranscriber
import XCTest

@MainActor
final class MeetingNotesRetryTests: XCTestCase {
    func testSyncTreatsSavedChatCompletionFailedAsNotesFailure() throws {
        let dir = try makeTempDirectory(prefix: "notes-failed-summary")
        let transcriptURL = dir.appendingPathComponent("t.txt")
        let notesURL = dir.appendingPathComponent("n.md")
        try "[00:27] Mitko: Hey".write(to: transcriptURL, atomically: true, encoding: .utf8)
        try """
        chat completion failed

        ---

        ## Full Transcript

        [00:27] Mitko: Hey
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

        XCTAssertEqual(session.phase, .ready)
        XCTAssertNil(session.notesMarkdown)
        XCTAssertEqual(session.notesFailure, .chatCompletionFailed)
        XCTAssertTrue(session.canRetryNotes)
        let message = try XCTUnwrap(session.errorMessage)
        XCTAssertTrue(message.contains("chat completion failed"))
        XCTAssertEqual(session.transcriptText, "[00:27] Mitko: Hey")
    }

    func testSyncTreatsProtocolGenerationWarningAsNotesFailure() {
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
        job.warnings = ["Notes could not be generated (timeout). The transcript was saved."]
        job.transcriptPath = URL(fileURLWithPath: "/tmp/does-not-need-to-exist-for-warning.txt")
        let queue = PipelineQueue()
        queue.jobs = [job]
        session.sync(from: queue)

        XCTAssertEqual(session.notesFailure, .timedOut)
        let message = session.errorMessage ?? ""
        XCTAssertTrue(message.contains("timeout"))
        XCTAssertFalse(session.canRetryNotes, "retry needs a readable transcript")
    }

    func testRetryNotesReplacesFailedContent() async throws {
        let dir = try makeTempDirectory(prefix: "notes-retry")
        let transcriptURL = dir.appendingPathComponent("t.txt")
        let notesURL = dir.appendingPathComponent("gather.md")
        try "[00:00] A: Hello".write(to: transcriptURL, atomically: true, encoding: .utf8)
        try "chat completion failed\n\n---\n\n## Full Transcript\n\n[00:00] A: Hello"
            .write(to: notesURL, atomically: true, encoding: .utf8)

        let protocolGen = MockProtocolGen()
        protocolGen.resultToReturn = "# Notes\nRecovered"
        let queue = PipelineQueue(
            engine: MockEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { protocolGen },
            outputDir: dir.appendingPathComponent("output", isDirectory: true),
            logDir: dir,
            micLabel: "Me",
            inFlightRuns: InFlightRunRegistry(),
        )
        var job = PipelineJob(
            meetingTitle: "Gather Tray Menu",
            appName: "GatherV2",
            mixPath: dir.appendingPathComponent("unused.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
            enqueuedAt: Date(),
        )
        job.state = .done
        job.transcriptPath = transcriptURL
        job.protocolPath = notesURL
        job.namingSlug = "gather"
        queue.insertJobForTesting(job)

        let session = MeetingNotesSession()
        session.begin(title: "Gather Tray Menu", appName: "GatherV2")
        session.finishRecording()
        session.sync(from: queue)
        XCTAssertEqual(session.notesFailure, .chatCompletionFailed)
        XCTAssertTrue(session.canRetryNotes)

        await session.retryNotes(using: queue)

        XCTAssertNil(session.notesFailure)
        XCTAssertFalse(session.isRetryingNotes)
        XCTAssertTrue(try XCTUnwrap(session.notesMarkdown).contains("Recovered"))
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(protocolGen.generateCallCount, 1)
    }
}
