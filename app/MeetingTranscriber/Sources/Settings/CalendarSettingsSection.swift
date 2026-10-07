import SwiftUI

/// Settings → General → Calendars. Connect/disconnect for Apple (EventKit)
/// and Google (OAuth), plus today's upcoming meetings.
struct CalendarSettingsSection: View {
    @Bindable var settings: AppSettings
    var calendar: CalendarController?

    var body: some View {
        Section("Calendars") {
            appleRow
            googleRow
            if let lastError = calendar?.lastError, !lastError.isEmpty {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(A11yID.calendarError)
            }
            upcoming
        }
        .onAppear {
            Task { await calendar?.refresh() }
        }
        .onChange(of: settings.appleCalendarEnabled) { _, enabled in
            calendar?.appleToggled(enabled)
        }
        .onChange(of: settings.googleCalendarEnabled) { _, _ in
            Task { await calendar?.refresh() }
        }
    }

    private var appleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HelpfulToggle(
                title: "Apple Calendar",
                help: SettingsHelp.appleCalendar,
                isOn: $settings.appleCalendarEnabled,
            )
            .accessibilityIdentifier(A11yID.appleCalendarToggle)
            Text(appleStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var googleRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpfulToggle(
                title: "Google Calendar",
                help: SettingsHelp.googleCalendar,
                isOn: $settings.googleCalendarEnabled,
            )
            .accessibilityIdentifier(A11yID.googleCalendarToggle)
            .disabled(calendar?.googleConnected != true)
            Text(googleStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("OAuth client ID", text: $settings.googleOAuthClientID)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier(A11yID.googleOAuthClientIDField)
                if calendar?.googleConnected == true {
                    Button("Disconnect") {
                        Task { await calendar?.disconnectGoogle() }
                    }
                    .accessibilityIdentifier(A11yID.googleCalendarDisconnect)
                } else {
                    Button(calendar?.isConnectingGoogle == true ? "Connecting…" : "Connect") {
                        Task { await calendar?.connectGoogle() }
                    }
                    .disabled(calendar?.isConnectingGoogle == true || clientID.isEmpty)
                    .accessibilityIdentifier(A11yID.googleCalendarConnect)
                }
            }
        }
    }

    @ViewBuilder private var upcoming: some View {
        if let events = calendar?.upcoming, !events.isEmpty {
            Text("Upcoming")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(events) { event in
                CalendarEventRow(event: event)
            }
        } else if settings.appleCalendarEnabled || (calendar?.googleConnected == true && settings.googleCalendarEnabled) {
            Text("No upcoming meetings on connected calendars.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var clientID: String {
        GoogleOAuthConfig.clientID(settingsValue: settings.googleOAuthClientID)
    }

    private var appleStatusText: String {
        switch calendar?.appleStatus ?? .notDetermined {
        case .granted:
            "macOS Calendar access granted, including iCloud and accounts added in Calendar."

        case .denied:
            "Calendar access denied. Enable Meeting Transcriber in System Settings → Privacy & Security → Calendars."

        case .restricted:
            "Calendar access is restricted on this Mac."

        case .notDetermined:
            "Turning this on asks macOS for Calendar access."
        }
    }

    private var googleStatusText: String {
        if let email = calendar?.googleEmail, calendar?.googleConnected == true {
            return "Connected as \(email)."
        }
        if calendar?.googleConnected == true {
            return "Connected. Events are fetched directly from Google."
        }
        if clientID.isEmpty {
            return "Paste a Google Cloud Desktop OAuth client ID, then click Connect."
        }
        return "Not connected. Connect opens Google in the browser and stores tokens in the Keychain."
    }
}
