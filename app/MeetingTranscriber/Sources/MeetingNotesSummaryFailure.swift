import SwiftUI

/// Error + Retry shown on the Summary tab when notes generation failed
/// (including meetings whose saved `.md` is the literal "chat completion failed"
/// text). Kept out of `MeetingNotesView` so the notes window's other tabs stay
/// out of this change.
struct MeetingNotesSummaryFailure: View {
    static let longTranscriptHint =
        "Long meetings can exceed the model's context window. Retry splits the transcript into smaller pieces."

    let message: String
    let hint: String?
    let retryEnabled: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message)
                .foregroundStyle(.red)
                .accessibilityIdentifier(A11yID.meetingNotesSummaryError)
            if let hint, !hint.isEmpty {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if retryEnabled {
                Button("Retry", action: onRetry)
                    .accessibilityIdentifier(A11yID.meetingNotesRetryButton)
            }
        }
    }
}
