import SwiftUI

enum MeetingNotesTab: String, CaseIterable, Identifiable {
    case transcript
    case summary

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .transcript: "Transcript"
        case .summary: "Summary"
        }
    }
}

/// Dedicated meeting-notes window: live transcript plus action-item notes.
///
/// Layout is modelled on a notes-app meeting page (title, timestamp, two tabs,
/// generating placeholder) rather than the menu-bar popover. Branding and
/// assets of any third-party app are not used.
struct MeetingNotesView: View {
    @Bindable var session: MeetingNotesSession
    @Bindable var settings: AppSettings
    @Bindable var queue: PipelineQueue
    let liveTranscriptionEnabled: Bool

    @State private var tab: MeetingNotesTab

    init(
        session: MeetingNotesSession,
        settings: AppSettings,
        queue: PipelineQueue,
        liveTranscriptionEnabled: Bool,
        initialTab: MeetingNotesTab = .transcript,
    ) {
        self.session = session
        self.settings = settings
        self.queue = queue
        self.liveTranscriptionEnabled = liveTranscriptionEnabled
        _tab = State(initialValue: initialTab)
    }

    static let liveTranscriptionHint =
        "Enable live transcription in Settings → Transcribe to see the transcript "
            + "while recording. The full transcript still appears here after the meeting is processed."

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            Divider()
            tabContent
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { session.sync(from: queue) }
        .onChange(of: jobSignature) { _, _ in
            session.sync(from: queue)
        }
        .onChange(of: session.phase) { _, phase in
            if phase == .generatingNotes || phase == .ready {
                tab = .summary
            }
        }
    }

    /// Cheap identity for pipeline ticks: job id + state + artefact paths.
    private var jobSignature: String {
        queue.jobs.map { job in
            "\(job.id.uuidString):\(job.state.rawValue):\(job.transcriptPath?.path ?? ""):\(job.protocolPath?.path ?? "")"
        }.joined(separator: "|")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.displayTitle)
                .font(.system(.largeTitle, design: .serif))
                .fontWeight(.regular)
                .accessibilityIdentifier(A11yID.meetingNotesTitle)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 8) {
                    if session.phase == .recording {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                            .accessibilityLabel("Recording")
                    }
                    Text(timestampLine(now: context.date))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    private var tabBar: some View {
        HStack(spacing: 20) {
            ForEach(MeetingNotesTab.allCases) { item in
                tabButton(item)
            }
            Spacer()
            if tab == .summary {
                Picker("Notes style", selection: $settings.protocolStyle) {
                    ForEach(ProtocolStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier(A11yID.meetingNotesStylePicker)
                .disabled(settings.recordOnly)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 4)
    }

    private func tabButton(_ item: MeetingNotesTab) -> some View {
        Button {
            tab = item
        } label: {
            VStack(spacing: 6) {
                Text(item.label)
                    .font(.body)
                    .fontWeight(tab == item ? .semibold : .regular)
                    .foregroundStyle(tab == item ? Color.primary : Color.secondary)
                Rectangle()
                    .fill(tab == item ? Color.primary : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(item == .transcript ? A11yID.meetingNotesTranscriptTab : A11yID.meetingNotesSummaryTab)
        .accessibilityAddTraits(tab == item ? .isSelected : [])
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .transcript:
            transcriptPane

        case .summary:
            summaryPane
        }
    }

    private var transcriptPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if session.hasTranscript {
                        Text(session.transcriptText)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 24)
                            .id("transcript-end")
                    } else {
                        transcriptEmpty
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 20)
            }
            .onChange(of: session.lines.count) { _, _ in
                proxy.scrollTo("transcript-end", anchor: .bottom)
            }
            .onChange(of: session.hypothesisMic) { _, _ in
                proxy.scrollTo("transcript-end", anchor: .bottom)
            }
            .onChange(of: session.hypothesisApp) { _, _ in
                proxy.scrollTo("transcript-end", anchor: .bottom)
            }
        }
        .accessibilityIdentifier(A11yID.meetingNotesTranscript)
    }

    private var transcriptEmpty: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.phase == .recording {
                if liveTranscriptionEnabled {
                    Text("Listening… the transcript appears here as people speak.")
                } else {
                    Text(Self.liveTranscriptionHint)
                }
            } else if session.phase == .processing {
                Text("Transcribing the recording…")
            } else {
                Text("No transcript yet. Start a recording, or process an audio file, to fill this page.")
            }
        }
        .font(.body)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
    }

    private var summaryPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if session.phase == .generatingNotes {
                    NotesGeneratingPlaceholder(style: settings.protocolStyle)
                } else if let notes = session.notesMarkdown, !notes.isEmpty {
                    notesBody(notes)
                } else if session.phase == .failed {
                    Text(session.errorMessage ?? "Notes could not be generated. The transcript was saved.")
                        .foregroundStyle(.red)
                } else {
                    draftOrWaiting
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier(A11yID.meetingNotesSummary)
    }

    @ViewBuilder private var draftOrWaiting: some View {
        let drafts = session.draftActionItems
        if session.phase == .recording || session.phase == .processing, !drafts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Likely action items")
                    .font(.headline)
                Text(
                    "Drafted from the live transcript. Generated notes in the \(settings.protocolStyle.label.lowercased()) style replace this after the meeting is processed.",
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                ForEach(Array(drafts.enumerated()), id: \.offset) { _, item in
                    Text("• \(item)")
                        .textSelection(.enabled)
                }
            }
        } else if session.phase == .recording {
            Text("Notes in the \(settings.protocolStyle.label.lowercased()) style appear here as the meeting is processed.")
                .foregroundStyle(.secondary)
        } else if session.phase == .processing {
            NotesGeneratingPlaceholder(style: settings.protocolStyle)
        } else if settings.protocolProvider == .none {
            Text("Notes are off — set an LLM provider in Settings → Output to generate a summary.")
                .foregroundStyle(.secondary)
        } else {
            Text("No notes yet.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func notesBody(_ markdown: String) -> some View {
        if let attributed = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace),
        ) {
            Text(attributed)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(markdown)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func timestampLine(now: Date) -> String {
        var parts: [String] = []
        if let startedAt = session.startedAt {
            parts.append(formattedMeetingTimestamp(startedAt))
            let seconds = session.duration(at: now)
            if seconds >= 1 {
                parts.append(formattedTime(seconds))
            }
        }
        if !session.appName.isEmpty {
            parts.append(session.appName)
        }
        return parts.joined(separator: "  ·  ")
    }
}

/// Skeleton + caption shown while notes are being written, including the
/// post-recording protocol-generation stage.
struct NotesGeneratingPlaceholder: View {
    let style: ProtocolStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "sparkle")
                    .foregroundStyle(.secondary)
                Text("Turning this meeting into \(style.progressCaption)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Notes")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

            skeletonBar(width: 0.55)
            skeletonBar(width: 0.92)
            skeletonBar(width: 0.78)
            skeletonBar(width: 0.40)
                .padding(.top, 8)
            skeletonBar(width: 0.88)
            skeletonBar(width: 0.70)
        }
        .accessibilityIdentifier(A11yID.meetingNotesGenerating)
    }

    private func skeletonBar(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.primary.opacity(0.08))
            .frame(height: 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, (1 - width) * 280)
    }
}

func formattedMeetingTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}
