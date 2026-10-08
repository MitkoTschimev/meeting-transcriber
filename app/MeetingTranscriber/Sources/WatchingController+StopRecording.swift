import Foundation

/// One Stop for whatever is recording, shared by the menu bar and the Meeting
/// Notes window. A manual recording ends the way it always has (its dedicated
/// loop is dropped); an auto-detected meeting ends through
/// `WatchLoop.endCurrentMeeting()`, which finalizes and enqueues the recording
/// exactly as a natural meeting end does and leaves watching on.
@MainActor
extension WatchingController {
    /// Whether there is a recording a Stop press would end right now.
    var canStopRecording: Bool {
        guard let loop = watchLoop else { return false }
        return loop.isManualRecording || loop.isRecordingDetectedMeeting
    }

    /// End the current recording, manual or auto-detected. No-op when nothing
    /// is recording.
    func stopCurrentRecording() {
        guard let loop = watchLoop else { return }
        if loop.isManualRecording {
            stopManualRecording()
        } else {
            loop.endCurrentMeeting()
        }
    }
}
