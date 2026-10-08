import SwiftUI

/// Destructive Stop in the Meeting Notes header. ⌘. (and a click) arms a
/// confirm rather than ending immediately: the shortcut fires even while
/// the thoughts editor has focus, and an accidental press would otherwise
/// finalize the recording with no undo. A second press (or Confirm Stop)
/// finalizes; Keep Recording backs out. Confirm disarms on its own after
/// `confirmTimeout` so a forgotten arm does not sit waiting for a second press.
struct MeetingNotesStopButton: View {
    static let confirmTimeout: TimeInterval = 5

    let onStop: () -> Void
    var confirmTimeout: TimeInterval = Self.confirmTimeout
    private let externalConfirm: Binding<Bool>?
    @State private var internalConfirm = false

    init(
        onStop: @escaping () -> Void,
        confirmStop: Binding<Bool>? = nil,
        confirmTimeout: TimeInterval = Self.confirmTimeout,
    ) {
        self.onStop = onStop
        externalConfirm = confirmStop
        self.confirmTimeout = confirmTimeout
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
        .task(id: confirmStop.wrappedValue) {
            guard confirmStop.wrappedValue else { return }
            await Self.disarmIfStillArmed(
                timeout: confirmTimeout,
                isStillArmed: { confirmStop.wrappedValue },
                disarm: { confirmStop.wrappedValue = false },
            )
        }
    }

    /// Wait `timeout`, then drop the confirm arm unless the user already
    /// confirmed or chose Keep Recording.
    static func disarmIfStillArmed(
        timeout: TimeInterval,
        sleep: (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        isStillArmed: () -> Bool,
        disarm: () -> Void,
    ) async {
        await sleep(timeout)
        if isStillArmed() { disarm() }
    }
}
