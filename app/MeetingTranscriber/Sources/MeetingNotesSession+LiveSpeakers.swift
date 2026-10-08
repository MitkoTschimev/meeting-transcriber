import Foundation

extension MeetingNotesSession {
    /// Whether the transcript on screen is the live one, whose speakers can
    /// be named. Once the pipeline transcript replaces it, diarized names win
    /// and naming moves to the post-meeting dialog.
    var canNameLiveSpeakers: Bool {
        pipelineTranscript == nil && !speakerRoster.speakers.isEmpty
    }

    /// The voice of the most recent finalized line, for the "speaking now"
    /// highlight.
    var lastLiveSpeakerID: Int? {
        lines.last { $0.speakerID != nil }?.speakerID
    }

    /// Attach a finalized utterance to a session voice (see
    /// `LiveCaptionsState.resolveSpeaker`). A later profile match that names
    /// an earlier "Speaker N" relabels that voice's earlier lines too.
    func resolveLiveSpeaker(
        _ sample: LiveSpeakerSample?,
        channel: LiveCaptionChannel,
        fallbackLabel: String,
    ) -> LiveSpeakerRoster.Resolution {
        if phase == .idle { begin(title: "Meeting", appName: "") }
        let resolution = speakerRoster.resolve(sample, channel: channel, fallbackLabel: fallbackLabel)
        if let relabeled = resolution.relabeledSpeakerID {
            relabelLines(ids: [relabeled], toID: relabeled, label: resolution.label)
        }
        return resolution
    }

    /// Name (or rename) a session voice: every line of that voice takes the
    /// name now and later lines arrive with it. Naming it after another voice
    /// in this session merges the two. The voice is written to `speakers.json`
    /// only when the live roster is retired, so a typo that is then corrected
    /// is never saved, and Alice→Bob does not leave the embedding folded into Alice.
    func renameLiveSpeaker(id: Int, to name: String) {
        guard let outcome = speakerRoster.rename(id: id, to: name, micLabel: micLabel) else { return }
        relabelLines(ids: Set(outcome.affectedIDs), toID: outcome.speakerID, label: outcome.label)
        let isYou = speakerRoster.speaker(id: outcome.speakerID)?.isYou ?? false
        registerSpeaker(outcome.label, isYou: isYou)
    }

    func refreshSavedVoices() {
        let names = voiceProfiles?.savedVoiceNames() ?? []
        if names != savedVoiceNames { savedVoiceNames = names }
    }

    /// Write each user-named voice to the saved profiles once, under its
    /// final name. Called when the live roster is retired — not on Stop,
    /// so a name given or corrected after Stop is what gets saved.
    func retireLiveRoster() {
        guard !didEnrollNamedVoices else { return }
        didEnrollNamedVoices = true
        guard let voiceProfiles else { return }
        let enrollments = speakerRoster.pendingEnrollments(micLabel: micLabel)
        guard !enrollments.isEmpty else { return }
        for enrollment in enrollments {
            voiceProfiles.enroll(enrollment)
        }
        refreshSavedVoices()
    }
}
