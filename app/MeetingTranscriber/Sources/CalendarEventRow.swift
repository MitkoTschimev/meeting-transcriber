import SwiftUI

/// Compact upcoming-meeting row used in Settings and the notes window.
struct CalendarEventRow: View {
    let event: CalendarEvent
    var showsSource: Bool = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(Self.timeLabel(event))
                    if showsSource {
                        Text(event.sourceLabel)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let url = event.joinURL {
                Link("Join", destination: url)
                    .font(.caption)
            }
        }
    }

    static func timeLabel(_ event: CalendarEvent, calendar: Calendar = .current) -> String {
        if event.isAllDay { return "All day" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = calendar.isDateInToday(event.start) ? .none : .short
        return formatter.string(from: event.start)
    }
}
