import Foundation

/// Where live speaker naming reads and writes saved voice profiles.
/// Injectable so `MeetingNotesSession` tests do not touch `speakers.json`.
@MainActor
protocol VoiceProfileStoring: AnyObject {
    /// Saved voice names for the naming picker, most recently used first.
    func savedVoiceNames() -> [String]
    /// Add (or fold into) the saved profile for `enrollment.name`.
    func enroll(_ enrollment: VoiceEnrollment)
    /// Rename a stored profile. A post-Stop correction must rename, not
    /// create a second profile under the new name.
    func renameProfile(from: String, to: String)
}

/// Production store: the same on-device `speakers.json` (Application Support,
/// owner-only) the post-meeting naming dialog and Settings → Speakers use, so
/// a voice named live is recognised by the live matcher straight away, by the
/// batch pipeline after the meeting, and can be renamed or deleted under
/// Settings → Speakers → Known voices. Nothing leaves the machine.
@MainActor
final class SpeakerDBVoiceProfileStore: VoiceProfileStoring {
    private let dbPath: URL
    private let onChange: () -> Void
    /// Avoid re-decoding `speakers.json` on the main thread every time the
    /// naming menu is composed. Invalidated when the file's mtime changes
    /// (this store's enroll, Settings → Speakers, post-meeting naming).
    private var cachedNames: [String] = []
    private var namesLoaded = false
    private var cachedModificationDate: Date?

    /// - Parameter onChange: invalidates caches that mirror the DB
    ///   (`PipelineQueue.knownSpeakerNames`), as KnownVoices' `onMutate` does.
    init(dbPath: URL = AppPaths.speakersDB, onChange: @escaping () -> Void = {}) {
        self.dbPath = dbPath
        self.onChange = onChange
    }

    func savedVoiceNames() -> [String] {
        let mtime = modificationDate()
        if namesLoaded, mtime == cachedModificationDate { return cachedNames }
        cachedNames = Self.loadNames(dbPath: dbPath)
        cachedModificationDate = mtime
        namesLoaded = true
        return cachedNames
    }

    /// Reuses `SpeakerMatcher.updateDB`, so a correction behaves exactly like
    /// a post-meeting confirmation: a new name creates a profile, an existing
    /// one gets the embedding folded into its running-mean centroid (when the
    /// voice spoke long enough) and its recent-samples FIFO.
    func enroll(_ enrollment: VoiceEnrollment) {
        guard !enrollment.embedding.isEmpty else { return }
        let label = "live-\(UUID().uuidString)"
        SpeakerMatcher(dbPath: dbPath).updateDB(
            mapping: [label: enrollment.name],
            embeddings: [label: enrollment.embedding],
            speakingTimes: [label: enrollment.speakingTime],
        )
        namesLoaded = false
        cachedModificationDate = nil
        onChange()
    }

    func renameProfile(from: String, to: String) {
        guard from != to else { return }
        SpeakerMatcher(dbPath: dbPath).renameSpeaker(from: from, to: to)
        namesLoaded = false
        cachedModificationDate = nil
        onChange()
    }

    private func modificationDate() -> Date? {
        try? dbPath.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    nonisolated private static func loadNames(dbPath: URL) -> [String] {
        let speakers = SpeakerMatcher(dbPath: dbPath).loadDB().filter { !$0.isSynthetic }
        return SpeakerMatcher.rankByRecency(speakers: speakers).map(\.name)
    }
}
