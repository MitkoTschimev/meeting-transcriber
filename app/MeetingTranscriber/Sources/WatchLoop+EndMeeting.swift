import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WatchLoop")

/// Why `WatchLoop.waitForMeetingEnd` returned.
enum MeetingEndReason: Equatable {
    /// The detector reported the meeting inactive for the full end grace.
    case signalEnded
    /// The recording hit `maxDuration`.
    case maxDuration
    /// The detector still reported a call, but neither channel carried
    /// audible audio for `callAudioIdleTimeout` (see
    /// `WatchLoop.usesCallAudioIdleBackstop`).
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

    /// How long a parked identity stays skipped while its detector signal
    /// remains up. After this, detection re-arms so a second conversation in
    /// the same always-on app (Gather still in the office) is recorded.
    nonisolated static let parkedIdentityTTL: TimeInterval = 30 * 60

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

    /// Whether the silence backstop applies to a meeting. Only synthesised
    /// identities that auto-record (custom watch apps, Electron hosts such as
    /// Gather): their signal is the generic WebRTC assertion / mic use, which
    /// an always-on app holds outside calls. Built-in apps (Teams, Zoom, …)
    /// have call-scoped signals. Browser meetings (consent-gated) drop WebRTC
    /// when the call ends, and one-sided presenting is common there, so
    /// silence must not end them.
    static func usesCallAudioIdleBackstop(_ meeting: DetectedMeeting) -> Bool {
        AppMeetingPattern.forAppName(meeting.pattern.appName) == nil
            && !meeting.pattern.requiresRecordingConsent
    }

    /// Classify whether the recording still has a live call, from mic *and*
    /// app levels plus tap health. No recorder, or a tap that cannot judge,
    /// is `.unknown` so a broken tap never ends a meeting that may be running.
    func currentCallActivity() -> CallActivity {
        guard let sample = currentCallSample() else { return .unknown }
        return CallActivityPolicy.classify(sample)
    }

    func currentCallSample() -> CallActivitySample? {
        guard let recorder = activeRecorder else { return nil }
        return CallActivitySample(
            appLevelDBFS: recorder.appLevelDBFS,
            micLevelDBFS: recorder.micLevelDBFS,
            appCaptureGaveUp: recorder.appCaptureGaveUp,
            appSilentTrackWatchdogGaveUp: recorder.appSilentTrackWatchdogGaveUp,
            secondsSinceLastAppBuffer: recorder.appSignalAges.secondsSinceLastBuffer,
        )
    }

    /// Identities detection skips this poll. Empty once parking has expired
    /// even if the detector signal is still up, so a later conversation in
    /// the same always-on app is recorded.
    var ignoredIdentities: Set<String> {
        guard let parkedMeeting, !parkedIdentityHasExpired else { return [] }
        return [parkedMeeting.pattern.appName]
    }

    var parkedIdentityHasExpired: Bool {
        guard !parkedUntilSignalDrops else { return false }
        guard let parkedAt else { return parkedMeeting != nil }
        return nowProvider().timeIntervalSince(parkedAt) >= Self.parkedIdentityTTL
    }

    /// Park a meeting that ended while its detector still reported it, so the
    /// next poll does not record it again.
    ///
    /// User Stop parks every app (Teams, Zoom, browsers included): the user
    /// asked to end this recording, and restarting ~6 s later (and re-prompting
    /// browsers) is wrong. Idle-audio parking stays limited to always-on apps
    /// whose signal outlives the call; built-in clients drop theirs.
    func parkIfEndedEarly(_ meeting: DetectedMeeting, reason: MeetingEndReason) {
        switch reason {
        case .userStopped:
            // Always-on apps keep the 30 min cap so a later Gather conversation
            // is recorded. Teams/Zoom/browsers stay parked until the call
            // signal drops — a TTL would restart a call the user stopped.
            parkWhileStillSignalling(
                meeting,
                untilSignalDrops: !Self.usesCallAudioIdleBackstop(meeting),
            )

        case .callAudioIdle:
            guard Self.usesCallAudioIdleBackstop(meeting) else { return }
            parkWhileStillSignalling(meeting, untilSignalDrops: false)

        case .signalEnded, .maxDuration, .cancelled:
            return
        }
    }

    private func parkWhileStillSignalling(_ meeting: DetectedMeeting, untilSignalDrops: Bool) {
        guard detector.isMeetingActive(meeting) else { return }
        parkedMeeting = meeting
        parkedAt = nowProvider()
        parkedUntilSignalDrops = untilSignalDrops
        if untilSignalDrops {
            logger.info(
                "\(meeting.pattern.appName, privacy: .public) still reports a call after Stop; not re-detecting it until that signal drops",
            )
        } else {
            logger.info(
                "\(meeting.pattern.appName, privacy: .public) still reports a call after the recording ended; not re-detecting it until that signal drops or \(Int(Self.parkedIdentityTTL / 60)) min pass",
            )
        }
    }

    /// Drop an idle-backstop recording that never heard anyone. After parking
    /// expires, an always-on app would otherwise enqueue ~5 min of silence
    /// every 30 min. Typed notes keep the recording. Audio is moved to Trash
    /// rather than unlinked, so it can be recovered.
    func discardSilentIdleRecordingIfNeeded(reason: MeetingEndReason, recording: RecordingResult) -> Bool {
        guard reason == .callAudioIdle, !heardCallAudioDuringRecording else { return false }
        if hasTypedNotes() {
            logger.info("Keeping a silent idle recording because the user typed notes")
            return false
        }
        logger.info("Moving a recording that never heard any call audio to Trash")
        discardedSilentIdleRecording = true
        let files = [recording.mixPath] + [recording.appPath, recording.micPath].compactMap(\.self)
        for url in files where RecordingFileGuard.isInside(url, directory: AppPaths.recordingsDir) {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                logger.error("Could not move silent recording to Trash: \(error.localizedDescription, privacy: .public)")
            }
        }
        notifier.notify(
            title: "Silent recording discarded",
            body: "Nothing was heard, so the audio was moved to Trash.",
            urgency: .standard,
        )
        return true
    }

    /// Release the parked meeting once its detector signal is gone, or (for
    /// always-on apps) the parking TTL has elapsed.
    func releaseParkedMeetingIfEnded() {
        guard let parked = parkedMeeting else { return }
        let expired = parkedIdentityHasExpired
        guard expired || !detector.isMeetingActive(parked) else { return }
        parkedMeeting = nil
        parkedAt = nil
        parkedUntilSignalDrops = false
        if expired {
            logger.info(
                "\(parked.pattern.appName, privacy: .public) parking expired; detecting it again",
            )
        } else {
            logger.info(
                "\(parked.pattern.appName, privacy: .public) call signal ended; detecting it again",
            )
        }
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

    /// Classify this poll, fall unknown back to quiet after the fallback, and
    /// record sustained activity. Returns the activity the idle timer should see.
    func noteCallActivity(
        sample: CallActivitySample?,
        now: Date,
        unknownSince: inout Date?,
        micSpeechPolls: inout Int,
        lastCallAudioAt: inout Date?,
    ) -> CallActivity {
        var activity = sample.map(CallActivityPolicy.classify) ?? .unknown
        if activity == .unknown {
            let started = unknownSince ?? now
            unknownSince = started
            activity = CallActivityPolicy.resolvingUnknown(
                activity,
                unknownDuration: now.timeIntervalSince(started),
            )
        } else {
            unknownSince = nil
        }
        switch activity {
        case .heard:
            if let sample, CallActivityPolicy.heardFromApp(sample) {
                lastCallAudioAt = now
                heardCallAudioDuringRecording = true
                micSpeechPolls = 0
            } else {
                micSpeechPolls += 1
                if micSpeechPolls >= CallActivityPolicy.micSpeechSustainPolls {
                    lastCallAudioAt = now
                    heardCallAudioDuringRecording = true
                }
            }

        case .quiet, .unknown:
            micSpeechPolls = 0
        }
        return activity
    }

    @discardableResult
    func waitForMeetingEnd(_ meeting: DetectedMeeting) async throws -> MeetingEndReason {
        var graceStart: Date?
        var lastCallAudioAt: Date?
        var unknownSince: Date?
        var micSpeechPolls = 0
        heardCallAudioDuringRecording = false
        discardedSilentIdleRecording = false
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
            let sample = currentCallSample()
            let activity = noteCallActivity(
                sample: sample,
                now: now,
                unknownSince: &unknownSince,
                micSpeechPolls: &micSpeechPolls,
                lastCallAudioAt: &lastCallAudioAt,
            )
            let decision = WatchLoopEndPolicy.step(
                config: config,
                now: now,
                startTime: startTime,
                graceStart: graceStart,
                meetingActive: detector.isMeetingActive(meeting),
                lastCallAudioAt: lastCallAudioAt,
                callActivityKnown: activity != .unknown,
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
