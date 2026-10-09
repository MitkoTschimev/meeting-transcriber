import SwiftUI

/// What the live transcript needs to let the user name speakers on the fly:
/// the session's voices, the saved voices to pick from, and the callback that
/// applies a name (relabel every line of that voice + save the voice).
struct LiveSpeakerNaming {
    let speakers: [LiveSessionSpeaker]
    let savedVoiceNames: [String]
    /// Display names from the overlapping calendar event, already filtered
    /// (no self, resources skipped, declined last). Empty when no event.
    let calendarAttendeeNames: [String]
    /// The voice of the latest line while recording, highlighted as speaking.
    let speakingNowID: Int?
    let micLabel: String
    let onAssign: @MainActor (Int, String) -> Void

    /// Picker cap: enough for a team, short enough to scan in a menu.
    static let maxSuggestions = 12

    init(
        speakers: [LiveSessionSpeaker],
        savedVoiceNames: [String],
        speakingNowID: Int?,
        micLabel: String,
        calendarAttendeeNames: [String] = [],
        onAssign: @escaping @MainActor (Int, String) -> Void,
    ) {
        self.speakers = speakers
        self.savedVoiceNames = savedVoiceNames
        self.calendarAttendeeNames = calendarAttendeeNames
        self.speakingNowID = speakingNowID
        self.micLabel = micLabel
        self.onAssign = onAssign
    }

    func speaker(id: Int) -> LiveSessionSpeaker? {
        speakers.first { $0.id == id }
    }

    /// "From calendar" names plus the existing Who-is-this list, with
    /// calendar names dropped from the latter so a saved voice that matches
    /// an attendee is not listed twice.
    func suggestionMenu(for speakerID: Int) -> (calendar: [String], others: [String]) {
        let current = speaker(id: speakerID)?.label.lowercased() ?? ""
        var seen: Set<String> = current.isEmpty ? [] : [current]
        var calendar: [String] = []
        for name in calendarAttendeeNames {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            calendar.append(trimmed)
        }
        let others = suggestions(for: speakerID).filter { name in
            !calendar.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        return (calendar, others)
    }

    /// Names offered for a voice, most useful first: the mic label for a mic
    /// voice (so "that was me" is one click), names already used in this
    /// meeting, then saved voices by recency. Excludes the voice's current
    /// name and duplicates (case-insensitive).
    func suggestions(for speakerID: Int) -> [String] {
        guard let target = speaker(id: speakerID) else { return [] }
        var candidates: [String] = []
        if target.channel == .mic {
            candidates.append(micLabel.isEmpty ? "Me" : micLabel)
        }
        candidates += speakers
            .filter { $0.id != speakerID && $0.source != .placeholder && $0.channel == target.channel }
            .map(\.label)
        candidates += savedVoiceNames

        var seen: Set<String> = [target.label.lowercased()]
        var result: [String] = []
        for name in candidates {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
            if result.count == Self.maxSuggestions { break }
        }
        return result
    }

    /// Text pre-filled in the "New name" field: empty for a placeholder
    /// ("Speaker 2"), the current name otherwise so a typo is a quick fix.
    func draftName(for speakerID: Int) -> String {
        guard let target = speaker(id: speakerID), target.source != .placeholder else { return "" }
        return target.label
    }
}

/// A speaker name that opens the naming menu.
struct LiveSpeakerMenu: View {
    let naming: LiveSpeakerNaming
    let speakerID: Int
    let title: String
    let color: Color
    var showsSpeakingIndicator = false
    let requestNewName: (Int) -> Void

    var body: some View {
        Menu {
            menuItems
        } label: {
            HStack(spacing: 4) {
                if showsSpeakingIndicator {
                    Image(systemName: "waveform")
                        .foregroundStyle(color)
                        .accessibilityLabel("Speaking now")
                }
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(color)
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Who is this? Pick a name or type a new one. All of their lines update and the voice is remembered for future meetings.")
        .accessibilityIdentifier(A11yID.meetingNotesSpeakerMenu(speakerID))
    }

    @ViewBuilder private var menuItems: some View {
        let menu = naming.suggestionMenu(for: speakerID)
        if !menu.calendar.isEmpty {
            Section("From calendar") {
                ForEach(menu.calendar, id: \.self) { name in
                    Button(name) { naming.onAssign(speakerID, name) }
                }
            }
        }
        if !menu.others.isEmpty {
            Section("Who is this?") {
                ForEach(menu.others, id: \.self) { name in
                    Button(name) { naming.onAssign(speakerID, name) }
                }
            }
        }
        if !menu.calendar.isEmpty || !menu.others.isEmpty {
            Divider()
        }
        Button("New name…") { requestNewName(speakerID) }
    }
}

/// "Who's talking" strip above the live transcript: one chip per voice in
/// this meeting, the current speaker marked, each chip opening the same
/// naming menu as the names in the transcript.
struct LiveSpeakerChipsBar: View {
    let naming: LiveSpeakerNaming
    let palette: SpeakerAccent.Palette
    let micLabel: String
    let requestNewName: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(naming.speakers) { speaker in
                    chip(speaker)
                }
            }
        }
        .accessibilityIdentifier(A11yID.meetingNotesSpeakerChips)
    }

    private func chip(_ speaker: LiveSessionSpeaker) -> some View {
        let key = SpeakerAccent.identityKey(speaker.label, micLabel: micLabel, isYou: speaker.isYou)
        let color = palette.color(forKey: key, isYou: speaker.isYou)
        return LiveSpeakerMenu(
            naming: naming,
            speakerID: speaker.id,
            title: SpeakerAccent.displayName(speaker.label, micLabel: micLabel, isYou: speaker.isYou),
            color: color,
            showsSpeakingIndicator: speaker.id == naming.speakingNowID,
            requestNewName: requestNewName,
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(speaker.id == naming.speakingNowID ? 0.18 : 0.08), in: Capsule())
    }
}

/// Hosts the "New name" prompt for the naming menus inside `content`.
struct LiveSpeakerNameAlertHost<Content: View>: View {
    let naming: LiveSpeakerNaming?
    let content: (_ requestNewName: @escaping (Int) -> Void) -> Content

    @State private var pendingID: Int?
    @State private var draft = ""
    /// Kept when the pipeline transcript replaces the live one while the
    /// prompt is open, so Save still applies the name the user typed.
    @State private var heldNaming: LiveSpeakerNaming?

    init(
        naming: LiveSpeakerNaming?,
        @ViewBuilder content: @escaping (_ requestNewName: @escaping (Int) -> Void) -> Content,
    ) {
        self.naming = naming
        self.content = content
    }

    var body: some View {
        content { id in
            heldNaming = naming
            draft = naming?.draftName(for: id) ?? ""
            pendingID = id
        }
        .alert("Who is this?", isPresented: isPresented) {
            TextField("Name", text: $draft)
                .accessibilityIdentifier(A11yID.meetingNotesNewSpeakerName)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) { dismiss() }
        } message: {
            Text("All of their lines in this meeting update. The voice is saved on this Mac only, so future meetings recognise them.")
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { pendingID != nil },
            set: { if !$0 { dismiss() } },
        )
    }

    private func save() {
        if let id = pendingID, let naming = heldNaming ?? naming {
            naming.onAssign(id, draft)
        }
        dismiss()
    }

    private func dismiss() {
        pendingID = nil
        heldNaming = nil
    }
}
