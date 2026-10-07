import Foundation

/// Merge, sort, and slice upcoming events from multiple providers.
///
/// Apple Calendar can already contain a Google account added in Calendar.app,
/// so enabling both providers often yields the same meeting twice. Dedup by
/// normalised title + start minute, keeping the copy that has a join link.
enum CalendarAgenda {
    static func merge(_ groups: [[CalendarEvent]]) -> [CalendarEvent] {
        var chosen: [String: CalendarEvent] = [:]
        var order: [String] = []
        for event in groups.joined() {
            let key = dedupKey(event)
            if let existing = chosen[key] {
                chosen[key] = prefer(event, over: existing)
            } else {
                chosen[key] = event
                order.append(key)
            }
        }
        return order.compactMap { chosen[$0] }
    }

    static func upcoming(
        _ events: [CalendarEvent],
        from now: Date,
        calendar: Calendar = .current,
        limit: Int = 12,
    ) -> [CalendarEvent] {
        let startOfDay = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 2, to: startOfDay) ?? now.addingTimeInterval(48 * 3600)
        let filtered = events
            .filter { $0.end >= now && $0.start < end }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        return Array(filtered.prefix(limit))
    }

    private static func dedupKey(_ event: CalendarEvent) -> String {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let minute = Int(event.start.timeIntervalSince1970 / 60)
        return "\(minute)|\(title)"
    }

    private static func prefer(_ incoming: CalendarEvent, over existing: CalendarEvent) -> CalendarEvent {
        switch (incoming.joinURL != nil, existing.joinURL != nil) {
        case (true, false): incoming
        case (false, true): existing
        default: existing
        }
    }
}
