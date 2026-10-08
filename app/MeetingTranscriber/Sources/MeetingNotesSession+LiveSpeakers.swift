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
    /// in this session merges the two. Names known at Stop are written then
    /// so the pipeline can match them; a correction after Stop renames the
    /// stored profile instead of writing a second one.
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

    /// Write currently named voices to `speakers.json`. Called at Stop and
    /// immediately before the pipeline job is queued, so live names reach
    /// the transcript and summary. Safe to call again: already-written names
    /// are skipped, and a correction since the last call renames the stored
    /// profile rather than creating a duplicate.
    func enrollLiveNamesKnownNow() {
        guard let voiceProfiles else { return }
        let enrollments = speakerRoster.pendingEnrollments(micLabel: micLabel)
        var didWrite = false
        for enrollment in enrollments {
            if let previous = enrolledAtStop[enrollment.speakerID] {
                if previous != enrollment.name {
                    voiceProfiles.renameProfile(from: previous, to: enrollment.name)
                    enrolledAtStop[enrollment.speakerID] = enrollment.name
                    didWrite = true
                }
                continue
            }
            voiceProfiles.enroll(enrollment)
            enrolledAtStop[enrollment.speakerID] = enrollment.name
            didWrite = true
        }
        if didWrite { refreshSavedVoices() }
    }

    /// Flush remaining names: enroll voices named after Stop, and rename a
    /// stored profile when the user corrected a name given at Stop. Names
    /// known at Stop were already written by `enrollLiveNamesKnownNow`.
    func retireLiveRoster() {
        guard !didEnrollNamedVoices else { return }
        didEnrollNamedVoices = true
        enrollLiveNamesKnownNow()
    }
}
