@testable import MeetingTranscriber
import XCTest

/// Pure-function tests for the decision policy that drives
/// `WatchLoop.waitForMeetingEnd`. These cover each branch without an async
/// timer loop, so the grace-reset / grace-expiry / max-duration interactions
/// are deterministic.
final class WatchLoopEndPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private static let defaultConfig = WatchLoopEndConfig(maxDuration: 100, endGracePeriod: 10)

    private func step(
        meetingActive: Bool,
        elapsedSinceStart: TimeInterval,
        graceStart: Date? = nil,
        config: WatchLoopEndConfig = defaultConfig,
    ) -> WatchLoopEndDecision {
        WatchLoopEndPolicy.step(
            config: config,
            now: t0.addingTimeInterval(elapsedSinceStart),
            startTime: t0,
            graceStart: graceStart,
            meetingActive: meetingActive,
        )
    }

    // MARK: - Max duration

    func testStopsWhenMaxDurationExceeded() {
        XCTAssertEqual(
            step(meetingActive: true, elapsedSinceStart: 100.1),
            .stopMaxDurationExceeded,
        )
    }

    func testMaxDurationTakesPrecedenceOverGrace() {
        // Even with an inactive meeting that would otherwise still be in
        // its grace window, max duration wins.
        XCTAssertEqual(
            step(
                meetingActive: false,
                elapsedSinceStart: 100.5,
                graceStart: t0.addingTimeInterval(100),
            ),
            .stopMaxDurationExceeded,
        )
    }

    // MARK: - Active meeting clears grace

    func testActiveMeetingClearsGrace() {
        XCTAssertEqual(
            step(
                meetingActive: true,
                elapsedSinceStart: 5,
                graceStart: t0.addingTimeInterval(2),
            ),
            .continuePolling(graceStart: nil),
        )
    }

    func testActiveMeetingContinuesWithoutGrace() {
        XCTAssertEqual(
            step(meetingActive: true, elapsedSinceStart: 5, graceStart: nil),
            .continuePolling(graceStart: nil),
        )
    }

    // MARK: - Inactive meeting starts grace

    func testInactiveMeetingStartsGraceWhenNoneRunning() {
        let now = t0.addingTimeInterval(5)
        XCTAssertEqual(
            WatchLoopEndPolicy.step(
                config: Self.defaultConfig,
                now: now,
                startTime: t0,
                graceStart: nil,
                meetingActive: false,
            ),
            .continuePolling(graceStart: now),
        )
    }

    // MARK: - Grace expiry

    func testInactiveMeetingStaysInGraceWhenNotYetExpired() {
        let graceStart = t0.addingTimeInterval(5)
        XCTAssertEqual(
            step(meetingActive: false, elapsedSinceStart: 9, graceStart: graceStart),
            .continuePolling(graceStart: graceStart),
        )
    }

    func testInactiveMeetingStopsWhenGraceExpired() {
        let graceStart = t0.addingTimeInterval(5)
        XCTAssertEqual(
            step(meetingActive: false, elapsedSinceStart: 15.5, graceStart: graceStart),
            .stopGraceExpired,
        )
    }

    func testGraceExpiryUsesGreaterThanOrEqual() {
        // Edge case: elapsed since graceStart == endGracePeriod exactly.
        // Current production behaviour treats this as expired (>= comparison).
        let graceStart = t0.addingTimeInterval(0)
        XCTAssertEqual(
            step(meetingActive: false, elapsedSinceStart: 10, graceStart: graceStart),
            .stopGraceExpired,
        )
    }

    // MARK: - Reset behaviour

    func testGraceResetsWhenMeetingResumesThenEnds() {
        // Sequence reproducing the WatchLoop characterization test on the
        // pure policy: inactive (grace starts) → active (grace clears) →
        // inactive (fresh grace) → inactive past gracePeriod (stops).
        var graceStart: Date?

        // t=1: inactive, grace starts.
        graceStart = expectContinue(step(
            meetingActive: false, elapsedSinceStart: 1, graceStart: graceStart,
        ))
        XCTAssertEqual(graceStart, t0.addingTimeInterval(1))

        // t=2: active, grace clears.
        graceStart = expectContinue(step(
            meetingActive: true, elapsedSinceStart: 2, graceStart: graceStart,
        ))
        XCTAssertNil(graceStart)

        // t=3: inactive, fresh grace.
        graceStart = expectContinue(step(
            meetingActive: false, elapsedSinceStart: 3, graceStart: graceStart,
        ))
        XCTAssertEqual(graceStart, t0.addingTimeInterval(3))

        // t=13: elapsed since fresh grace = 10, threshold met → stop.
        XCTAssertEqual(
            step(meetingActive: false, elapsedSinceStart: 13, graceStart: graceStart),
            .stopGraceExpired,
        )

        // Critical: the first grace started at t=1, so a monotonic timer
        // would have stopped at t=11. The fact that we are still polling
        // at t=13 proves the reset.
    }

    // MARK: - Call-audio idle backstop

    private static let idleConfig = WatchLoopEndConfig(
        maxDuration: 1000, endGracePeriod: 10, callAudioIdleTimeout: 300,
    )

    private func idleStep(elapsed: TimeInterval, lastAudioAt: TimeInterval?, active: Bool = true) -> WatchLoopEndDecision {
        WatchLoopEndPolicy.step(
            config: Self.idleConfig,
            now: t0.addingTimeInterval(elapsed),
            startTime: t0,
            graceStart: nil,
            meetingActive: active,
            lastCallAudioAt: lastAudioAt.map { t0.addingTimeInterval($0) },
        )
    }

    /// The Gather case: the detector still says "in a call", but nobody has
    /// been heard for the whole idle window, so the recording ends.
    func testStillActiveMeetingStopsAfterCallAudioIdleTimeout() {
        XCTAssertEqual(idleStep(elapsed: 400, lastAudioAt: 100), .stopCallAudioIdle)
    }

    func testRecentCallAudioKeepsAnActiveMeetingRecording() {
        XCTAssertEqual(idleStep(elapsed: 399, lastAudioAt: 100), .continuePolling(graceStart: nil))
    }

    /// A false start on an idle app (never any call audio) counts from the
    /// recording start instead of running forever.
    func testNoCallAudioEverCountsFromRecordingStart() {
        XCTAssertEqual(idleStep(elapsed: 299, lastAudioAt: nil), .continuePolling(graceStart: nil))
        XCTAssertEqual(idleStep(elapsed: 300, lastAudioAt: nil), .stopCallAudioIdle)
    }

    /// Without a timeout (every built-in app) silence never ends a meeting
    /// that its detector still reports.
    func testNoIdleTimeoutMeansSilenceNeverStops() {
        XCTAssertEqual(
            step(meetingActive: true, elapsedSinceStart: 99),
            .continuePolling(graceStart: nil),
        )
    }

    func testMaxDurationStillWinsOverIdle() {
        XCTAssertEqual(idleStep(elapsed: 1000.5, lastAudioAt: nil), .stopMaxDurationExceeded)
    }

    /// A stalled or given-up tap cannot say the call ended, so idle must not
    /// fire even after the timeout. Max duration is the remaining bound.
    func testUnknownCallActivitySkipsIdleTimeout() {
        XCTAssertEqual(
            WatchLoopEndPolicy.step(
                config: Self.idleConfig,
                now: t0.addingTimeInterval(400),
                startTime: t0,
                graceStart: nil,
                meetingActive: true,
                lastCallAudioAt: t0,
                callActivityKnown: false,
            ),
            .continuePolling(graceStart: nil),
        )
    }

    // MARK: - Call activity classification

    func testMicSpeechCountsAsHeardEvenWhenTheAppChannelIsSilent() {
        XCTAssertEqual(
            CallActivityPolicy.classify(CallActivitySample(appLevelDBFS: -120, micLevelDBFS: -30)),
            .heard,
        )
    }

    func testQuietAppAndMicIsQuiet() {
        XCTAssertEqual(
            CallActivityPolicy.classify(CallActivitySample(appLevelDBFS: -80, micLevelDBFS: -80)),
            .quiet,
        )
    }

    func testStalledAppTapIsUnknownWhenTheMicIsQuiet() {
        XCTAssertEqual(
            CallActivityPolicy.classify(CallActivitySample(
                appLevelDBFS: -120,
                micLevelDBFS: -120,
                secondsSinceLastAppBuffer: 3,
            )),
            .unknown,
        )
    }

    func testMicSpeechWinsOverAStalledTap() {
        XCTAssertEqual(
            CallActivityPolicy.classify(CallActivitySample(
                appLevelDBFS: -120,
                micLevelDBFS: -30,
                secondsSinceLastAppBuffer: 5,
            )),
            .heard,
        )
    }

    func testGivenUpCaptureIsUnknown() {
        XCTAssertEqual(
            CallActivityPolicy.classify(CallActivitySample(
                appLevelDBFS: -120,
                micLevelDBFS: -120,
                appCaptureGaveUp: true,
            )),
            .unknown,
        )
    }

    func testSilentTrackWatchdogGaveUpIsUnknown() {
        XCTAssertEqual(
            CallActivityPolicy.classify(CallActivitySample(
                appLevelDBFS: -120,
                micLevelDBFS: -120,
                appSilentTrackWatchdogGaveUp: true,
            )),
            .unknown,
        )
    }

    func testNeverDeliveredBufferIsUnknown() {
        XCTAssertEqual(
            CallActivityPolicy.classify(CallActivitySample(
                appLevelDBFS: -120,
                micLevelDBFS: -120,
                secondsSinceLastAppBuffer: nil,
            )),
            .unknown,
        )
    }

    func testAppSpeechIsHeard() {
        XCTAssertEqual(
            CallActivityPolicy.classify(CallActivitySample(appLevelDBFS: -25, micLevelDBFS: -120)),
            .heard,
        )
        XCTAssertTrue(CallActivityPolicy.heardFromApp(CallActivitySample(appLevelDBFS: -25, micLevelDBFS: -120)))
        XCTAssertFalse(CallActivityPolicy.heardFromApp(CallActivitySample(appLevelDBFS: -120, micLevelDBFS: -30)))
    }

    func testRecordingFileGuardUsesPathComponentsNotPrefix() {
        let recordings = URL(fileURLWithPath: "/tmp/recordings")
        XCTAssertTrue(RecordingFileGuard.isInside(
            URL(fileURLWithPath: "/tmp/recordings/mix.wav"),
            directory: recordings,
        ))
        XCTAssertFalse(
            RecordingFileGuard.isInside(
                URL(fileURLWithPath: "/tmp/recordings-old/mix.wav"),
                directory: recordings,
            ),
            "hasPrefix would have treated recordings-old as inside recordings",
        )
    }

    func testUnknownFallsBackToQuietAfterTimeout() {
        XCTAssertEqual(
            CallActivityPolicy.resolvingUnknown(.unknown, unknownDuration: CallActivityPolicy.unknownQuietFallback - 1),
            .unknown,
        )
        XCTAssertEqual(
            CallActivityPolicy.resolvingUnknown(.unknown, unknownDuration: CallActivityPolicy.unknownQuietFallback),
            .quiet,
        )
        XCTAssertEqual(
            CallActivityPolicy.resolvingUnknown(.heard, unknownDuration: CallActivityPolicy.unknownQuietFallback),
            .heard,
        )
    }

    /// Helper: assert decision is `.continuePolling` and return the new
    /// grace-start carried forward to the next poll.
    private func expectContinue(_ decision: WatchLoopEndDecision) -> Date? {
        guard case let .continuePolling(g) = decision else {
            XCTFail("Expected .continuePolling, got \(decision)")
            return nil
        }
        return g
    }
}
