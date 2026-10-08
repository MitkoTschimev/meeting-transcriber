import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PipelineQueue")

extension PipelineQueue {
    /// Re-run protocol generation from the transcript already on disk.
    /// Unlike `retryJob`, this does not transcribe again.
    ///
    /// Returns whether usable notes were written. A false result leaves any
    /// previously saved (possibly failed) `.md` in place so Retry can run
    /// again; `generateProtocol` refuses to overwrite with error text.
    @discardableResult
    func retryProtocolGeneration(jobID: UUID) async -> Bool {
        guard let job = jobs.first(where: { $0.id == jobID }),
              let transcriptPath = job.transcriptPath,
              let outputDir,
              protocolGeneratorFactory?() != nil,
              let transcript = try? String(contentsOf: transcriptPath, encoding: .utf8),
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }

        await generateProtocol(
            jobID: jobID,
            transcript: transcript,
            title: job.meetingTitle,
            protocolsDir: outputDir.appendingPathComponent("protocols"),
        )
        if let current = jobs.first(where: { $0.id == jobID }),
           current.state == .generatingProtocol {
            updateJobState(id: jobID, to: .done)
        }
        guard let updated = jobs.first(where: { $0.id == jobID }),
              let path = updated.protocolPath,
              let text = try? String(contentsOf: path, encoding: .utf8)
        else { return false }
        return ProtocolNotesFailure.detectingSavedContent(text) == nil
    }

    /// Direct generate, then chunked fallback when the failure looks like
    /// context pressure on a long transcript. Throws if both paths fail so
    /// `generateProtocol` can warn without saving the error as notes.
    ///
    /// The generator is resolved from the factory on every call rather than
    /// held across `await` — `any ProtocolGenerating` is not Sendable.
    func produceProtocolMarkdown(
        transcript: String,
        title: String,
        diarized: Bool,
        meetingStartTime: Date?,
    ) async throws -> String {
        do {
            let direct = try await requestProtocolMarkdown(
                transcript: transcript,
                title: title,
                diarized: diarized,
                meetingStartTime: meetingStartTime,
            )
            if ProtocolNotesFailure.detectingSavedContent(direct) == nil {
                return direct
            }
            let failure = ProtocolNotesFailure.detectingSavedContent(direct) ?? .chatCompletionFailed
            try throwUnlessChunking(failure, transcript: transcript)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            let failure = ProtocolNotesFailure.classifying(error)
            try throwUnlessChunking(failure, transcript: transcript, wrapped: error)
        }
        return try await generateChunkedProtocol(
            transcript: transcript,
            title: title,
            diarized: diarized,
            meetingStartTime: meetingStartTime,
        )
    }

    private func throwUnlessChunking(
        _ failure: ProtocolNotesFailure,
        transcript: String,
        wrapped: (any Error)? = nil,
    ) throws {
        let canChunk = ProtocolTranscriptChunker.needsChunking(transcript)
            && failure.suggestsContextPressure
        guard canChunk else {
            throw wrapped ?? failure.asProtocolError()
        }
        logger.info(
            "protocol_generation_chunking reason=\(failure.reasonLabel, privacy: .public) transcript_chars=\(transcript.count, privacy: .public)",
        )
    }

    private func generateChunkedProtocol(
        transcript: String,
        title: String,
        diarized: Bool,
        meetingStartTime: Date?,
    ) async throws -> String {
        let chunks = ProtocolTranscriptChunker.chunks(transcript)
        var parts: [String] = []
        parts.reserveCapacity(chunks.count)
        for (index, chunk) in chunks.enumerated() {
            let labeled = """
            This is part \(index + 1) of \(chunks.count) of a long meeting. \
            Write a compact section summary: topics, decisions, and action items only. \
            Do not write a full protocol.

            \(chunk)
            """
            let part = try await requestProtocolMarkdown(
                transcript: labeled,
                title: title,
                diarized: diarized,
                meetingStartTime: meetingStartTime,
            )
            if let failure = ProtocolNotesFailure.detectingSavedContent(part) {
                throw failure.asProtocolError()
            }
            parts.append(part)
        }
        let combined = parts.enumerated()
            .map { "## Section \($0.offset + 1)\n\n\($0.element)" }
            .joined(separator: "\n\n")
        let merge = """
        The following are section summaries of a \(parts.count)-part meeting. \
        Produce the finished notes from them. Do not mention the sections.

        \(combined)
        """
        let merged = try await requestProtocolMarkdown(
            transcript: merge,
            title: title,
            diarized: diarized,
            meetingStartTime: meetingStartTime,
        )
        if let failure = ProtocolNotesFailure.detectingSavedContent(merged) {
            throw failure.asProtocolError()
        }
        return merged
    }

    private func requestProtocolMarkdown(
        transcript: String,
        title: String,
        diarized: Bool,
        meetingStartTime: Date?,
    ) async throws -> String {
        guard let protocolGeneratorFactory, let generator = protocolGeneratorFactory() else {
            throw ProtocolError.connectionFailed("Notes generator is not configured")
        }
        return try await generator.generate(
            transcript: transcript,
            title: title,
            diarized: diarized,
            meetingStartTime: meetingStartTime,
        )
    }
}
