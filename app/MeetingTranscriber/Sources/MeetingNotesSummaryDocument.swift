import SwiftUI

/// How generated notes are shown. Preview is the default; Source is the raw
/// Markdown for copying. Notes are not editable — the protocol file is the
/// source of truth, same as before this renderer existed.
enum NotesMarkdownMode: String, CaseIterable, Identifiable {
    case preview
    case source

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .preview: "Preview"
        case .source: "Source"
        }
    }
}

/// Rendered (or raw) notes body plus a collapsed Full Transcript appendix.
struct MeetingNotesSummaryDocument: View {
    let markdown: String

    @State private var mode: NotesMarkdownMode
    @State private var showingTranscript: Bool

    init(
        markdown: String,
        initialMode: NotesMarkdownMode = .preview,
        transcriptExpanded: Bool = false,
    ) {
        self.markdown = markdown
        _mode = State(initialValue: initialMode)
        _showingTranscript = State(initialValue: transcriptExpanded)
    }

    var body: some View {
        let split = NotesMarkdownSplit.parse(markdown)
        VStack(alignment: .leading, spacing: 16) {
            modePicker
            notesBody(split.notes)
            if let transcript = split.transcript {
                transcriptDisclosure(transcript)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modePicker: some View {
        Picker("Notes display", selection: $mode) {
            ForEach(NotesMarkdownMode.allCases) { item in
                Text(item.label).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .accessibilityIdentifier(A11yID.meetingNotesDisplayMode)
    }

    @ViewBuilder
    private func notesBody(_ notes: String) -> some View {
        switch mode {
        case .preview:
            NotesMarkdownView(markdown: notes)

        case .source:
            Text(notes)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(A11yID.meetingNotesMarkdownSource)
        }
    }

    private func transcriptDisclosure(_ transcript: String) -> some View {
        DisclosureGroup("Full Transcript", isExpanded: $showingTranscript) {
            if showingTranscript {
                NotesTranscriptAppendix(text: transcript)
            }
        }
        .accessibilityIdentifier(A11yID.meetingNotesFullTranscriptDisclosure)
    }
}

/// Timestamped speech from the protocol appendix, one line per row so a long
/// meeting stays lazy. Built only while the disclosure is open.
struct NotesTranscriptAppendix: View {
    let text: String

    var body: some View {
        let rows = Self.rows(from: text)
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                Text(row.text.isEmpty ? " " : row.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 8)
        .accessibilityIdentifier(A11yID.meetingNotesFullTranscript)
    }

    struct Row: Identifiable {
        let id: Int
        let text: String
    }

    static func rows(from text: String) -> [Row] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { Row(id: $0.offset, text: String($0.element)) }
    }
}
