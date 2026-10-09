import Foundation

/// Generated notes plus the optional Full Transcript appendix the pipeline
/// concatenates when "include full transcript" is on.
///
/// Splitting keeps a 70-minute transcript out of the Markdown renderer: the
/// notes body is a short GFM document; the appendix is plain timestamped
/// speech and is shown collapsed / lazily instead.
///
/// The heading match is a whole line (`#{1,6} Full Transcript`),
/// case-insensitive, and uses the **last** occurrence so an LLM-written
/// `### Full Transcript` topic does not steal the appendix, and a mid-line
/// substring cannot split the document.
struct NotesMarkdownSplit: Equatable, Sendable {
    let notes: String
    let transcript: String?

    /// ATX heading whose title is "Full Transcript", any level, any case.
    static let headingPattern = #"^#{1,6}[ \t]+full[ \t]+transcript[ \t]*\r?$"#

    static func parse(_ markdown: String) -> Self {
        guard let range = lastHeadingRange(in: markdown) else {
            return Self(notes: markdown, transcript: nil)
        }
        let notes = stripTrailingRule(String(markdown[..<range.lowerBound]))
        let transcript = String(markdown[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(
            notes: notes,
            transcript: transcript.isEmpty ? nil : transcript,
        )
    }

    static func lastHeadingRange(in markdown: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(
            pattern: headingPattern,
            options: [.anchorsMatchLines, .caseInsensitive],
        ) else { return nil }
        let full = NSRange(markdown.startIndex..., in: markdown)
        guard let match = regex.matches(in: markdown, range: full).last else { return nil }
        return Range(match.range, in: markdown)
    }

    static func stripTrailingRule(_ body: String) -> String {
        var notes = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.hasSuffix("---") {
            notes = String(notes.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return notes
    }
}
