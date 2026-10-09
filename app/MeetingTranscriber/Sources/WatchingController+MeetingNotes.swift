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
        let attendees = loop?.recordingAttendees ?? []
        if let manual = loop?.manualRecordingInfo {
            meetingNotes.begin(title: manual.title, appName: manual.appName, calendarAttendees: attendees)
        } else if let meeting = loop?.currentMeeting {
            meetingNotes.begin(
                title: loop?.recordingTitle ?? WatchLoop.cleanTitle(meeting.windowTitle),
                appName: meeting.pattern.appName,
                calendarAttendees: attendees,
            )
        } else {
            meetingNotes.begin(title: "Meeting", appName: "", calendarAttendees: attendees)
        }
        meetingNotes.presentWindowIfNeeded(enabled: settings.autoOpenMeetingNotes)
    }
}
