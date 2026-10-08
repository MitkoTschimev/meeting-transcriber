import Foundation

/// Decision returned by `WatchLoopEndPolicy.step` on each poll of
/// `WatchLoop.waitForMeetingEnd`.
enum WatchLoopEndDecision: Equatable {
    /// Continue polling. The returned `graceStart` is the value the caller
    /// should hold until the next poll: `nil` when the meeting is currently
    /// active (grace cleared), the original value when grace is still
    /// running, or `now` when a fresh grace window just started.
    case continuePolling(graceStart: Date?)
    /// Stop because the recording has exceeded its maximum duration. The
    /// caller is responsible for logging this case if it wants to.
    case stopMaxDurationExceeded
    /// Stop because the meeting has been inactive for the full grace
    /// period — the meeting is definitively over.
    case stopGraceExpired
    /// Stop because the detector signal is still up but neither channel has
    /// carried audible audio for `callAudioIdleTimeout`. Only reachable for
    /// meetings whose detector signal is known to outlive the call (see
    /// `WatchLoop.usesCallAudioIdleBackstop`).
    case stopCallAudioIdle
}

/// Evidence that a still-signalling meeting is actually still a call, from
/// capture levels and tap health rather than the detector (whose signal can
/// outlive the conversation).
enum CallActivity: Equatable {
    /// Mic or app channel is carrying speech.
    case heard
    /// Both channels are quiet and the app tap is still delivering buffers.
    case quiet
    /// The app tap cannot say whether anyone is talking (gave up, stalled, or
    /// the silent-track watchdog stopped rebuilding) and the mic is not
    /// speaking either. Idle must not fire: a broken tap is not an ended call.
    case unknown
}

/// Instantaneous capture snapshot `CallActivityPolicy` classifies. Mirrors the
/// recorder fields the end poller already reads, so the decision is
/// unit-testable without a `RecordingProvider`.
struct CallActivitySample: Equatable {
    var appLevelDBFS: Double
    var micLevelDBFS: Double
    var appCaptureGaveUp: Bool = false
    var appSilentTrackWatchdogGaveUp: Bool = false
    /// `nil` means no buffer has ever arrived, which is not "quiet" — it is
    /// a tap that never started.
    var secondsSinceLastAppBuffer: Double? = 0
}

/// Pure classification of whether the recording still has a live call.
enum CallActivityPolicy {
    /// Speech through a call app sits around -30 to -20 dBFS; idle WebRTC
    /// and comfort noise sit well below -60.
    static let appAudibleThresholdDBFS: Double = -50
    /// A presenter talking into the mic while everyone else is muted. A
    /// slightly higher floor than the app channel, so office ambience does
    /// not keep a finished Gather recording alive.
    static let micSpeechThresholdDBFS: Double = -45
    /// No buffer for this long means the tap has stalled, not that the far
    /// end went quiet. Quiet still delivers buffers (at -120 dBFS).
    static let appTapStallTimeout: TimeInterval = 2
    /// Consecutive end-polls the mic must stay above `micSpeechThresholdDBFS`
    /// before a spike (keyboard, cough, one noisy sample) counts as activity.
    static let micSpeechSustainPolls = 2
    /// A tap that cannot judge (watchdog gave up, stall, capture gave up)
    /// stays `.unknown` so idle cannot fire. After this long with a quiet
    /// mic, treat it as `.quiet` so a truly silent always-on app still ends.
    static let unknownQuietFallback: TimeInterval = 300

    static func classify(_ sample: CallActivitySample) -> CallActivity {
        // Mic speech wins even when the app tap is dead: presenting while
        // others are muted, or talking over a stalled tap, is still a call.
        if sample.micLevelDBFS >= micSpeechThresholdDBFS { return .heard }
        if sample.appCaptureGaveUp || sample.appSilentTrackWatchdogGaveUp {
            return .unknown
        }
        guard let bufferAge = sample.secondsSinceLastAppBuffer else {
            return .unknown
        }
        if bufferAge > appTapStallTimeout { return .unknown }
        if sample.appLevelDBFS >= appAudibleThresholdDBFS { return .heard }
        return .quiet
    }

    /// App-channel speech that is safe to trust this poll. Mic-only `.heard`
    /// still needs `micSpeechSustainPolls` before it resets the idle timer.
    static func heardFromApp(_ sample: CallActivitySample) -> Bool {
        if sample.appCaptureGaveUp || sample.appSilentTrackWatchdogGaveUp { return false }
        guard let bufferAge = sample.secondsSinceLastAppBuffer, bufferAge <= appTapStallTimeout else {
            return false
        }
        return sample.appLevelDBFS >= appAudibleThresholdDBFS
    }

    /// After `unknownQuietFallback` of continuous unknown, a quiet mic is
    /// silence — not a broken tap that must run until max duration.
    static func resolvingUnknown(_ activity: CallActivity, unknownDuration: TimeInterval) -> CallActivity {
        if activity == .unknown, unknownDuration >= unknownQuietFallback { return .quiet }
        return activity
    }
}

/// Path membership by path components, not `hasPrefix` (which would treat
/// `recordings-old` as inside `recordings`).
enum RecordingFileGuard {
    static func isInside(_ url: URL, directory: URL) -> Bool {
        let dir = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let file = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return file.starts(with: dir)
    }
}

/// Static configuration for `WatchLoopEndPolicy.step` — duration limits
/// owned by the WatchLoop instance and re-used across every poll.
struct WatchLoopEndConfig: Equatable {
    let maxDuration: TimeInterval
    let endGracePeriod: TimeInterval
    /// How long both channels may stay silent before a still-"active"
    /// meeting is treated as over. `nil` disables the backstop, which is the
    /// default and what every built-in app with a reliable end signal uses.
    var callAudioIdleTimeout: TimeInterval?
}

/// Pure decision logic for `WatchLoop.waitForMeetingEnd`. Separated so
/// the grace-reset / max-duration / continue-on-active branches can be
/// asserted directly without driving the async timer loop.
enum WatchLoopEndPolicy {
    /// Decide what the meeting-end poller should do given the current
    /// state of the world.
    ///
    /// - Parameters:
    ///   - config: Duration limits (max recording duration + end-of-meeting
    ///     grace period).
    ///   - now: The current wall-clock time. Pass `Date()` from production.
    ///   - startTime: When the poller first started waiting for end.
    ///   - graceStart: When the current inactive run started, or `nil`
    ///     if the meeting was active on the last poll (or has never gone
    ///     inactive).
    ///   - meetingActive: Whether the meeting is active right now.
    ///   - lastCallAudioAt: When either channel last carried audible audio,
    ///     or `nil` if it has not yet in this recording (then the recording
    ///     start counts, so a false start on an idle app still ends).
    ///   - callActivityKnown: When false the app tap cannot be trusted this
    ///     poll (stalled, gave up, silent-track). Idle must not fire; a
    ///     broken tap is not an ended call.
    static func step(
        config: WatchLoopEndConfig,
        now: Date,
        startTime: Date,
        graceStart: Date?,
        meetingActive: Bool,
        lastCallAudioAt: Date? = nil,
        callActivityKnown: Bool = true,
    ) -> WatchLoopEndDecision {
        if now.timeIntervalSince(startTime) > config.maxDuration {
            return .stopMaxDurationExceeded
        }
        // The idle window is its own grace: it already spans minutes of
        // silence, so it stops at once instead of opening a second window.
        // Skipped when the tap cannot judge — otherwise a stalled or
        // silent-track tap would end a meeting that is still going.
        if let idleTimeout = config.callAudioIdleTimeout, callActivityKnown,
           now.timeIntervalSince(lastCallAudioAt ?? startTime) >= idleTimeout {
            return .stopCallAudioIdle
        }
        if meetingActive {
            return .continuePolling(graceStart: nil)
        }
        guard let start = graceStart else {
            return .continuePolling(graceStart: now)
        }
        if now.timeIntervalSince(start) >= config.endGracePeriod {
            return .stopGraceExpired
        }
        return .continuePolling(graceStart: start)
    }
}
