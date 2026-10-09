import Foundation

extension WatchLoop {
    func overlappingCalendarEvent() -> CalendarEvent? {
        calendarLookup(nowProvider())
    }

    func calendarContext(detectedTitle: String, appName: String) -> (title: String, attendees: [CalendarAttendee]) {
        let event = overlappingCalendarEvent()
        let title = CalendarTitlePolicy.resolve(
            detectedTitle: detectedTitle,
            event: event,
            appName: appName,
        )
        return (title, event?.attendees ?? [])
    }

    func enrichedTitle(_ detected: String, appName: String) -> String {
        calendarContext(detectedTitle: detected, appName: appName).title
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
