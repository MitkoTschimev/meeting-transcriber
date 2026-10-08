import Foundation

/// One finalized utterance's voice evidence, produced by
/// `LiveSpeakerMatching.identify(audio:)`.
struct LiveSpeakerSample: Equatable, Sendable {
    /// WeSpeaker embedding of the utterance. Empty when none could be
    /// extracted (model not loaded, a test fake): the roster then cannot
    /// cluster and the caller keeps the old channel-default label.
    let embedding: [Float]
    /// Saved voice profile (`speakers.json`) the utterance matched, if any
    /// cleared `SpeakerMatcher`'s threshold and confidence margin.
    let matchedName: String?
    /// Seconds of speech behind the embedding.
    let duration: TimeInterval
}

/// What a user naming should teach the saved voice profiles.
struct VoiceEnrollment: Equatable, Sendable {
    let name: String
    /// Mean embedding of the session speaker's qualifying utterances.
    let embedding: [Float]
    let speakingTime: TimeInterval
}

/// A speaker as the live transcript knows them in this session.
struct LiveSessionSpeaker: Equatable, Identifiable {
    enum LabelSource: Equatable {
        /// Default label ("Me" for the first mic voice, "Speaker N" otherwise).
        case placeholder
        /// Auto-labelled from a saved voice profile.
        case profile
        /// Named by the user during this session.
        case user
    }

    let id: Int
    let channel: LiveCaptionChannel
    var label: String
    var source: LabelSource
    /// Running mean of qualifying utterance embeddings; empty until the
    /// speaker has one utterance long enough to trust.
    var centroid: [Float]
    var centroidSampleCount: Int
    var speakingTime: TimeInterval
    /// The local user (first voice on the mic channel). Cleared when the user
    /// names this voice as someone else, so it stops rendering as "(You)".
    var isYou: Bool
}

/// Session-local speaker identities for the live transcript: clusters the
/// per-utterance embeddings into voices ("Speaker 1", "Speaker 2", ...),
/// carries saved-profile matches onto a whole voice, and turns a user's
/// naming into a `VoiceEnrollment` for the saved profiles.
///
/// Pure value type so the clustering and labelling rules are unit-testable
/// without models or UI. `MeetingNotesSession` owns one per recording.
struct LiveSpeakerRoster: Equatable {
    /// Cosine distance under which an utterance joins an existing voice.
    /// Looser than `SpeakerMatcher`'s 0.40 profile threshold on purpose: a
    /// wrong merge inside one meeting is cheap to fix by renaming, while a
    /// split floods the transcript with "Speaker 7".
    static let clusterDistanceThreshold: Float = 0.5
    /// Utterances shorter than this give embeddings too noisy to found a new
    /// voice or move a centroid; they still join the nearest voice.
    static let minQualifyingDuration: TimeInterval = 1.0
    /// A saved-profile match must speak at least this long before it may
    /// rename a whole voice (and all its earlier lines). Shorter hits are
    /// too easy to fire on a cough or a one-word overlap.
    static let minProfileRelabelDuration: TimeInterval = SpeakerMatcher.minSpeakingTimeForCentroid
    /// Hard cap per channel so a noisy channel cannot invent dozens of voices.
    static let maxSpeakersPerChannel = 8

    struct Resolution: Equatable {
        /// nil when the sample carried no embedding (no voice to attach to).
        let speakerID: Int?
        let label: String
        /// Set when this sample changed an existing voice's label (a later
        /// profile match), so earlier lines must be relabelled too.
        var relabeledSpeakerID: Int?
    }

    struct RenameOutcome: Equatable {
        /// The speaker the renamed lines now belong to (differs from the
        /// renamed id when the name merged two session voices).
        let speakerID: Int
        let label: String
        /// Every session id whose lines must move to `speakerID` / `label`.
        let affectedIDs: [Int]
        /// nil when there is nothing to learn (no qualifying audio yet, or a
        /// generic name such as "Me").
        let enrollment: VoiceEnrollment?
    }

    private(set) var speakers: [LiveSessionSpeaker] = []
    private var nextID = 0
    private var nextPlaceholderNumber = 1

    func speaker(id: Int) -> LiveSessionSpeaker? {
        speakers.first { $0.id == id }
    }

    /// Ids whose voice is on the mic channel but is not the local user.
    var notYouSpeakerIDs: Set<Int> {
        Set(speakers.filter { $0.channel == .mic && !$0.isYou }.map(\.id))
    }

    // MARK: - Resolve

    /// Attach one utterance to a session voice and return its label.
    /// - Parameter fallbackLabel: the channel default (`"Me"` / `"Remote"`),
    ///   used for the first mic voice and when the sample has no embedding.
    mutating func resolve(
        _ sample: LiveSpeakerSample?,
        channel: LiveCaptionChannel,
        fallbackLabel: String,
    ) -> Resolution {
        guard let sample, !sample.embedding.isEmpty else {
            return Resolution(speakerID: nil, label: sample?.matchedName ?? fallbackLabel)
        }
        let nearest = nearestSpeaker(to: sample.embedding, channel: channel)
        let withinThreshold = nearest.map { $0.distance < Self.clusterDistanceThreshold } ?? false
        let nearestHasNoCentroid = nearest.map { speakers[$0.index].centroid.isEmpty } ?? false

        if let matched = sample.matchedName, sample.duration >= Self.minProfileRelabelDuration {
            return resolveMatched(sample, matched: matched, channel: channel, nearest: nearest, withinThreshold: withinThreshold)
        }
        if let nearest, withinThreshold {
            return absorb(sample, intoIndex: nearest.index)
        }
        // A voice founded by a short opening line has no centroid yet. The
        // next qualifying sample of the same channel belongs to it — otherwise
        // "hi" becomes Me and the next sentence becomes Speaker 1 for the rest
        // of the meeting.
        if let nearest, nearestHasNoCentroid {
            return absorb(sample, intoIndex: nearest.index)
        }
        let channelCount = speakers.filter { $0.channel == channel }.count
        let canFound = channelCount == 0
            || (sample.duration >= Self.minQualifyingDuration && channelCount < Self.maxSpeakersPerChannel)
        if canFound || nearest == nil {
            return found(sample, channel: channel, label: placeholderLabel(channel: channel, fallback: fallbackLabel), source: .placeholder)
        }
        // Too short (or channel full) to be a new voice: closest voice wins.
        return absorb(sample, intoIndex: nearest?.index ?? 0)
    }

    private mutating func resolveMatched(
        _ sample: LiveSpeakerSample,
        matched: String,
        channel: LiveCaptionChannel,
        nearest: (index: Int, distance: Float)?,
        withinThreshold: Bool,
    ) -> Resolution {
        // The user's word beats the matcher for a voice they already named.
        if let nearest, withinThreshold, speakers[nearest.index].source == .user {
            return absorb(sample, intoIndex: nearest.index)
        }
        if let index = speakers.firstIndex(where: { $0.channel == channel && $0.label == matched }) {
            return absorb(sample, intoIndex: index)
        }
        if let nearest, speakers[nearest.index].source != .user,
           withinThreshold || speakers[nearest.index].centroid.isEmpty {
            speakers[nearest.index].label = matched
            speakers[nearest.index].source = .profile
            var resolution = absorb(sample, intoIndex: nearest.index)
            resolution.relabeledSpeakerID = speakers[nearest.index].id
            return resolution
        }
        return found(sample, channel: channel, label: matched, source: .profile)
    }

    /// Voices the user named in this session, ready to teach `speakers.json`
    /// once the recording ends. Computed from the *final* name of each voice
    /// so a typo that was then corrected is never written.
    func pendingEnrollments(micLabel: String) -> [VoiceEnrollment] {
        speakers.compactMap { speaker in
            guard speaker.source == .user,
                  !Self.isGenericName(speaker.label, micLabel: micLabel),
                  !speaker.centroid.isEmpty else { return nil }
            return VoiceEnrollment(
                name: speaker.label,
                embedding: speaker.centroid,
                speakingTime: speaker.speakingTime,
            )
        }
    }

    // MARK: - Rename

    /// Name a session voice. Applies to all of its lines; naming it after
    /// another voice in this session merges the two. Returns nil for an
    /// unknown id or a blank name.
    mutating func rename(id: Int, to rawName: String, micLabel: String) -> RenameOutcome? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = speakers.firstIndex(where: { $0.id == id }) else { return nil }
        let isGeneric = Self.isGenericName(name, micLabel: micLabel)

        var affected = [id]
        var targetIndex = index
        if let other = speakers.firstIndex(where: { $0.id != id && $0.channel == speakers[index].channel && $0.label == name }) {
            speakers[other] = Self.merged(speakers[other], absorbing: speakers[index])
            affected = [id, speakers[other].id]
            speakers.remove(at: index)
            targetIndex = other > index ? other - 1 : other
        }
        speakers[targetIndex].label = name
        speakers[targetIndex].source = .user
        if speakers[targetIndex].channel == .mic {
            speakers[targetIndex].isYou = isGeneric
        }

        let target = speakers[targetIndex]
        let enrollment: VoiceEnrollment? = if isGeneric || target.centroid.isEmpty {
            nil
        } else {
            VoiceEnrollment(name: name, embedding: target.centroid, speakingTime: target.speakingTime)
        }
        return RenameOutcome(speakerID: target.id, label: name, affectedIDs: affected, enrollment: enrollment)
    }

    /// Names that describe a role, not a person, and so are never saved as a
    /// voice profile: the mic label ("Me" or the user's name setting) and the
    /// channel defaults.
    static func isGenericName(_ name: String, micLabel: String) -> Bool {
        let generic = ["Me", "Remote", micLabel].filter { !$0.isEmpty }
        return generic.contains { $0.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    // MARK: - Internals

    private func nearestSpeaker(to embedding: [Float], channel: LiveCaptionChannel) -> (index: Int, distance: Float)? {
        var best: (index: Int, distance: Float)?
        for (index, speaker) in speakers.enumerated() where speaker.channel == channel && !speaker.centroid.isEmpty {
            let distance = SpeakerMatcher.cosineDistance(embedding, speaker.centroid)
            if distance < (best?.distance ?? .greatestFiniteMagnitude) {
                best = (index, distance)
            }
        }
        if best == nil, let index = speakers.lastIndex(where: { $0.channel == channel }) {
            // Voices founded only by short utterances have no centroid yet;
            // treat them as far away but still the closest candidate.
            best = (index, .greatestFiniteMagnitude)
        }
        return best
    }

    private mutating func absorb(_ sample: LiveSpeakerSample, intoIndex index: Int) -> Resolution {
        speakers[index].speakingTime += sample.duration
        if sample.duration >= Self.minQualifyingDuration,
           let updated = SpeakerMatcher.updateCentroid(
               current: speakers[index].centroid,
               count: speakers[index].centroidSampleCount,
               with: sample.embedding,
           ) {
            speakers[index].centroid = updated.centroid
            speakers[index].centroidSampleCount = updated.count
        }
        return Resolution(speakerID: speakers[index].id, label: speakers[index].label)
    }

    private mutating func found(
        _ sample: LiveSpeakerSample,
        channel: LiveCaptionChannel,
        label: String,
        source: LiveSessionSpeaker.LabelSource,
    ) -> Resolution {
        let qualifies = sample.duration >= Self.minQualifyingDuration
        let isFirstMicVoice = channel == .mic && !speakers.contains { $0.channel == .mic }
        let speaker = LiveSessionSpeaker(
            id: nextID,
            channel: channel,
            label: label,
            source: source,
            centroid: qualifies ? sample.embedding : [],
            centroidSampleCount: qualifies ? 1 : 0,
            speakingTime: sample.duration,
            // First mic voice is the local user even when a saved profile of
            // their own voice labelled them. Only an explicit rename to
            // someone else clears this.
            isYou: isFirstMicVoice,
        )
        nextID += 1
        speakers.append(speaker)
        return Resolution(speakerID: speaker.id, label: label)
    }

    private mutating func placeholderLabel(channel: LiveCaptionChannel, fallback: String) -> String {
        if channel == .mic, !speakers.contains(where: { $0.channel == .mic }) {
            return fallback
        }
        defer { nextPlaceholderNumber += 1 }
        return "Speaker \(nextPlaceholderNumber)"
    }

    private static func merged(_ keep: LiveSessionSpeaker, absorbing other: LiveSessionSpeaker) -> LiveSessionSpeaker {
        var result = keep
        result.speakingTime += other.speakingTime
        let mergedCentroid = SpeakerMatcher.mergeCentroids(
            a: keep.centroid.isEmpty ? nil : keep.centroid, aCount: keep.centroidSampleCount,
            b: other.centroid.isEmpty ? nil : other.centroid, bCount: other.centroidSampleCount,
        )
        result.centroid = mergedCentroid.centroid ?? []
        result.centroidSampleCount = mergedCentroid.count
        result.isYou = keep.isYou || other.isYou
        return result
    }
}
