import Foundation

extension WatchLoop {
    func enrichedTitle(_ detected: String, appName: String) -> String {
        CalendarTitlePolicy.resolve(
            detectedTitle: detected,
            event: calendarLookup(nowProvider()),
            appName: appName,
        )
    }

    /// Strip app suffixes from meeting titles for cleaner display.
    static func cleanTitle(_ title: String) -> String {
        let suffixes = [" | Microsoft Teams", " - Zoom", " - Webex"]
        for suffix in suffixes where title.hasSuffix(suffix) {
            return String(title.dropLast(suffix.count))
        }
        return title
    }
}
