import SwiftUI

/// Vertical transcript: speaker name in accent color above their text, no
/// chat bubbles, name omitted on continuation lines of the same turn.
/// Duration chrome ticks once a second; turns rebuild only when the caller
/// passes new `turns` (lines / hypothesis / pipeline transcript).
struct MeetingNotesTranscriptPane: View {
    let turns: [TranscriptTurn]
    let palette: SpeakerAccent.Palette
    let micLabel: String
    let startedAt: Date?
    let endedAt: Date?
    let liveTranscriptionEnabled: Bool
    let phase: MeetingNotesPhase
    let emptyHint: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !turns.isEmpty {
                        chrome
                        ForEach(turns) { turn in
                            turnBlock(turn)
                        }
                        Color.clear.frame(height: 1).id("transcript-end")
                    } else {
                        empty
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: turns.count) { _, _ in
                proxy.scrollTo("transcript-end", anchor: .bottom)
            }
        }
        .accessibilityIdentifier(A11yID.meetingNotesTranscript)
    }

    @ViewBuilder private var chrome: some View {
        if let startedAt, let endedAt {
            chromeText(duration: max(0, endedAt.timeIntervalSince(startedAt)))
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                chromeText(duration: duration(at: context.date))
            }
        }
    }

    private func chromeText(duration: TimeInterval) -> some View {
        Text(TranscriptTurn.chrome(speakerCount: palette.speakerCount, duration: duration))
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .tracking(0.6)
            .accessibilityIdentifier(A11yID.meetingNotesSpeakerChrome)
    }

    private func duration(at now: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    private func turnBlock(_ turn: TranscriptTurn) -> some View {
        let key = SpeakerAccent.identityKey(turn.speakerRaw, micLabel: micLabel, isYou: turn.isYou)
        let color = palette.color(forKey: key, isYou: turn.isYou)
        return VStack(alignment: .leading, spacing: 6) {
            if !turn.speakerRaw.isEmpty {
                Text(SpeakerAccent.displayName(turn.speakerRaw, micLabel: micLabel, isYou: turn.isYou))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(color)
            }
            ForEach(Array(turn.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.body)
                    .foregroundStyle(turn.isHypothesis ? Color.secondary : Color.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .opacity(turn.isHypothesis ? 0.75 : 1)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            if phase == .recording {
                Text(emptyHint)
            } else if phase == .processing {
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
}
