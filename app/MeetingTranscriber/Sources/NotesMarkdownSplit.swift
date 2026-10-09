import Foundation

/// Generated notes plus the optional `## Full Transcript` appendix the pipeline
/// concatenates when "include full transcript" is on.
///
/// Splitting is what keeps a 70-minute transcript out of the Markdown renderer:
/// the notes body is a short GFM document; the appendix is plain timestamped
/// speech and is shown collapsed / lazily instead.
struct NotesMarkdownSplit: Equatable, Sendable {
    let notes: String
    let transcript: String?

    static func parse(_ markdown: String) -> Self {
        let heading = ProtocolNotesFailure.fullTranscriptHeading
        guard let range = markdown.range(of: heading) else {
            return Self(notes: markdown, transcript: nil)
        }
        let notes = ProtocolNotesFailure.notesBody(from: markdown)
        let transcript = String(markdown[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(
            notes: notes,
            transcript: transcript.isEmpty ? nil : transcript,
        )
    }
}
