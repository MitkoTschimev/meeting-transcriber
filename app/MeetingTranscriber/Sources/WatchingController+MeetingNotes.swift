import Foundation

extension WatchingController {
    /// Open (or retitle) the notes session for the recording that just started
    /// and bring the notes window forward. Title comes from the loop's published
    /// meeting identity so the window names the same meeting the job will.
    func beginMeetingNotes(from loop: WatchLoop?) {
        if let manual = loop?.manualRecordingInfo {
            meetingNotes.begin(title: manual.title, appName: manual.appName)
        } else if let meeting = loop?.currentMeeting {
            meetingNotes.begin(
                title: loop?.recordingTitle ?? WatchLoop.cleanTitle(meeting.windowTitle),
                appName: meeting.pattern.appName,
            )
        } else {
            meetingNotes.begin(title: "Meeting", appName: "")
        }
        NotificationCenter.default.post(name: .showMeetingNotes, object: nil)
    }
}
