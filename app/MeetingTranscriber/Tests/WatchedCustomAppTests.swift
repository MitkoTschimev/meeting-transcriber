@testable import MeetingTranscriber
import XCTest

final class WatchedCustomAppTests: XCTestCase {
    private let gather = URL(fileURLWithPath: "/Applications/GatherV2.app")
    private let helper = URL(
        fileURLWithPath: "/Applications/GatherV2.app/Contents/Frameworks/Gather Helper.app",
    )

    func testResolvedFallsBackToTheBundleIDWhenTheAppIsNotInstalled() {
        let app = WatchedCustomApp.resolved(
            bundleID: "com.example.not-installed",
            applicationURL: { _ in nil },
            nestedBundleIDs: { _ in [] },
        )
        XCTAssertEqual(app.displayName, "com.example.not-installed")
        XCTAssertEqual(app.matchingBundleIDs, ["com.example.not-installed"])
        XCTAssertNil(app.appBundleURL)
    }

    func testResolvedUsesTheAppFolderNameAndNestedHelperIDs() {
        let app = WatchedCustomApp.resolved(
            bundleID: "com.gather.Gather",
            applicationURL: { $0 == "com.gather.Gather" ? self.gather : nil },
            nestedBundleIDs: { _ in ["com.gather.Gather.helper", "com.github.Electron.helper"] },
        )
        XCTAssertEqual(app.displayName, "GatherV2")
        XCTAssertEqual(
            app.matchingBundleIDs,
            ["com.gather.Gather", "com.gather.Gather.helper", "com.github.Electron.helper"],
        )
        XCTAssertEqual(app.appBundleURL, gather)
    }

    func testMatchesPrefixedHelpersAndDiscoveredUnprefixedHelpers() {
        let app = WatchedCustomApp.resolved(
            bundleID: "com.gather.Gather",
            applicationURL: { _ in self.gather },
            nestedBundleIDs: { _ in ["com.github.Electron.helper"] },
        )
        XCTAssertTrue(app.matches(processBundleID: "com.gather.Gather"))
        XCTAssertTrue(app.matches(processBundleID: "com.gather.Gather.helper.Renderer"))
        XCTAssertTrue(app.matches(processBundleID: "com.github.Electron.helper"))
        XCTAssertFalse(app.matches(processBundleID: "com.gather.Gatherextra"))
        XCTAssertFalse(app.matches(processBundleID: "com.tinyspeck.slackmacgap"))
    }

    func testMatchesAHelperByContainingAppPath() {
        let app = WatchedCustomApp.resolved(
            bundleID: "com.gather.Gather",
            applicationURL: { _ in self.gather },
            nestedBundleIDs: { _ in [] },
        )
        XCTAssertTrue(app.matches(processBundleURL: helper))
        XCTAssertFalse(app.matches(processBundleURL: URL(fileURLWithPath: "/Applications/Slack.app")))
    }

    func testMatchesProcessORsBundleIDAndPath() {
        let app = WatchedCustomApp.resolved(
            bundleID: "com.gather.Gather",
            applicationURL: { _ in self.gather },
            nestedBundleIDs: { _ in [] },
        )
        XCTAssertTrue(app.matches(process: ProcessBundleRef(
            bundleID: "com.github.Electron.helper",
            bundleURL: helper,
        )))
        XCTAssertFalse(app.matches(process: ProcessBundleRef(
            bundleID: "com.tinyspeck.slackmacgap.helper",
            bundleURL: URL(fileURLWithPath: "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app"),
        )))
        XCTAssertFalse(app.matches(process: nil))
    }

    func testBundleIDsInAppAtReadsNestedInfoPlists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchedCustomAppTests-\(UUID().uuidString)", isDirectory: true)
        let host = root.appendingPathComponent("GatherV2.app", isDirectory: true)
        let helperApp = host.appendingPathComponent("Contents/Frameworks/Gather Helper.app", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        try writeInfoPlist(bundleID: "com.gather.Gather", at: host)
        try writeInfoPlist(bundleID: "com.github.Electron.helper", at: helperApp)

        let ids = WatchedCustomApp.bundleIDs(inAppAt: host)
        XCTAssertEqual(Set(ids), ["com.github.Electron.helper"])
        XCTAssertEqual(WatchedCustomApp.bundleIdentifier(at: host), "com.gather.Gather")
    }

    func testMeetingPatternDoesNotRequireConsent() {
        let app = WatchedCustomApp(
            bundleID: "com.gather.Gather",
            displayName: "GatherV2",
            matchingBundleIDs: ["com.gather.Gather"],
            appBundleURL: gather,
        )
        XCTAssertFalse(app.meetingPattern.requiresRecordingConsent)
        XCTAssertEqual(app.meetingPattern.appName, "GatherV2")
    }

    private func writeInfoPlist(bundleID: String, at appURL: URL) throws {
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}
