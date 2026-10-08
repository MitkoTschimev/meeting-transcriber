import SwiftUI

/// Destructive Stop in the Meeting Notes header. ⌘. (and a click) arms a
/// confirm rather than ending immediately: the shortcut fires even while
/// the thoughts editor has focus, and an accidental press would otherwise
/// finalize the recording with no undo. A second press (or Confirm Stop)
/// finalizes; Keep Recording backs out.
struct MeetingNotesStopButton: View {
    let onStop: () -> Void
    private let externalConfirm: Binding<Bool>?
    @State private var internalConfirm = false

    init(onStop: @escaping () -> Void, confirmStop: Binding<Bool>? = nil) {
        self.onStop = onStop
        externalConfirm = confirmStop
    }

    private var confirmStop: Binding<Bool> {
        externalConfirm ?? $internalConfirm
    }

    var body: some View {
        HStack(spacing: 8) {
            if confirmStop.wrappedValue {
                Button("Keep Recording", role: .cancel) {
                    confirmStop.wrappedValue = false
                }
                .controlSize(.large)
                .accessibilityIdentifier(A11yID.meetingNotesKeepRecordingButton)
                Button("Confirm Stop", role: .destructive, action: onStop)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("End this recording now. The transcript and notes are finalized as if the meeting had ended.")
                    .accessibilityIdentifier(A11yID.meetingNotesConfirmStopButton)
            } else {
                Button(role: .destructive) {
                    confirmStop.wrappedValue = true
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .keyboardShortcut(".", modifiers: .command)
                .help("End this recording. You will be asked to confirm.")
                .accessibilityIdentifier(A11yID.meetingNotesStopButton)
            }
        }
    }
}
