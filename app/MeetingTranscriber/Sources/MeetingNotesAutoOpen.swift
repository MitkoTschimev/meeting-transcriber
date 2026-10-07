/// Whether the notes window should be brought forward for this recording start.
///
/// Pure so the once-per-session rule is pinned without constructing a
/// `WatchingController` or posting `Notification.Name.showMeetingNotes`.
/// The window opens at session start (auto-detected meeting or manual
/// conversation), not again while that recording is still running — including
/// after the user closed Notes mid-meeting.
enum MeetingNotesAutoOpen {
    static func shouldPresent(enabled: Bool, alreadyPresentedForSession: Bool) -> Bool {
        enabled && !alreadyPresentedForSession
    }
}
