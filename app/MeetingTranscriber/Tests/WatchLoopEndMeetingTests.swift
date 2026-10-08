import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// A detector a test scripts per call. `active` decides `isMeetingActive`,
/// so a test can keep a signal up forever (the Gather case) or drop it.
final class ScriptedMeetingDetector: MeetingDetecting {
    var meeting: DetectedMeeting?
    var active: (DetectedMeeting) -> Bool = { _ in true }

    func checkOnce() -> DetectedMeeting? {
        meeting
    }

    func isMeetingActive(_ meeting: DetectedMeeting) -> Bool {
        active(meeting)
    }

    func reset(appName _: String?) {}
}

/// Ending an auto-detected meeting while its detector still reports a call:
/// the Stop button and the call-audio idle backstop (regression for "it
/// started automatically but never stopped" with Gather, a custom watch app
/// whose WebRTC assertion and mic use outlive the call).
@MainActor
final class WatchLoopEndMeetingTests: XCTestCase {
    private func gatherMeeting() -> DetectedMeeting {
        DetectedMeeting(
            pattern: AppMeetingPattern(appName: "GatherV2", ownerNames: ["GatherV2"], meetingPatterns: []),
            windowTitle: "GatherV2 Call",
            ownerName: "GatherV2",
            windowPID: 100,
        )
    }

    /// Zoom rather than Teams: `handleMeeting` reads Teams participants over
    /// Accessibility, which a unit test must not touch.
    private func zoomMeeting() -> DetectedMeeting {
        DetectedMeeting(
            pattern: .zoom,
            windowTitle: "Zoom Meeting",
            ownerName: "zoom.us",
            windowPID: 1234,
        )
    }

    /// A browser-meeting identity (Google Meet in Chrome): consent-gated,
    /// synthesised process name. WebRTC drops when the call ends, so the
    /// idle backstop must not apply.
    private func chromeMeeting() -> DetectedMeeting {
        DetectedMeeting(
            pattern: AppMeetingPattern(
                appName: "Google Chrome",
                ownerNames: ["Google Chrome"],
                meetingPatterns: [],
                requiresRecordingConsent: true,
            ),
            windowTitle: "Meet - Chrome",
            ownerName: "Google Chrome",
            windowPID: 200,
        )
    }

    private func makeLoop(
        detector: any MeetingDetecting,
        recorder: MockRecorder,
        clock: TestClock,
        maxDuration: TimeInterval = 3600,
    ) -> WatchLoop {
        WatchLoop(
            detector: detector,
            recorderFactory: { recorder },
            pollInterval: 3,
            endGracePeriod: 15,
            maxDuration: maxDuration,
            callAudioIdleTimeout: 300,
            nowProvider: { clock.now },
            sleepProvider: { await clock.sleep(for: $0) },
        )
    }

    // MARK: - Call-audio idle backstop

    func testCustomAppWithStickySignalStopsWhenCallAudioGoesSilent() async throws {
        let detector = ScriptedMeetingDetector()
        let recorder = makeMockRecorder()
        recorder.appLevelDBFS = -120
        let clock = TestClock()
        let loop = makeLoop(detector: detector, recorder: recorder, clock: clock)
        let start = clock.now

        try await loop.handleMeeting(gatherMeeting())

        XCTAssertTrue(recorder.stopCalled, "the recording must be finalized, not left running")
        let elapsed = clock.now.timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 300)
        XCTAssertLessThan(elapsed, 3600, "must end on silence, not at max duration")
        XCTAssertEqual(loop.parkedMeeting?.pattern.appName, "GatherV2")
    }

    func testCallAudioKeepsTheCustomAppRecordingGoing() async throws {
        let detector = ScriptedMeetingDetector()
        let recorder = makeMockRecorder()
        let clock = TestClock()
        let start = clock.now
        // Audible for the first ten minutes, then silent.
        detector.active = { _ in
            recorder.appLevelDBFS = clock.now.timeIntervalSince(start) < 600 ? -25 : -120
            return true
        }
        let loop = makeLoop(detector: detector, recorder: recorder, clock: clock)

        try await loop.handleMeeting(gatherMeeting())

        let elapsed = clock.now.timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 900, "idle counts from the last audible poll")
        XCTAssertLessThan(elapsed, 1000)
    }

    /// Built-in apps keep their call-scoped end signal; silence alone (a long
    /// quiet stretch in a Zoom call) must not end them.
    func testBuiltInAppIsNotEndedBySilence() async throws {
        let detector = ScriptedMeetingDetector()
        let recorder = makeMockRecorder()
        recorder.appLevelDBFS = -120
        let clock = TestClock()
        let loop = makeLoop(detector: detector, recorder: recorder, clock: clock, maxDuration: 1200)
        let start = clock.now

        try await loop.handleMeeting(zoomMeeting())

        XCTAssertGreaterThan(clock.now.timeIntervalSince(start), 1200, "only max duration ends it")
        XCTAssertNil(loop.parkedMeeting)
    }

    /// A capture that gave up cannot say whether anyone is talking, so it
    /// must not end a meeting that may well be running.
    func testGivenUpAppCaptureNeverCountsAsSilence() async throws {
        let detector = ScriptedMeetingDetector()
        let recorder = makeMockRecorder()
        recorder.appLevelDBFS = -120
        recorder.appCaptureGaveUp = true
        let clock = TestClock()
        let loop = makeLoop(detector: detector, recorder: recorder, clock: clock, maxDuration: 1200)
        let start = clock.now

        try await loop.handleMeeting(gatherMeeting())

        XCTAssertGreaterThan(clock.now.timeIntervalSince(start), 1200)
    }

    func testUsesBackstopOnlyForSynthesisedAutoRecordIdentities() {
        XCTAssertTrue(WatchLoop.usesCallAudioIdleBackstop(gatherMeeting()))
        XCTAssertFalse(WatchLoop.usesCallAudioIdleBackstop(zoomMeeting()))
        XCTAssertFalse(
            WatchLoop.usesCallAudioIdleBackstop(chromeMeeting()),
            "browser meetings drop WebRTC when the call ends; silence must not stop them",
        )
    }

    /// Presenting while everyone else is muted: the app channel is silent
    /// for minutes, but the mic is not, so the recording must keep going.
    func testMicSpeechKeepsACustomAppRecordingGoing() async throws {
        let detector = ScriptedMeetingDetector()
        let recorder = makeMockRecorder()
        recorder.appLevelDBFS = -120
        recorder.micLevelDBFS = -30
        let clock = TestClock()
        let loop = makeLoop(detector: detector, recorder: recorder, clock: clock, maxDuration: 1200)
        let start = clock.now

        try await loop.handleMeeting(gatherMeeting())

        XCTAssertGreaterThan(clock.now.timeIntervalSince(start), 1200, "mic speech is activity; only max duration ends it")
        XCTAssertNil(loop.parkedMeeting)
    }

    /// A tap that has stopped delivering buffers cannot be read as "the call
    /// went silent". Ending and parking would drop the rest of a live meeting.
    func testStalledAppTapNeverCountsAsSilence() async throws {
        let detector = ScriptedMeetingDetector()
        let recorder = makeMockRecorder()
        recorder.appLevelDBFS = -120
        recorder.micLevelDBFS = -120
        recorder.appSignalAges = ChannelSignalAges(secondsSinceLastBuffer: 5, secondsSinceLastEnergy: 5)
        let clock = TestClock()
        let loop = makeLoop(detector: detector, recorder: recorder, clock: clock, maxDuration: 1200)
        let start = clock.now

        try await loop.handleMeeting(gatherMeeting())

        XCTAssertGreaterThan(clock.now.timeIntervalSince(start), 1200)
        XCTAssertNil(loop.parkedMeeting)
    }

    func testSilentTrackWatchdogGaveUpNeverCountsAsSilence() async throws {
        let detector = ScriptedMeetingDetector()
        let recorder = makeMockRecorder()
        recorder.appLevelDBFS = -120
        recorder.appSilentTrackWatchdogGaveUp = true
        let clock = TestClock()
        let loop = makeLoop(detector: detector, recorder: recorder, clock: clock, maxDuration: 1200)
        let start = clock.now

        try await loop.handleMeeting(gatherMeeting())

        XCTAssertGreaterThan(clock.now.timeIntervalSince(start), 1200)
    }

    func testBrowserMeetingIsNotEndedBySilence() async throws {
        let detector = ScriptedMeetingDetector()
        let recorder = makeMockRecorder()
        recorder.appLevelDBFS = -120
        let clock = TestClock()
        let loop = makeLoop(detector: detector, recorder: recorder, clock: clock, maxDuration: 1200)
        let start = clock.now

        try await loop.handleMeeting(chromeMeeting())

        XCTAssertGreaterThan(clock.now.timeIntervalSince(start), 1200, "only max duration ends a browser meeting")
        XCTAssertNil(loop.parkedMeeting)
    }

    // MARK: - Stop button

    func testEndCurrentMeetingFinalizesTheRecording() async throws {
        let detector = ScriptedMeetingDetector()
        let recorder = makeMockRecorder()
        recorder.appLevelDBFS = -20
        let clock = TestClock()
        let start = clock.now
        var loopRef: WatchLoop?
        let polls = ManagedCounter()
        detector.active = { _ in
            if polls.increment() == 3 {
                MainActor.assumeIsolated { loopRef?.endCurrentMeeting() }
            }
            return true
        }
        let loop = makeLoop(detector: detector, recorder: recorder, clock: clock)
        loopRef = loop

        try await loop.handleMeeting(gatherMeeting())

        XCTAssertTrue(recorder.stopCalled)
        XCTAssertLessThan(clock.now.timeIntervalSince(start), 20, "ends at the next poll, not on a timeout")
        XCTAssertEqual(loop.parkedMeeting?.pattern.appName, "GatherV2", "a still-signalling app is parked")
        XCTAssertFalse(loop.endRequested, "the request is spent once the recording ended")
    }

    /// Stop must not wait out the poll interval: the press wakes the poller.
    func testEndCurrentMeetingWakesTheSleepingPoller() async throws {
        let detector = ScriptedMeetingDetector()
        let recorder = makeMockRecorder()
        recorder.appLevelDBFS = -20
        let loop = WatchLoop(
            detector: detector,
            recorderFactory: { recorder },
            pollInterval: 60,
            endGracePeriod: 15,
        )
        let task = Task { try await loop.handleMeeting(self.gatherMeeting()) }
        for _ in 0 ..< 1000 where loop.endPollSleeper == nil {
            await Task.yield()
        }
        XCTAssertNotNil(loop.endPollSleeper, "the poller should be sleeping between polls")
        XCTAssertTrue(loop.isRecordingDetectedMeeting)

        let pressedAt = Date()
        loop.endCurrentMeeting()
        try await task.value

        XCTAssertLessThan(Date().timeIntervalSince(pressedAt), 5)
        XCTAssertTrue(recorder.stopCalled)
    }

    func testEndCurrentMeetingIsANoOpWhenNotRecording() {
        let loop = WatchLoop(detector: ScriptedMeetingDetector())
        loop.endCurrentMeeting()
        XCTAssertFalse(loop.endRequested)
        XCTAssertFalse(loop.isRecordingDetectedMeeting)
    }

    // MARK: - Parking

    func testParkedMeetingIsIgnoredUntilItsSignalDrops() {
        let detector = ScriptedMeetingDetector()
        let loop = WatchLoop(detector: detector)
        let meeting = gatherMeeting()

        loop.parkIfEndedEarly(meeting, reason: .userStopped)
        XCTAssertEqual(loop.ignoredIdentities, ["GatherV2"])

        loop.releaseParkedMeetingIfEnded()
        XCTAssertEqual(loop.ignoredIdentities, ["GatherV2"], "signal still up: stay parked")

        detector.active = { _ in false }
        loop.releaseParkedMeetingIfEnded()
        XCTAssertTrue(loop.ignoredIdentities.isEmpty, "signal gone: the next call is detected again")
    }

    func testNaturalEndsDoNotPark() {
        let loop = WatchLoop(detector: ScriptedMeetingDetector())
        for reason in [MeetingEndReason.signalEnded, .maxDuration, .cancelled] {
            loop.parkIfEndedEarly(gatherMeeting(), reason: reason)
            XCTAssertNil(loop.parkedMeeting, "\(reason) must not park")
        }
    }

    func testEarlyEndOfAnAlreadyFinishedMeetingDoesNotPark() {
        let detector = ScriptedMeetingDetector()
        detector.active = { _ in false }
        let loop = WatchLoop(detector: detector)
        loop.parkIfEndedEarly(gatherMeeting(), reason: .callAudioIdle)
        XCTAssertNil(loop.parkedMeeting)
    }

    /// Built-in apps drop their call signal when the meeting ends. Parking
    /// them on Stop would skip a back-to-back call that starts before that
    /// leftover signal disappears.
    func testBuiltInAppUserStopDoesNotPark() {
        let loop = WatchLoop(detector: ScriptedMeetingDetector())
        loop.parkIfEndedEarly(zoomMeeting(), reason: .userStopped)
        XCTAssertNil(loop.parkedMeeting)
        XCTAssertTrue(loop.ignoredIdentities.isEmpty)
    }

    func testParkingExpiresAfterTTLWhileTheSignalStaysUp() async {
        let detector = ScriptedMeetingDetector()
        let clock = TestClock()
        let loop = WatchLoop(
            detector: detector,
            nowProvider: { clock.now },
            sleepProvider: { await clock.sleep(for: $0) },
        )
        loop.parkIfEndedEarly(gatherMeeting(), reason: .callAudioIdle)
        XCTAssertEqual(loop.ignoredIdentities, ["GatherV2"])

        await clock.sleep(for: WatchLoop.parkedIdentityTTL - 1)
        loop.releaseParkedMeetingIfEnded()
        XCTAssertEqual(loop.ignoredIdentities, ["GatherV2"], "TTL not yet elapsed: stay parked")

        await clock.sleep(for: 1)
        loop.releaseParkedMeetingIfEnded()
        XCTAssertTrue(loop.ignoredIdentities.isEmpty, "TTL elapsed: re-arm even though the signal is still up")
        XCTAssertNil(loop.parkedMeeting)
    }
}
