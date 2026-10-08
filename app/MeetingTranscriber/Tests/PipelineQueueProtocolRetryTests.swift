@testable import MeetingTranscriber
import XCTest

@MainActor
// swiftlint:disable:next attributes balanced_xctest_lifecycle
final class PipelineQueueProtocolRetryTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "pipeline_protocol_retry_test")
    }

    func testDoesNotSaveChatCompletionFailedAsNotes() async throws {
        let protocolGen = MockProtocolGen()
        protocolGen.resultToReturn = "chat completion failed"
        let (queue, job) = try makeQueue(protocolGen: protocolGen, transcript: "[00:00] A: Hello")

        await queue.generateProtocol(
            jobID: job.id,
            transcript: "[00:00] A: Hello",
            title: job.meetingTitle,
            protocolsDir: protocolsDir,
        )

        let after = try XCTUnwrap(queue.jobs.first)
        XCTAssertNil(after.protocolPath)
        XCTAssertEqual(protocolGen.generateCallCount, 1, "short transcript must not chunk")
        XCTAssertTrue(
            after.warnings.contains { $0.contains("chat completion failed") },
            "\(after.warnings)",
        )
    }

    func testRetryOverwritesSavedFailureWithUsableNotes() async throws {
        let protocolGen = MockProtocolGen()
        protocolGen.resultToReturn = "# Notes\nShipped"
        let (queue, job) = try makeQueue(protocolGen: protocolGen, transcript: "[00:00] A: Hello")
        let failedPath = try protocolsDir.appendingPathComponent("\(XCTUnwrap(job.namingSlug)).md")
        try FileManager.default.createDirectory(at: protocolsDir, withIntermediateDirectories: true)
        try """
        chat completion failed

        ---

        ## Full Transcript

        [00:00] A: Hello
        """.write(to: failedPath, atomically: true, encoding: .utf8)
        queue.jobs[0].protocolPath = failedPath

        let replaced = await queue.retryProtocolGeneration(jobID: job.id)
        XCTAssertTrue(replaced)
        let after = try XCTUnwrap(queue.jobs.first)
        XCTAssertEqual(after.state, .done)
        let saved = try String(contentsOf: XCTUnwrap(after.protocolPath), encoding: .utf8)
        XCTAssertTrue(saved.contains("Shipped"))
        XCTAssertNil(ProtocolNotesFailure.detectingSavedContent(saved))
        XCTAssertEqual(protocolGen.generateCallCount, 1)
    }

    func testRetryWithoutTranscriptReturnsFalse() async throws {
        let protocolGen = MockProtocolGen()
        let (queue, job) = try makeQueue(protocolGen: protocolGen, transcript: "[00:00] A: Hello")
        queue.jobs[0].transcriptPath = nil

        let replaced = await queue.retryProtocolGeneration(jobID: job.id)
        XCTAssertFalse(replaced)
        XCTAssertFalse(protocolGen.generateCalled)
    }

    func testThrownTimeoutIsClassifiedInWarning() async throws {
        let protocolGen = MockProtocolGen()
        protocolGen.errorToThrow = ProtocolError.generationTimedOut(600)
        let (queue, job) = try makeQueue(protocolGen: protocolGen, transcript: "[00:00] A: Hello")

        await queue.generateProtocol(
            jobID: job.id,
            transcript: "[00:00] A: Hello",
            title: job.meetingTitle,
            protocolsDir: protocolsDir,
        )

        let after = try XCTUnwrap(queue.jobs.first)
        XCTAssertNil(after.protocolPath)
        XCTAssertTrue(
            after.warnings.contains { $0.contains("timeout") },
            "\(after.warnings)",
        )
    }

    func testLongTranscriptChunksAfterFailedDirectCompletion() async throws {
        let protocolGen = MockProtocolGen()
        protocolGen.resultsQueue = ["chat completion failed"]
        protocolGen.resultToReturn = "# Notes\nChunked"
        let longTranscript = String(
            repeating: "[00:00] Speaker: hello there colleagues\n",
            count: 1200,
        )
        XCTAssertTrue(ProtocolTranscriptChunker.needsChunking(longTranscript))
        let (queue, job) = try makeQueue(protocolGen: protocolGen, transcript: longTranscript)

        await queue.generateProtocol(
            jobID: job.id,
            transcript: longTranscript,
            title: job.meetingTitle,
            protocolsDir: protocolsDir,
        )

        let after = try XCTUnwrap(queue.jobs.first)
        XCTAssertNotNil(after.protocolPath)
        XCTAssertGreaterThan(protocolGen.generateCallCount, 1)
        let saved = try String(contentsOf: XCTUnwrap(after.protocolPath), encoding: .utf8)
        XCTAssertTrue(saved.contains("Chunked"))
        XCTAssertNil(ProtocolNotesFailure.detectingSavedContent(saved))
        XCTAssertEqual(protocolGen.capturedTranscripts.first, longTranscript)
        XCTAssertTrue(protocolGen.capturedTranscripts.dropFirst().contains { $0.contains("part 1 of") })
    }

    private var protocolsDir: URL {
        tmpDir.appendingPathComponent("output/protocols", isDirectory: true)
    }

    private func makeQueue(
        protocolGen: MockProtocolGen,
        transcript: String,
    ) throws -> (PipelineQueue, PipelineJob) {
        let root = tmpDir.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transcriptPath = tmpDir.appendingPathComponent("meeting.txt")
        try transcript.write(to: transcriptPath, atomically: true, encoding: .utf8)

        let queue = PipelineQueue(
            engine: MockEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { protocolGen },
            outputDir: root,
            logDir: tmpDir,
            micLabel: "Me",
            inFlightRuns: InFlightRunRegistry(),
        )
        var job = PipelineJob(
            meetingTitle: "Gather Tray Menu",
            appName: "GatherV2",
            mixPath: tmpDir.appendingPathComponent("unused.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        job.state = .done
        job.transcriptPath = transcriptPath
        job.namingSlug = "gather_tray_menu"
        queue.insertJobForTesting(job)
        return (queue, job)
    }
}
