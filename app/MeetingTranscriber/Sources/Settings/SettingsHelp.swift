import AudioTapLib
import Foundation

/// Short, plain-English explanations for settings options, surfaced via ``HelpBadge``.
///
/// Kept out of the view bodies so those stay lint- and type-check-friendly
/// (no inline string literals inflating SwiftUI expression type-checking), and
/// so the help copy is auditable in one place.
enum SettingsHelp {
    static let echoCancellation =
        """
        Removes the remote voices from the microphone audio with an on-device \
        model before it is transcribed. Because it works on the audio rather \
        than on the text, the cleaned track is also what speaker detection \
        sees.

        The saved recording is not changed: what is kept on disk stays the \
        audio your devices captured. Only runs on recordings already reported \
        as affected, and replaces the transcript option below wherever both \
        are on.
        """

    static let echoDedup =
        """
        When a meeting is held on loudspeakers, the microphone picks the remote \
        voices up as well and they are transcribed twice. With this on, the \
        second copy is left out of the transcript.

        Only applies to recordings already reported as affected, and only the \
        written transcript is shortened: nothing is removed from the recording.

        It is not exact, which is why it is off: a quiet remark you make while \
        the far end is talking can be taken for part of the echo and left out \
        of the transcript.
        """

    static let vad =
        "Voice Activity Detection trims silent stretches out of the recording before " +
        "transcription, which speeds up processing and can improve accuracy. Enable it " +
        "for long or pause-heavy recordings; disable it if you notice speech being cut off."

    static let silentCaptureChannel =
        "Turns the menu bar red when one capture channel goes silent while the other " +
        "still carries audio, for example a muted microphone or a dropped app-audio tap. " +
        "You are notified only when a channel actually stops delivering audio, not when " +
        "it is merely quiet, so muting yourself is not reported as a fault. Turning this " +
        "off removes the colour, not the warnings: a channel that stops delivering is " +
        "still reported."

    static let silentTrackWatchdog =
        """
        When the app-audio track has carried only silence for \
        \(Int(SilentTrackWatchdogLimits.secondsOfZerosBeforeRebuild)) seconds while the \
        meeting app still reports playing audio, rebuild the capture, at most \
        once every \(Int(SilentTrackWatchdogLimits.secondsBetweenRebuilds)) seconds \
        and \(SilentTrackWatchdogLimits.rebuildsPerRecording) times per recording. \
        After \(SilentTrackWatchdogLimits.rebuildsWithoutSignal) rebuilds that do \
        not bring the audio back it stops, and tells you once your microphone \
        shows the call is live.

        Off by default because it is not yet known to help: each rebuild loses \
        at least half a second of audio, and a far end that is genuinely silent looks \
        the same. Every attempt is written to the diagnostic log, which is what \
        a report about a silent app track needs.
        """

    static let customWatchApps =
        """
        Start Watching must be on. Recording starts when an added app stays in a \
        call for a few seconds — microphone busy, or an in-call WebRTC connection \
        if Browser Web Meetings is on. Screen Recording permission is needed to \
        capture the other participants.
        """

    static let autoOpenMeetingNotes =
        """
        Opens the Meeting Notes window once when recording starts — from a \
        detected meeting or a manual microphone / app conversation. Closing \
        the window mid-meeting does not reopen it. The next session opens it \
        again.
        """

    static let appleCalendar =
        """
        Uses the macOS Calendar app (EventKit): iCloud, local calendars, and any \
        Google or Exchange accounts already added there. Turning this on asks macOS \
        for Calendar access. Upcoming events can fill in a meeting title when a \
        recording starts, and show today's agenda in Meeting Notes.
        """

    static let googleCalendar =
        """
        Connects a Google account directly with OAuth (not through Calendar.app). \
        Tokens are stored in the Keychain. Create a Desktop OAuth client ID in \
        Google Cloud Console and register the loopback redirect URI \
        http://127.0.0.1 (any port; the app binds one at connect time). Paste \
        the client ID here, then click Connect. The app only requests read-only \
        calendar access.
        """

    static let asymmetricSilenceWarning =
        "How long the condition must last before the indicator turns red and, for a channel " +
        "that has stopped delivering, before you are notified. Lower reacts faster to a dead " +
        "channel; higher ignores natural speaking pauses."
}
