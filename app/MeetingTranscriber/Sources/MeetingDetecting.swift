import CoreGraphics
import Foundation

/// Represents a detected active meeting.
struct DetectedMeeting: Equatable {
    let pattern: AppMeetingPattern
    let windowTitle: String
    let ownerName: String
    let windowPID: pid_t
    let detectedAt: Date

    init(
        pattern: AppMeetingPattern,
        windowTitle: String,
        ownerName: String,
        windowPID: pid_t,
        detectedAt: Date = Date(),
    ) {
        self.pattern = pattern
        self.windowTitle = windowTitle
        self.ownerName = ownerName
        self.windowPID = windowPID
        self.detectedAt = detectedAt
    }
}

/// Protocol for meeting detection strategies.
protocol MeetingDetecting {
    /// Single poll: check for active meetings. Returns a meeting after confirmation threshold.
    func checkOnce() -> DetectedMeeting?

    /// Single poll that never returns, nor counts towards confirming, a meeting
    /// whose identity (`pattern.appName`) is in `ignoring`. Used while a meeting
    /// that was ended early still signals (see `WatchLoop+EndMeeting`), so it
    /// cannot win every poll and starve another app's detection.
    func checkOnce(ignoring: Set<String>) -> DetectedMeeting?

    /// Check if a previously detected meeting is still active.
    func isMeetingActive(_ meeting: DetectedMeeting) -> Bool

    /// Reset confirmation counters and start cooldown for the given app.
    func reset(appName: String?)
}

extension MeetingDetecting {
    /// Fallback for detectors that do not filter natively: drop an ignored hit
    /// after the fact.
    func checkOnce(ignoring: Set<String>) -> DetectedMeeting? {
        guard let meeting = checkOnce() else { return nil }
        return ignoring.contains(meeting.pattern.appName) ? nil : meeting
    }

    // swiftlint:disable:next unused_declaration
    func reset() {
        reset(appName: nil)
    }
}
