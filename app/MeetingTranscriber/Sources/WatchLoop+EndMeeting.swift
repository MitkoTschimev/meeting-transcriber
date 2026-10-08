import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WatchLoop")

/// Why `WatchLoop.waitForMeetingEnd` returned.
enum MeetingEndReason: Equatable {
    /// The detector reported the meeting inactive for the full end grace.
    case signalEnded
    /// The recording hit `maxDuration`.
    case maxDuration
    /// The detector still reported a call, but the call channel stayed silent
    /// for `callAudioIdleTimeout` (see `WatchLoop.usesCallAudioIdleBackstop`).
    case callAudioIdle
    /// The user pressed Stop (menu bar or Meeting Notes window).
    case userStopped
    /// The watch task was cancelled (Stop Watching, manual start, quit).
    case cancelled
}

/// Ending an auto-detected meeting before its detector signal drops: the
/// user's Stop button, and the silence backstop for apps whose signal outlives
/// the call. Both "park" the meeting so detection does not immediately start
/// a new recording of the very same, still-signalling app.
///
/// Why this exists (Gather, a custom watch app since #4): an Electron office
/// app holds the "WebRTC has active PeerConnections" assertion, and keeps the
/// microphone open, for as long as you are in the space, not just while you
/// are in a conversation. Both signals stay up after the call ends, so
/// `isMeetingActive` never went false, the end grace never started, and the
/// recording ran until `maxDuration` (4 h). The detector cannot tell "in a
/// call" from "in the app", so the call audio itself has to.
extension WatchLoop {
    /// Default silence window for the backstop. Long enough that a pause, a
    /// screen-share without narration or a quiet stretch in a real call does
    /// not end it; short enough that a forgotten recording stops on its own.
    nonisolated static let defaultCallAudioIdleTimeout: TimeInterval = 300

    /// App-channel level at or above which the call channel counts as
    /// carrying call audio. Speech through a call app sits around -30 to
    /// -20 dBFS; an idle WebRTC stream and comfort noise sit well below -60.
    nonisolated static let callAudioAudibleThresholdDBFS: Double = -50

    /// Whether an auto-detected meeting (not a manual recording) is recording,
    /// i.e. whether `endCurrentMeeting()` has anything to end.
    var isRecordingDetectedMeeting: Bool {
        state == .recording && manualRecordingInfo == nil && currentMeeting != nil
    }

    /// End the auto-detected meeting that is recording now, keep watching.
    /// The recording is finalized and enqueued exactly as on a natural end;
    /// the poller is woken so this takes effect at once, not a poll later.
    func endCurrentMeeting() {
        guard isRecordingDetectedMeeting, !endRequested else { return }
        endRequested = true
        endPollSleeper?.cancel()
        logger.info("Stop requested for the detected meeting")
    }

    /// Whether the silence backstop applies to a meeting. Only identities
    /// synthesised for apps the detector does not know (custom watch apps,
    /// Electron hosts, browser processes): their signal is the generic WebRTC
    /// assertion / mic use, which an always-on app holds outside calls. The
    /// built-in apps (Teams, Zoom, Webex, FaceTime, ...) have call-scoped
    /// signals and keep ending on those alone.
    static func usesCallAudioIdleBackstop(_ meeting: DetectedMeeting) -> Bool {
        AppMeetingPattern.forAppName(meeting.pattern.appName) == nil
    }

    /// Whether the call (app-audio) channel carries audible audio right now.
    /// Answers true when it cannot judge (no recorder, or the app capture gave
    /// up), so a broken tap never ends a meeting that may well be running.
    func callAudioIsAudible() -> Bool {
        guard let recorder = activeRecorder, !recorder.appCaptureGaveUp else { return true }
        return recorder.appLevelDBFS >= Self.callAudioAudibleThresholdDBFS
    }

    /// Identities detection skips this poll.
    var ignoredIdentities: Set<String> {
        guard let parkedMeeting else { return [] }
        return [parkedMeeting.pattern.appName]
    }

    /// Park a meeting that ended while its detector still reported it, so the
    /// next poll does not record it again.
    func parkIfEndedEarly(_ meeting: DetectedMeeting, reason: MeetingEndReason) {
        switch reason {
        case .userStopped, .callAudioIdle:
            guard detector.isMeetingActive(meeting) else { return }
            parkedMeeting = meeting
            logger.info(
                "\(meeting.pattern.appName, privacy: .public) still reports a call after the recording ended; not re-detecting it until that signal drops",
            )

        case .signalEnded, .maxDuration, .cancelled:
            return
        }
    }

    /// Release the parked meeting once its detector signal is gone, so the
    /// app's next call is detected normally.
    func releaseParkedMeetingIfEnded() {
        guard let parked = parkedMeeting, !detector.isMeetingActive(parked) else { return }
        parkedMeeting = nil
        logger.info("\(parked.pattern.appName, privacy: .public) call signal ended; detecting it again")
    }

    /// Sleep one poll interval between end checks, waking early (without
    /// throwing) when `endCurrentMeeting()` cancels the sleep. A cancellation
    /// of the watch task itself still throws, as before.
    func sleepUntilNextEndPoll() async throws {
        let interval = pollInterval
        let sleeper = Task { try await self.sleepProvider(interval) }
        endPollSleeper = sleeper
        defer { endPollSleeper = nil }
        do {
            try await withTaskCancellationHandler {
                try await sleeper.value
            } onCancel: {
                sleeper.cancel()
            }
        } catch is CancellationError {
            if endRequested, !Task.isCancelled { return }
            throw CancellationError()
        }
    }

    // MARK: - Meeting End Detection

    @discardableResult
    func waitForMeetingEnd(_ meeting: DetectedMeeting) async throws -> MeetingEndReason {
        var graceStart: Date?
        var lastCallAudioAt: Date?
        let startTime = nowProvider()
        let config = WatchLoopEndConfig(
            maxDuration: maxDuration,
            endGracePeriod: endGracePeriod,
            callAudioIdleTimeout: Self.usesCallAudioIdleBackstop(meeting) ? callAudioIdleTimeout : nil,
        )

        while !Task.isCancelled {
            if endRequested {
                logger.info("Recording stopped by the user")
                return .userStopped
            }
            let now = nowProvider()
            if callAudioIsAudible() { lastCallAudioAt = now }
            let decision = WatchLoopEndPolicy.step(
                config: config,
                now: now,
                startTime: startTime,
                graceStart: graceStart,
                meetingActive: detector.isMeetingActive(meeting),
                lastCallAudioAt: lastCallAudioAt,
            )
            switch decision {
            case .stopMaxDurationExceeded:
                logger.info("Max recording duration reached (\(Int(self.maxDuration))s)")
                return .maxDuration

            case .stopGraceExpired:
                return .signalEnded

            case .stopCallAudioIdle:
                logger.info(
                    "No call audio for \(Int(self.callAudioIdleTimeout))s while \(meeting.pattern.appName, privacy: .public) still reports a call — ending the recording",
                )
                return .callAudioIdle

            case let .continuePolling(newGraceStart):
                graceStart = newGraceStart
            }
            try await sleepUntilNextEndPoll()
        }
        return .cancelled
    }
}
