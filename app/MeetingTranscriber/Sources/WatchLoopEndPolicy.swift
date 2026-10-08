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
    /// Stop because the detector signal is still up but the call channel has
    /// carried no audible audio for `callAudioIdleTimeout`. Only reachable for
    /// meetings whose detector signal is known to outlive the call (see
    /// `WatchLoop.usesCallAudioIdleBackstop`).
    case stopCallAudioIdle
}

/// Static configuration for `WatchLoopEndPolicy.step` — duration limits
/// owned by the WatchLoop instance and re-used across every poll.
struct WatchLoopEndConfig: Equatable {
    let maxDuration: TimeInterval
    let endGracePeriod: TimeInterval
    /// How long the call channel may stay silent before a still-"active"
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
    ///   - lastCallAudioAt: When the call channel last carried audible audio,
    ///     or `nil` if it has not yet in this recording (then the recording
    ///     start counts, so a false start on an idle app still ends).
    static func step(
        config: WatchLoopEndConfig,
        now: Date,
        startTime: Date,
        graceStart: Date?,
        meetingActive: Bool,
        lastCallAudioAt: Date? = nil,
    ) -> WatchLoopEndDecision {
        if now.timeIntervalSince(startTime) > config.maxDuration {
            return .stopMaxDurationExceeded
        }
        // The idle window is its own grace: it already spans minutes of
        // silence, so it stops at once instead of opening a second window.
        if let idleTimeout = config.callAudioIdleTimeout,
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
