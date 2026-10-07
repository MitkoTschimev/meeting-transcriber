import Foundation

extension WatchingController {
    /// Open (or retitle) the notes session for the recording that just started
    /// and, once per session, bring the notes window forward. Title comes from
    /// the loop's published meeting identity so the window names the same
    /// meeting the job will.
    ///
    /// The window post is gated on `AppSettings.autoOpenMeetingNotes` and on
    /// `MeetingNotesSession.didAutoOpenWindow`. A second `.recording`
    /// transition, a live-caption retitle, or the user closing Notes
    /// mid-meeting must not spam the window back open. The session itself
    /// still begins so the transcript has somewhere to land.
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
        guard MeetingNotesAutoOpen.shouldPresent(
            enabled: settings.autoOpenMeetingNotes,
            alreadyPresentedForSession: meetingNotes.didAutoOpenWindow,
        ) else { return }
        meetingNotes.markWindowAutoOpened()
        presentMeetingNotes()
    }
}
