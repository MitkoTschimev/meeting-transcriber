import Foundation

/// A protocol/notes generation failure, as opposed to usable Markdown notes.
///
/// Two shapes land in the Summary tab as if they were notes:
/// 1. The LLM call throws (`ProtocolError`) and used to become a warning only.
/// 2. Some OpenAI-compatible servers answer HTTP 200 with a body whose content
///    is literally `"chat completion failed"`. That string was then concatenated
///    with `## Full Transcript` and saved as the `.md` file, so a later open
///    looks like a finished summary.
///
/// This type is the single detector for both: classify a thrown error, and
/// recognise already-saved files (including meetings recorded before the
/// detector existed).
enum ProtocolNotesFailure: Equatable, Sendable {
    case chatCompletionFailed
    case timedOut
    case unauthorized
    case modelUnavailable
    case contextTooLong
    case truncated
    case empty
    case connection
    case httpStatus(Int)
    case unknown

    /// Short reason shown in the Summary error copy, e.g. "timeout".
    var reasonLabel: String {
        switch self {
        case .chatCompletionFailed: "chat completion failed"
        case .timedOut: "timeout"
        case .unauthorized: "auth"
        case .modelUnavailable: "model unavailable"
        case .contextTooLong: "context too long"
        case .truncated: "output truncated"
        case .empty: "empty response"
        case .connection: "connection failed"
        case let .httpStatus(code): "HTTP \(code)"
        case .unknown: "generation failed"
        }
    }

    var userMessage: String {
        "Notes could not be generated (\(reasonLabel)). The transcript was saved."
    }

    /// Failures that often mean the prompt (transcript + system prompt) did not
    /// fit the model. Retry then splits a long transcript into chunks.
    var suggestsContextPressure: Bool {
        switch self {
        case .chatCompletionFailed, .contextTooLong, .truncated, .empty: true

        case .timedOut, .unauthorized, .modelUnavailable, .connection, .httpStatus, .unknown:
            false
        }
    }

    /// Heading the pipeline appends when "include full transcript" is on.
    /// Detection strips everything from this heading so the error line is not
    /// hidden behind seventy minutes of speech.
    static let fullTranscriptHeading = "## Full Transcript"

    /// Protocol body with the optional Full Transcript appendix removed.
    static func notesBody(from markdown: String) -> String {
        let heading = fullTranscriptHeading
        guard let range = markdown.range(of: heading) else { return markdown }
        var body = String(markdown[..<range.lowerBound])
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasSuffix("---") {
            body = String(body.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return body
    }

    /// `nil` when `markdown` looks like real notes. Existing files whose whole
    /// notes body is "chat completion failed" (the screenshot case) are a
    /// failure even though the job is `.done`.
    static func detectingSavedContent(_ markdown: String) -> Self? {
        let body = notesBody(from: markdown).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return .empty }
        if let failure = phraseFailure(body) { return failure }
        let firstLine = body.split(whereSeparator: \.isNewline)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return phraseFailure(firstLine)
    }

    /// Job warnings from a generate call that threw and saved nothing.
    static func detecting(warnings: [String]) -> Self? {
        for warning in warnings {
            let lower = warning.lowercased()
            let mentionsFailure = lower.contains("protocol generation failed")
                || lower.contains("notes could not be generated")
            guard mentionsFailure else { continue }
            if let open = warning.firstIndex(of: "("),
               let close = warning.firstIndex(of: ")"),
               open < close {
                let reason = String(warning[warning.index(after: open) ..< close])
                return from(reasonLabel: reason)
            }
            return .unknown
        }
        return nil
    }

    static func classifying(_ error: any Error) -> Self {
        if let protocolError = error as? ProtocolError {
            return classifying(protocolError)
        }
        return classifying(diagnostic: error.localizedDescription) ?? .unknown
    }

    static func classifying(_ error: ProtocolError) -> Self {
        switch error {
        #if !APPSTORE
            case .timeout: .timedOut

            case .cliFailed, .cliNotFound: classifying(diagnostic: error.localizedDescription) ?? .unknown
        #endif

        case .emptyProtocol: .empty

        case let .httpError(code, body): classifying(httpStatus: code, body: body)

        case let .connectionFailed(reason): classifying(diagnostic: reason) ?? .connection

        case .generationTimedOut: .timedOut

        case .protocolTruncated: .truncated
        }
    }

    /// Map a thrown failure back to `ProtocolError` so `generateProtocol`'s
    /// existing catch path can log and warn without a new error case.
    func asProtocolError() -> ProtocolError {
        switch self {
        case .timedOut: .generationTimedOut(0)

        case .truncated: .protocolTruncated

        case .empty: .emptyProtocol

        case let .httpStatus(code): .httpError(code, "")

        case .chatCompletionFailed, .unauthorized, .modelUnavailable, .contextTooLong, .connection, .unknown:
            .connectionFailed(reasonLabel)
        }
    }

    static func from(reasonLabel: String) -> Self {
        let trimmed = reasonLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch trimmed {
        case "chat completion failed": return .chatCompletionFailed

        case "timeout": return .timedOut

        case "auth": return .unauthorized

        case "model unavailable": return .modelUnavailable

        case "context too long": return .contextTooLong

        case "output truncated": return .truncated

        case "empty response": return .empty

        case "connection failed": return .connection

        case "generation failed": return .unknown

        default:
            if trimmed.hasPrefix("http "), let code = Int(trimmed.dropFirst(5)) {
                return .httpStatus(code)
            }
            return classifying(diagnostic: trimmed) ?? .unknown
        }
    }

    // MARK: - Internals

    /// Only the whole notes body (or its first line) may be an error phrase.
    /// A real summary that *mentions* "timeout" must not be flagged, so this
    /// list is exact phrases servers actually write as the completion text —
    /// not the looser diagnostic matching used for thrown errors.
    private static func phraseFailure(_ text: String) -> Self? {
        let collapsed = text.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return .empty }
        if collapsed == "chat completion failed" || collapsed.hasPrefix("chat completion failed") {
            return .chatCompletionFailed
        }
        if collapsed == "completion failed" {
            return .chatCompletionFailed
        }
        return nil
    }

    private static func classifying(httpStatus code: Int, body: String) -> Self {
        if code == 401 || code == 403 { return .unauthorized }
        if code == 404 { return .modelUnavailable }
        if code == 408 || code == 504 { return .timedOut }
        if let fromBody = classifying(diagnostic: body) { return fromBody }
        return .httpStatus(code)
    }

    private static func classifying(diagnostic: String) -> Self? {
        let text = diagnostic.lowercased()
        if text.contains("chat completion failed") || text.contains("completion failed") {
            return .chatCompletionFailed
        }
        if text.contains("invalid api key") || text.contains("invalid_api_key")
            || text.contains("unauthorized") || text.contains("authentication") {
            return .unauthorized
        }
        if text.contains("model_not_found") || text.contains("model not found")
            || text.contains("unknown model")
            || (text.contains("model") && text.contains("does not exist")) {
            return .modelUnavailable
        }
        if text.contains("context length") || text.contains("context_length")
            || text.contains("maximum context") || text.contains("too many tokens")
            || text.contains("prompt is too long")
            || (text.contains("exceed") && (text.contains("context") || text.contains("token"))) {
            return .contextTooLong
        }
        if text.contains("timed out") || text.contains("timeout") {
            return .timedOut
        }
        if text.contains("overloaded") || text.contains("model is currently unavailable") {
            return .modelUnavailable
        }
        return nil
    }
}
