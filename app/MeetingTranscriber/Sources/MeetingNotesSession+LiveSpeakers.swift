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
    /// are skipped; a correction renames only a profile this meeting created,
    /// otherwise enrolls under the new name and withdraws this meeting's
    /// sample from the pre-existing profile.
    func enrollLiveNamesKnownNow() {
        guard let voiceProfiles else { return }
        let enrollments = speakerRoster.pendingEnrollments(micLabel: micLabel)
        let pendingIDs = Set(enrollments.map(\.speakerID))
        var didWrite = false

        let staleIDs = enrolledAtStop.keys.filter { !pendingIDs.contains($0) }
        for id in staleIDs {
            if let previous = enrolledAtStop.removeValue(forKey: id) {
                dropStopEnrollment(previous, using: voiceProfiles)
                didWrite = true
            }
        }

        for enrollment in enrollments {
            if let previous = enrolledAtStop[enrollment.speakerID] {
                if previous.name != enrollment.name {
                    applyPostStopCorrection(from: previous, to: enrollment, using: voiceProfiles)
                    didWrite = true
                }
                continue
            }
            let created = voiceProfiles.enroll(enrollment)
            enrolledAtStop[enrollment.speakerID] = LiveStopEnrollment(
                name: enrollment.name,
                createdProfile: created,
                embedding: enrollment.embedding,
                speakingTime: enrollment.speakingTime,
            )
            didWrite = true
        }
        if didWrite { refreshSavedVoices() }
    }

    /// A post-Stop correction never renames or deletes a profile this meeting
    /// did not create (saved "Bob" corrected to "Rob" must not become "Rob").
    private func applyPostStopCorrection(
        from previous: LiveStopEnrollment,
        to enrollment: VoiceEnrollment,
        using voiceProfiles: any VoiceProfileStoring,
    ) {
        if previous.createdProfile {
            let targetExisted = voiceProfiles.savedVoiceNames().contains { $0 == enrollment.name }
            voiceProfiles.renameProfile(from: previous.name, to: enrollment.name)
            enrolledAtStop[enrollment.speakerID] = LiveStopEnrollment(
                name: enrollment.name,
                createdProfile: !targetExisted,
                embedding: enrollment.embedding,
                speakingTime: enrollment.speakingTime,
            )
            return
        }
        voiceProfiles.withdraw(
            VoiceEnrollment(
                name: previous.name,
                embedding: previous.embedding,
                speakingTime: previous.speakingTime,
                speakerID: enrollment.speakerID,
            ),
            from: previous.name,
        )
        let created = voiceProfiles.enroll(enrollment)
        enrolledAtStop[enrollment.speakerID] = LiveStopEnrollment(
            name: enrollment.name,
            createdProfile: created,
            embedding: enrollment.embedding,
            speakingTime: enrollment.speakingTime,
        )
    }

    /// Generic-name correction or a merge that dropped this voice: delete a
    /// profile we created, otherwise take our sample out of the old one.
    private func dropStopEnrollment(
        _ previous: LiveStopEnrollment,
        using voiceProfiles: any VoiceProfileStoring,
    ) {
        if previous.createdProfile {
            voiceProfiles.deleteProfile(name: previous.name)
            return
        }
        voiceProfiles.withdraw(
            VoiceEnrollment(
                name: previous.name,
                embedding: previous.embedding,
                speakingTime: previous.speakingTime,
            ),
            from: previous.name,
        )
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
