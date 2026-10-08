import SwiftUI

/// Destructive Stop in the Meeting Notes header. ⌘. (and a click) arms a
/// confirm rather than ending immediately: the shortcut fires even while
/// the thoughts editor has focus, and an accidental press would otherwise
/// finalize the recording with no undo.
struct MeetingNotesStopButton: View {
    let onStop: () -> Void
    @State private var confirmStop = false

    var body: some View {
        Button(role: .destructive) {
            confirmStop = true
        } label: {
            Label("Stop Recording", systemImage: "stop.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
        .keyboardShortcut(".", modifiers: .command)
        .help("End this recording. You will be asked to confirm.")
        .accessibilityIdentifier(A11yID.meetingNotesStopButton)
        .confirmationDialog(
            "Stop recording?",
            isPresented: $confirmStop,
            titleVisibility: .visible,
        ) {
            Button("Stop Recording", role: .destructive) {
                onStop()
            }
            .accessibilityIdentifier(A11yID.meetingNotesConfirmStopButton)
            Button("Keep Recording", role: .cancel) {}
                .accessibilityIdentifier(A11yID.meetingNotesKeepRecordingButton)
        } message: {
            Text("The recording is finalized as if the meeting had ended. This cannot be undone.")
        }
    }
}
