import Foundation

/// Decides when a calendar event should replace a detected window title, and
/// which of today's events is "the current meeting".
///
/// Window titles from Zoom/Teams are often the product name or a 1:1 contact;
/// calendar titles are usually the meeting the user put on the agenda. Prefer
/// the calendar only when the detected title is generic, or when the two
/// already name the same meeting. Unrelated specific titles keep the window
/// title: a call titled "Jane Doe" should not become "Focus time".
enum CalendarTitlePolicy {
    private static let genericTitles: Set<String> = [
        "meeting",
        "zoom meeting",
        "zoom",
        "microsoft teams meeting",
        "microsoft teams",
        "teams meeting",
        "webex meeting",
        "webex",
        "google meet",
        "meet",
        "facetime",
        "whatsapp",
        "whatsapp call",
        "microphone recording",
    ]

    static func isGeneric(_ title: String, appName: String = "") -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let lower = trimmed.lowercased()
        if Self.genericTitles.contains(lower) { return true }
        if !appName.isEmpty, lower == appName.lowercased() { return true }
        return false
    }

    static func resolve(detectedTitle: String, event: CalendarEvent?, appName: String = "") -> String {
        let detected = detectedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let event else { return detected }
        let calendarTitle = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if calendarTitle.isEmpty { return detected }
        if isGeneric(detected, appName: appName) { return calendarTitle }
        if isGeneric(calendarTitle) { return detected }
        let detectedLower = detected.lowercased()
        let calendarLower = calendarTitle.lowercased()
        if detectedLower.contains(calendarLower) || calendarLower.contains(detectedLower) {
            return calendarTitle
        }
        return detected
    }

    /// Timed (not all-day) event whose span contains `date`, with a little
    /// grace on either side so a recording that starts a minute early still
    /// matches. Closest start wins when two events overlap.
    static func overlappingEvent(
        in events: [CalendarEvent],
        at date: Date,
        graceBefore: TimeInterval = 120,
        graceAfter: TimeInterval = 120,
    ) -> CalendarEvent? {
        events
            .filter { event in
                guard !event.isAllDay, !event.isCancelled, !event.currentUserDeclined else { return false }
                let windowStart = event.start.addingTimeInterval(-graceBefore)
                let windowEnd = event.end.addingTimeInterval(graceAfter)
                return date >= windowStart && date <= windowEnd
            }
            .min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }
    }
}
