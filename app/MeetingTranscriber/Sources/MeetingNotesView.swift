import SwiftUI

enum MeetingNotesTab: String, CaseIterable, Identifiable {
    case thoughts
    case transcript
    case summary

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .thoughts: "My thoughts"
        case .transcript: "Transcript"
        case .summary: "Summary"
        }
    }

    var accessibilityID: String {
        switch self {
        case .thoughts: A11yID.meetingNotesThoughtsTab
        case .transcript: A11yID.meetingNotesTranscriptTab
        case .summary: A11yID.meetingNotesSummaryTab
        }
    }
}

/// Dedicated meeting-notes window: private scratchpad, live transcript, and
/// action-item notes. Layout is modelled on a notes-app meeting page (title,
/// timestamp, tabs). Branding and assets of any third-party app are not used.
struct MeetingNotesView: View {
    @Bindable var session: MeetingNotesSession
    @Bindable var settings: AppSettings
    @Bindable var queue: PipelineQueue
    let liveTranscriptionEnabled: Bool

    @State private var tab: MeetingNotesTab
    @State private var userPickedTab: Bool

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
        _userPickedTab = State(initialValue: initialTab != .transcript)
    }

    /// Auto-switch to Summary only from the default Transcript tab when the
    /// user has not picked a tab themselves. My thoughts and an explicit
    /// Transcript choice stay put.
    static func tabAfterPhaseChange(
        phase: MeetingNotesPhase,
        current: MeetingNotesTab,
        userPickedTab: Bool,
    ) -> MeetingNotesTab {
        guard phase == .generatingNotes || phase == .ready else { return current }
        guard !userPickedTab, current == .transcript else { return current }
        return .summary
    }

    static let liveTranscriptionHint =
        "Enable live transcription in Settings → Transcribe to see the transcript "
            + "while recording. The full transcript still appears here after the meeting is processed."

    static let thoughtsPrivacyHint =
        "My thoughts are private local notes — they are not included in transcripts, summaries, or protocol files."

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            Divider()
            tabContent
            MeetingNotesAskBar()
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            session.setMicLabel(micLabel)
            session.sync(from: queue)
        }
        .onChange(of: jobSignature) { _, _ in
            session.sync(from: queue)
        }
        .onChange(of: session.phase) { _, phase in
            tab = Self.tabAfterPhaseChange(
                phase: phase,
                current: tab,
                userPickedTab: userPickedTab,
            )
        }
    }

    /// Cheap identity for pipeline ticks: job id + state + artefact paths.
    private var jobSignature: String {
        queue.jobs.map { job in
            "\(job.id.uuidString):\(job.state.rawValue):\(job.transcriptPath?.path ?? ""):\(job.protocolPath?.path ?? "")"
        }.joined(separator: "|")
    }

    private var micLabel: String {
        settings.micName.isEmpty ? "Me" : settings.micName
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
                VStack(alignment: .trailing, spacing: 2) {
                    Picker("Notes style", selection: $settings.protocolStyle) {
                        ForEach(ProtocolStyle.allCases, id: \.self) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityIdentifier(A11yID.meetingNotesStylePicker)
                    .disabled(settings.recordOnly || notesExist)
                    if notesExist {
                        Text("applies to next meeting")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 4)
    }

    private var notesExist: Bool {
        if let notes = session.notesMarkdown, !notes.isEmpty { return true }
        return false
    }

    private func tabButton(_ item: MeetingNotesTab) -> some View {
        Button {
            userPickedTab = true
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
        .accessibilityIdentifier(item.accessibilityID)
        .accessibilityAddTraits(tab == item ? .isSelected : [])
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .thoughts:
            thoughtsPane

        case .transcript:
            transcriptPane

        case .summary:
            summaryPane
        }
    }

    private var thoughtsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.thoughtsPrivacyHint)
                .font(.callout)
                .foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                if session.thoughts.isEmpty {
                    Text("Write privately…")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 4)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $session.thoughts)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.leading, -4)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier(A11yID.meetingNotesThoughts)
    }

    private var transcriptPane: some View {
        let turns = session.turns(micLabel: micLabel)
        return MeetingNotesTranscriptPane(
            turns: turns,
            palette: session.palette(for: turns, micLabel: micLabel),
            micLabel: micLabel,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            liveTranscriptionEnabled: liveTranscriptionEnabled,
            phase: session.phase,
            emptyHint: liveTranscriptionEnabled
                ? "Listening… the transcript appears here as people speak."
                : Self.liveTranscriptionHint,
        )
    }

    private var summaryPane: some View {
        let turns = session.turns(micLabel: micLabel)
        let palette = session.palette(for: turns, micLabel: micLabel)
        let mentions = SpeakerMentionText.mentions(from: turns, palette: palette, micLabel: micLabel)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !session.warnings.isEmpty {
                    ForEach(session.warnings, id: \.self) { warning in
                        Text(warning)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if session.phase == .generatingNotes {
                    NotesGeneratingPlaceholder(style: settings.protocolStyle)
                } else if let notes = session.notesMarkdown, !notes.isEmpty {
                    SpeakerMentionText(markdown: notes, mentions: mentions)
                } else if session.phase == .failed {
                    Text(session.errorMessage ?? "Notes could not be generated. The transcript was saved.")
                        .foregroundStyle(.red)
                } else {
                    draftOrWaiting(mentions: mentions)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier(A11yID.meetingNotesSummary)
    }

    @ViewBuilder
    private func draftOrWaiting(mentions: [SpeakerMentionText.Mention]) -> some View {
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
                ForEach(drafts, id: \.self) { item in
                    SpeakerMentionText(markdown: "• \(item)", mentions: mentions)
                }
            }
        } else if session.phase == .recording {
            Text("Notes in the \(settings.protocolStyle.label.lowercased()) style appear here as the meeting is processed.")
                .foregroundStyle(.secondary)
        } else if session.phase == .processing {
            NotesGeneratingPlaceholder(style: settings.protocolStyle)
        } else if settings.recordOnly {
            Text("Record-only is on — notes are not generated.")
                .foregroundStyle(.secondary)
        } else if settings.protocolProvider == .none {
            Text("Notes are off — set an LLM provider in Settings → Output to generate a summary.")
                .foregroundStyle(.secondary)
        } else {
            Text("No notes yet.")
                .foregroundStyle(.secondary)
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

/// Disabled layout stub. Ask-anything chat is out of this slice.
struct MeetingNotesAskBar: View {
    var body: some View {
        HStack {
            Text("Ask anything")
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .accessibilityLabel("Ask anything is not available yet")
        .accessibilityIdentifier(A11yID.meetingNotesAskBar)
        .allowsHitTesting(false)
    }
}

func formattedMeetingTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}
