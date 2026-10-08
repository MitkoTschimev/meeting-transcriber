import SwiftUI

/// What the live transcript needs to let the user name speakers on the fly:
/// the session's voices, the saved voices to pick from, and the callback that
/// applies a name (relabel every line of that voice + save the voice).
struct LiveSpeakerNaming {
    let speakers: [LiveSessionSpeaker]
    let savedVoiceNames: [String]
    /// The voice of the latest line while recording, highlighted as speaking.
    let speakingNowID: Int?
    let micLabel: String
    let onAssign: @MainActor (Int, String) -> Void

    /// Picker cap: enough for a team, short enough to scan in a menu.
    static let maxSuggestions = 12

    func speaker(id: Int) -> LiveSessionSpeaker? {
        speakers.first { $0.id == id }
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
        .accessibilityIdentifier(A11yID.meetingNotesSpeakerMenu)
    }

    @ViewBuilder private var menuItems: some View {
        let names = naming.suggestions(for: speakerID)
        if !names.isEmpty {
            Section("Who is this?") {
                ForEach(names, id: \.self) { name in
                    Button(name) { naming.onAssign(speakerID, name) }
                }
            }
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

    init(
        naming: LiveSpeakerNaming?,
        @ViewBuilder content: @escaping (_ requestNewName: @escaping (Int) -> Void) -> Content,
    ) {
        self.naming = naming
        self.content = content
    }

    var body: some View {
        content { id in
            draft = naming?.draftName(for: id) ?? ""
            pendingID = id
        }
        .alert("Who is this?", isPresented: isPresented) {
            TextField("Name", text: $draft)
                .accessibilityIdentifier(A11yID.meetingNotesNewSpeakerName)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) { pendingID = nil }
        } message: {
            Text("All of their lines in this meeting update. The voice is saved on this Mac only, so future meetings recognise them.")
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { pendingID != nil },
            set: { if !$0 { pendingID = nil } },
        )
    }

    private func save() {
        if let id = pendingID, let naming {
            naming.onAssign(id, draft)
        }
        pendingID = nil
    }
}
