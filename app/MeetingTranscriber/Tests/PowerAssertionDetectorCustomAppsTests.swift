import AppKit
@testable import MeetingTranscriber
import XCTest

final class PowerAssertionDetectorCustomAppsTests: XCTestCase {
    private let gather = URL(fileURLWithPath: "/Applications/GatherV2.app")
    private let helper = URL(
        fileURLWithPath: "/Applications/GatherV2.app/Contents/Frameworks/Gather Helper.app",
    )
    private let renderer = URL(
        fileURLWithPath: "/Applications/GatherV2.app/Contents/Frameworks/Gather Helper (Renderer).app",
    )

    private func gatherApp() -> WatchedCustomApp {
        WatchedCustomApp(
            bundleID: "com.gather.Gather",
            displayName: "GatherV2",
            matchingBundleIDs: ["com.gather.Gather", "com.gather.Gather.helper", "com.github.Electron.helper"],
            appBundleURL: gather,
        )
    }

    private func detector() -> PowerAssertionDetector {
        let detector = PowerAssertionFixture.browserDetector()
        detector.customAppsProvider = { [self.gatherApp()] }
        detector.mainAppPIDProvider = { $0 == "com.gather.Gather" ? 100 : nil }
        return detector
    }

    func testACustomAppHoldingWebRTCAutoRecordsWithoutConsent() throws {
        let detector = detector()
        detector.processBundleProvider = { _ in
            ProcessBundleRef(bundleID: "com.gather.Gather.helper", bundleURL: self.helper)
        }
        detector.assertionProvider = {
            PowerAssertionFixture.assertions((555, "Gather Helper", PowerAssertionFixture.webRTC))
        }

        let meeting = try XCTUnwrap(detector.checkOnce())
        XCTAssertEqual(meeting.pattern.appName, "GatherV2")
        XCTAssertFalse(meeting.pattern.requiresRecordingConsent)
        XCTAssertEqual(meeting.windowPID, 100, "tap the host app, not the helper that held the assertion")
        XCTAssertEqual(meeting.ownerName, "GatherV2")
    }

    func testHelperProcessHopsStillConfirmAsOneCustomApp() {
        let detector = PowerAssertionFixture.browserDetector(confirmationCount: 2)
        detector.customAppsProvider = { [self.gatherApp()] }
        detector.mainAppPIDProvider = { $0 == "com.gather.Gather" ? 100 : nil }
        detector.processBundleProvider = { pid in
            pid == 1
                ? ProcessBundleRef(bundleID: "com.gather.Gather.helper", bundleURL: self.helper)
                : ProcessBundleRef(bundleID: "com.gather.Gather.helper.Renderer", bundleURL: self.renderer)
        }

        detector.assertionProvider = {
            PowerAssertionFixture.assertions((1, "Gather Helper", PowerAssertionFixture.webRTC))
        }
        XCTAssertNil(detector.checkOnce(), "first helper hit must not confirm")

        detector.assertionProvider = {
            PowerAssertionFixture.assertions((2, "Gather Helper (Renderer)", PowerAssertionFixture.webRTC))
        }
        let meeting = detector.checkOnce()
        XCTAssertEqual(meeting?.pattern.appName, "GatherV2")
        XCTAssertFalse(meeting?.pattern.requiresRecordingConsent ?? true)
    }

    func testADeniedBrowserIdentityDoesNotBlockACustomApp() throws {
        let detector = detector()
        detector.isIdentityDenied = { $0 == "GatherV2" || $0 == "Gather Helper" }
        detector.processBundleProvider = { _ in
            ProcessBundleRef(bundleID: "com.gather.Gather", bundleURL: self.gather)
        }
        detector.assertionProvider = {
            PowerAssertionFixture.assertions((100, "GatherV2", PowerAssertionFixture.webRTC))
        }
        let meeting = try XCTUnwrap(detector.checkOnce())
        XCTAssertEqual(meeting.pattern.appName, "GatherV2")
        XCTAssertFalse(meeting.pattern.requiresRecordingConsent)
    }

    func testAStockElectronHelperOnAnotherHostIsNotTheWatchedApp() {
        let slackHelper = URL(
            fileURLWithPath: "/Applications/Slack.app/Contents/Frameworks/Electron Helper.app",
        )
        let detector = detector()
        detector.processBundleProvider = { _ in
            ProcessBundleRef(bundleID: "com.github.Electron.helper", bundleURL: slackHelper)
        }
        detector.assertionProvider = {
            PowerAssertionFixture.assertions((9, "Slack Helper", PowerAssertionFixture.webRTC))
        }

        let meeting = detector.checkOnce()
        XCTAssertNotEqual(meeting?.pattern.appName, "GatherV2")
        XCTAssertTrue(
            meeting?.pattern.requiresRecordingConsent ?? false,
            "another Electron app's stock helper must still require consent, not auto-record as Gather",
        )
    }

    func testAnUnknownBrowserStillRequiresConsent() {
        let detector = detector()
        detector.processBundleProvider = { _ in
            ProcessBundleRef(
                bundleID: "org.fjordfox.browser",
                bundleURL: URL(fileURLWithPath: "/Applications/Fjordfox.app"),
            )
        }
        detector.assertionProvider = {
            PowerAssertionFixture.assertionDict(
                processName: PowerAssertionFixture.unknownBrowser,
                assertName: PowerAssertionFixture.webRTC,
            )
        }
        let meeting = detector.checkOnce()
        XCTAssertEqual(meeting?.pattern.appName, PowerAssertionFixture.unknownBrowser)
        XCTAssertTrue(meeting?.pattern.requiresRecordingConsent ?? false)
    }

    func testLivenessFollowsAnyHelperOfTheCustomApp() throws {
        let detector = detector()
        detector.processBundleProvider = { pid in
            pid == 555
                ? ProcessBundleRef(bundleID: "com.gather.Gather.helper", bundleURL: self.helper)
                : ProcessBundleRef(bundleID: "com.gather.Gather.helper.Renderer", bundleURL: self.renderer)
        }
        detector.assertionProvider = {
            PowerAssertionFixture.assertions((555, "Gather Helper", PowerAssertionFixture.webRTC))
        }
        let meeting = try XCTUnwrap(detector.checkOnce())

        detector.assertionProvider = {
            PowerAssertionFixture.assertions((556, "Gather Helper (Renderer)", PowerAssertionFixture.webRTC))
        }
        XCTAssertTrue(detector.isMeetingActive(meeting))

        detector.assertionProvider = {
            PowerAssertionFixture.assertions((9, "Microsoft Edge", PowerAssertionFixture.webRTC))
        }
        detector.processBundleProvider = { _ in
            ProcessBundleRef(
                bundleID: "com.microsoft.edgemac",
                bundleURL: URL(fileURLWithPath: "/Applications/Microsoft Edge.app"),
            )
        }
        XCTAssertFalse(detector.isMeetingActive(meeting))
    }

    func testANestedHelperWithoutACustomAppStillRequiresConsentButGroupsByHost() throws {
        // Slack huddle with Browser Web Meetings on, but Slack not added as a
        // custom app: still confirm across helper hops, still ask.
        let detector = PowerAssertionFixture.browserDetector(confirmationCount: 2)
        detector.processBundleProvider = { pid in
            let slack = URL(fileURLWithPath: "/Applications/Slack.app")
            let helper = slack.appendingPathComponent("Contents/Frameworks/Slack Helper.app")
            let renderer = slack.appendingPathComponent("Contents/Frameworks/Slack Helper (Renderer).app")
            return pid == 1
                ? ProcessBundleRef(bundleID: "com.tinyspeck.slackmacgap.helper", bundleURL: helper)
                : ProcessBundleRef(bundleID: "com.tinyspeck.slackmacgap.helper.Renderer", bundleURL: renderer)
        }

        detector.assertionProvider = {
            PowerAssertionFixture.assertions((1, "Slack Helper", PowerAssertionFixture.webRTC))
        }
        XCTAssertNil(detector.checkOnce())

        detector.assertionProvider = {
            PowerAssertionFixture.assertions((2, "Slack Helper (Renderer)", PowerAssertionFixture.webRTC))
        }
        let meeting = try XCTUnwrap(detector.checkOnce())
        XCTAssertEqual(meeting.pattern.appName, "Slack")
        XCTAssertTrue(meeting.pattern.requiresRecordingConsent)
    }

    @MainActor
    func testDefaultDetectorWiresCustomAppsIntoTheAssertionChannel() throws {
        let suite = "CustomAssertionWiring-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let settings = try AppSettings(defaults: XCTUnwrap(UserDefaults(suiteName: suite)))
        settings.watchBrowserMeetings = true
        settings.watchCustomApps = ["com.apple.finder"]

        let detector = try XCTUnwrap(
            WatchingController.defaultDetectors(settings: settings)
                .compactMap { $0 as? PowerAssertionDetector }.first,
        )
        detector.windowListProvider = { [] }
        let finderURL = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder"))
        detector.processBundleProvider = { _ in
            ProcessBundleRef(bundleID: "com.apple.finder", bundleURL: finderURL)
        }
        detector.assertionProvider = {
            PowerAssertionFixture.assertions((42, "Finder", PowerAssertionFixture.webRTC))
        }

        _ = detector.checkOnce()
        let meeting = try XCTUnwrap(detector.checkOnce())
        XCTAssertEqual(meeting.pattern.appName, "Finder")
        XCTAssertFalse(meeting.pattern.requiresRecordingConsent)
    }
}
