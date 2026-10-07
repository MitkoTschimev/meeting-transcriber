import AppKit
import AudioTapLib
import Foundation

/// Bundle identity of a live process, used to decide whether it belongs to a
/// user-added custom watch app (main binary or an Electron/Chromium helper).
struct ProcessBundleRef: Equatable {
    var bundleID: String
    var bundleURL: URL?
}

/// An app the user added under Settings → Apps to Watch.
///
/// Custom apps opt in to auto-recording: mic-input detection already treats
/// them as a call, and the browser WebRTC path must not then demand a second
/// consent prompt (Gather, Slack huddles, and other Electron clients hold both
/// signals). Matching is by the picked bundle ID, `<id>.*` helpers, nested
/// helper bundle IDs discovered inside the `.app`, and the containing-app
/// path. Helper IDs that do not share the main prefix (a stock Electron
/// `com.github.Electron.helper`) still count, but only when the process
/// lives under this host — the stock ID is shared across Electron apps.
struct WatchedCustomApp: Equatable {
    let bundleID: String
    let displayName: String
    /// Main bundle ID first, then nested helper IDs from the installed app.
    let matchingBundleIDs: [String]
    let appBundleURL: URL?

    /// Resolve an installed app, or fall back to the bundle ID as the name
    /// when it is not on disk (tests, and a Settings row the user has not
    /// reinstalled yet).
    static func resolved(
        bundleID: String,
        applicationURL: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        nestedBundleIDs: (URL) -> [String] = bundleIDs(inAppAt:),
        displayName: (String, URL?) -> String = { id, url in
            url?.deletingPathExtension().lastPathComponent ?? id
        },
    ) -> WatchedCustomApp {
        let url = applicationURL(bundleID)
        var ids = [bundleID]
        if let url {
            for nested in nestedBundleIDs(url) where !ids.contains(nested) {
                ids.append(nested)
            }
        }
        return WatchedCustomApp(
            bundleID: bundleID,
            displayName: displayName(bundleID, url),
            matchingBundleIDs: ids,
            appBundleURL: url,
        )
    }

    /// True for the picked ID and `<id>.*` helpers. Unprefixed nested IDs
    /// (stock `com.github.Electron.helper`) are not unique across Electron
    /// apps and must not match by ID alone — use `matches(process:)`.
    func matches(processBundleID: String) -> Bool {
        guard !processBundleID.isEmpty else { return false }
        return processBundleID == bundleID || processBundleID.hasPrefix(bundleID + ".")
    }

    func matches(processBundleURL: URL) -> Bool {
        guard let appBundleURL else { return false }
        let outer = ProcessTreeEnumerator.outermostAppBundle(containing: processBundleURL)
        return outer.resolvingSymlinksInPath().path == appBundleURL.resolvingSymlinksInPath().path
    }

    func matches(process: ProcessBundleRef?) -> Bool {
        guard let process else { return false }
        if matches(processBundleID: process.bundleID) { return true }
        // Unprefixed nested IDs (stock Electron helpers) are not unique;
        // they only count when the process lives under this host.
        guard let url = process.bundleURL else { return false }
        return matches(processBundleURL: url)
    }

    /// Every `.app` bundle identifier under `url`, including helpers nested
    /// inside Frameworks or a Chromium versioned Helpers directory.
    static func bundleIDs(inAppAt url: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles],
        ) else { return [] }

        var ids: [String] = []
        for case let item as URL in enumerator {
            guard item.pathExtension.lowercased() == "app" else { continue }
            if let id = bundleIdentifier(at: item), !ids.contains(id) {
                ids.append(id)
            }
        }
        return ids
    }

    static func bundleIdentifier(at appURL: URL) -> String? {
        if let id = Bundle(url: appURL)?.bundleIdentifier, !id.isEmpty {
            return id
        }
        let info = appURL.appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: info),
              let id = plist["CFBundleIdentifier"] as? String, !id.isEmpty
        else { return nil }
        return id
    }

    var meetingPattern: AppMeetingPattern {
        AppMeetingPattern(appName: displayName, ownerNames: [displayName], meetingPatterns: [])
    }
}
