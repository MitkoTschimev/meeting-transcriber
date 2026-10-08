@testable import MeetingTranscriber
import XCTest

/// `checkOnce(ignoring:)`: a parked identity neither confirms nor shadows
/// another app's call.
final class DetectorIgnoringTests: XCTestCase {
    private let gatherURL = URL(fileURLWithPath: "/Applications/GatherV2.app")
    private let helperURL = URL(fileURLWithPath: "/Applications/GatherV2.app/Contents/Frameworks/Gather Helper.app")

    private func gatherDetector() -> PowerAssertionDetector {
        let detector = PowerAssertionDetector(
            patterns: PowerAssertionDetector.patterns(
                watching: [AppMeetingPattern.browserMeetings.appName, "Microsoft Teams"],
            ),
            confirmationCount: 1,
        )
        detector.windowListProvider = { [] }
        let gather = WatchedCustomApp(
            bundleID: "com.gather.Gather",
            displayName: "GatherV2",
            matchingBundleIDs: ["com.gather.Gather"],
            appBundleURL: gatherURL,
        )
        detector.customAppsProvider = { [gather] }
        detector.mainAppPIDProvider = { $0 == "com.gather.Gather" ? 100 : nil }
        detector.processBundleProvider = { pid in
            pid == 555 ? ProcessBundleRef(bundleID: "com.gather.Gather.helper", bundleURL: self.helperURL) : nil
        }
        return detector
    }

    func testPowerAssertionDetectorSkipsAnIgnoredCustomApp() {
        let detector = gatherDetector()
        detector.assertionProvider = {
            PowerAssertionFixture.assertions((555, "Gather Helper", PowerAssertionFixture.webRTC))
        }
        XCTAssertNil(detector.checkOnce(ignoring: ["GatherV2"]))
        XCTAssertEqual(detector.consecutiveHits["GatherV2", default: 0], 0, "an ignored key must not accumulate")
        XCTAssertEqual(detector.checkOnce()?.pattern.appName, "GatherV2", "not ignored: detected as before")
    }

    func testIgnoredAppDoesNotShadowAnotherCall() {
        let detector = gatherDetector()
        detector.assertionProvider = {
            PowerAssertionFixture.assertions(
                (555, "Gather Helper", PowerAssertionFixture.webRTC),
                (777, "MSTeams", "Microsoft Teams Call in progress"),
            )
        }
        XCTAssertEqual(detector.checkOnce(ignoring: ["GatherV2"])?.pattern.appName, "Microsoft Teams")
    }

    func testMicInputDetectorSkipsAnIgnoredApp() {
        let detector = MicInputDetector(
            patterns: [MicInputDetector.MicPattern(
                appName: "GatherV2", bundleIDs: ["com.gather.Gather"],
                matchesHelpers: true, usesBuiltInMeetingPattern: false,
            )],
            confirmationCount: 1,
        )
        detector.windowListProvider = { [] }
        detector.processProvider = {
            [MicInputDetector.AudioProcessSnapshot(bundleID: "com.gather.Gather.helper", pid: 555, isRunningInput: true)]
        }
        detector.mainAppPIDProvider = { _ in 100 }
        XCTAssertNil(detector.checkOnce(ignoring: ["GatherV2"]))
        XCTAssertEqual(detector.checkOnce()?.pattern.appName, "GatherV2")
    }

    func testCompositeForwardsTheIgnoredSet() {
        let gather = ScriptedMeetingDetector()
        gather.meeting = DetectedMeeting(
            pattern: AppMeetingPattern(appName: "GatherV2", ownerNames: ["GatherV2"], meetingPatterns: []),
            windowTitle: "GatherV2 Call", ownerName: "GatherV2", windowPID: 100,
        )
        let composite = CompositeMeetingDetector([gather])
        XCTAssertNil(composite.checkOnce(ignoring: ["GatherV2"]))
        XCTAssertNotNil(composite.checkOnce())
    }
}
