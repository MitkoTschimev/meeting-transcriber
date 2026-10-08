import AppKit
import Foundation
import Observation

/// Lifecycle of the meeting-notes window for the current (or last) session.
enum MeetingNotesPhase: Equatable {
    case idle
    case recording
    case processing
    case generatingNotes
    case ready
    case failed
}

/// Rolling transcript + notes for one meeting, shown in the dedicated notes
/// window. Distinct from `LiveCaptionsState`: the overlay keeps two lines and
/// auto-clears on silence; this keeps the whole session so the user can read
/// it back, and holds generated notes once the pipeline writes them.
///
/// Fed from two places:
///   - live caption finals/partials (`LiveCaptionsState` forwards here)
///   - the post-recording pipeline (`sync(from:)` reads transcript/protocol files)
@Observable
@MainActor
final class MeetingNotesSession {
    private(set) var title: String = ""
    private(set) var appName: String = ""
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?
    private(set) var phase: MeetingNotesPhase = .idle
    private(set) var lines: [LiveCaptionLine] = []
    private(set) var hypothesisMic: String = ""
    private(set) var hypothesisApp: String = ""
    private(set) var pipelineTranscript: String?
    private(set) var notesMarkdown: String?
    private(set) var jobID: UUID?
    private(set) var errorMessage: String?
    private(set) var warnings: [String] = []
    private(set) var speakerPalette = SpeakerAccent.Palette()
    /// Set when saved notes are an LLM error (not usable Markdown) or when
    /// generation threw and left only a warning. Distinct from `phase ==
    /// .failed`, which is a pipeline/job error.
    private(set) var notesFailure: ProtocolNotesFailure?
    /// True while `retryNotes` is awaiting the protocol generator.
    private(set) var isRetryingNotes = false
    /// Voices heard in this session; naming one relabels all of its lines
    /// and teaches the saved voice profiles. Reset with every new session.
    var speakerRoster = LiveSpeakerRoster()
    /// Saved voice names offered when naming a speaker, most recent first.
    var savedVoiceNames: [String] = []
    /// Saved voice profiles (`speakers.json` in production). nil in tests that
    /// do not exercise naming, and then naming is session-only.
    @ObservationIgnored var voiceProfiles: (any VoiceProfileStoring)? {
        didSet { refreshSavedVoices() }
    }

    /// Overlay buffer that mirrors live lines. Relabel after a naming so the
    /// caption bar does not keep the old "Speaker N".
    @ObservationIgnored var onSpeakerRelabel: ((Set<Int>, Int, String) -> Void)?
    /// True once this session's named voices have been written. A later
    /// `retireLiveRoster` (pipeline transcript, next `begin`, quit) is a no-op.
    var didEnrollNamedVoices = false
    /// Names already written at Stop, keyed by session speaker id. Retire
    /// enrolls only names added after Stop. A correction renames the stored
    /// profile only when this meeting created it; otherwise it enrolls under
    /// the new name and withdraws this meeting's sample from the old one.
    var enrolledAtStop: [Int: LiveStopEnrollment] = [:]

    /// Private scratchpad for the My thoughts tab. Never written into the
    /// transcript, summary, or protocol files. Keystrokes debounce to disk;
    /// finish / adopt / begin flush immediately.
    var thoughts: String = "" {
        didSet {
            guard !isLoadingThoughts, thoughts != oldValue else { return }
            schedulePersistThoughts()
        }
    }

    /// Paths already loaded, so `sync` does not re-read the same file every
    /// job-state tick.
    private var loadedTranscriptPath: URL?
    private var loadedNotesPath: URL?
    private let thoughtsStore: MeetingThoughtsStore?
    private var thoughtsURL: URL?
    private var isLoadingThoughts = false
    private var persistTask: Task<Void, Never>?
    private let persistDelay: Duration
    var micLabel: String = ""

    /// Whether this recording episode already asked the scene to show the
    /// notes window. Reset when `begin` starts a new session, not when a
    /// second call only fills in the meeting title.
    private(set) var didAutoOpenWindow = false

    /// Jobs enqueued a beat before `startedAt` still belong to this session
    /// (clock skew between watch-loop stop and pipeline enqueue).
    private static let enqueueMatchSlack: TimeInterval = 2

    init(
        thoughtsStore: MeetingThoughtsStore? = nil,
        persistDelay: Duration = .milliseconds(400),
        voiceProfiles: (any VoiceProfileStoring)? = nil,
    ) {
        self.thoughtsStore = thoughtsStore
        self.persistDelay = persistDelay
        self.voiceProfiles = voiceProfiles
        thoughtsStore?.pruneInProgress()
        refreshSavedVoices()
        // Names given after Stop live on the roster until it is retired.
        // Quit has no next `begin` and may never adopt a pipeline transcript
        // (record-only), so flush here. The session lives for the process.
        // swiftlint:disable:next discarded_notification_center_observer
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.retireLiveRoster()
            }
        }
    }

    func setMicLabel(_ label: String) {
        micLabel = label
    }

    var hasSession: Bool {
        phase != .idle || !lines.isEmpty || pipelineTranscript != nil || notesMarkdown != nil
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Meeting" : trimmed
    }

    /// Live lines plus in-flight hypotheses. Used by the Transcript tab while
    /// a recording is running; once a pipeline transcript exists it wins.
    var liveTranscriptText: String {
        var rows: [String] = lines.map { "\($0.speaker): \($0.text)" }
        if !hypothesisApp.isEmpty {
            rows.append("\(RemoteHypothesisLabel.app): \(hypothesisApp)")
        }
        if !hypothesisMic.isEmpty {
            rows.append("\(RemoteHypothesisLabel.mic): \(hypothesisMic)")
        }
        return rows.joined(separator: "\n\n")
    }

    var transcriptText: String {
        if let pipelineTranscript, !pipelineTranscript.isEmpty {
            return pipelineTranscript
        }
        return liveTranscriptText
    }

    var hasTranscript: Bool {
        !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canRetryNotes: Bool {
        notesFailure != nil && hasTranscript && jobID != nil && !isRetryingNotes
    }

    var transcriptLooksLong: Bool {
        transcriptText.count > ProtocolTranscriptChunker.directCharacterLimit
    }

    var draftActionItems: [String] {
        ActionItemDraft.items(from: lines)
    }

    func turns(micLabel: String) -> [TranscriptTurn] {
        TranscriptTurn.build(
            liveLines: lines,
            hypothesisMic: hypothesisMic,
            hypothesisApp: hypothesisApp,
            pipelineTranscript: pipelineTranscript,
            micLabel: micLabel,
            notYouSpeakerIDs: speakerRoster.notYouSpeakerIDs,
        )
    }

    /// Append-only palette so live→diarized handoff keeps first-seen colors.
    /// Pure merge — does not store, so SwiftUI body can call it freely.
    func palette(for turns: [TranscriptTurn], micLabel: String) -> SpeakerAccent.Palette {
        TranscriptTurn.palette(for: turns, micLabel: micLabel, existing: speakerPalette)
    }

    func duration(at now: Date = Date()) -> TimeInterval {
        guard let startedAt else { return 0 }
        let end = endedAt ?? now
        return max(0, end.timeIntervalSince(startedAt))
    }

    /// Start (or retitle) the live session. A second call while still recording
    /// only fills in the real meeting title — live captions can arrive before
    /// the watch loop publishes `.recording`.
    func begin(title: String, appName: String, startTime: Date = Date()) {
        if phase == .recording, endedAt == nil {
            if !title.isEmpty { self.title = title }
            if !appName.isEmpty { self.appName = appName }
            return
        }
        persistThoughtsNow()
        resetContents()
        self.title = title
        self.appName = appName
        startedAt = startTime
        endedAt = nil
        phase = .recording
        thoughtsURL = thoughtsStore?.inProgressURL()
        thoughtsStore?.pruneInProgress(keeping: thoughtsURL)
        loadThoughtsFromCurrentURL()
    }

    func markWindowAutoOpened() {
        didAutoOpenWindow = true
    }

    /// Test seam: production posts `.showMeetingNotes` so the scene brings
    /// the window forward. Tests replace this to count presentations without
    /// racing a shared `NotificationCenter` under `swift test --parallel`.
    var presentWindow: () -> Void = {
        NotificationCenter.default.post(name: .showMeetingNotes, object: nil)
    }

    func presentWindowIfNeeded(enabled: Bool) {
        guard MeetingNotesAutoOpen.shouldPresent(
            enabled: enabled,
            alreadyPresentedForSession: didAutoOpenWindow,
        ) else { return }
        markWindowAutoOpened()
        presentWindow()
    }

    func finishRecording(recordOnly: Bool = false) {
        guard phase == .recording else { return }
        persistThoughtsNow()
        // Names known now must be in speakers.json before the pipeline's
        // matchVerbose (which runs before the transcript is adopted).
        enrollLiveNamesKnownNow()
        endedAt = Date()
        hypothesisMic = ""
        hypothesisApp = ""
        // Record-only never enqueues a pipeline job. Stay out of `.processing`
        // so Summary does not sit on the generating placeholder forever.
        phase = recordOnly ? .ready : .processing
    }

    func applyPartial(_ text: String, channel: LiveCaptionChannel) {
        if phase == .idle { begin(title: "Meeting", appName: "") }
        switch channel {
        case .mic: hypothesisMic = text
        case .app: hypothesisApp = text
        }
    }

    func applyFinalized(_ text: String, channel: LiveCaptionChannel, speaker: String, speakerID: Int? = nil) {
        if phase == .idle { begin(title: "Meeting", appName: "") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch channel {
        case .mic: hypothesisMic = ""
        case .app: hypothesisApp = ""
        }
        lines.append(LiveCaptionLine(channel: channel, text: trimmed, speaker: speaker, speakerID: speakerID))
        let isYou = speakerID.map { !speakerRoster.notYouSpeakerIDs.contains($0) } ?? true
        registerSpeaker(speaker, isYou: channel == .mic && isYou)
    }

    func applyGeneratedNotes(_ markdown: String) {
        adoptNotesMarkdown(markdown)
    }

    /// Re-run notes generation from the existing transcript. Progress uses
    /// `isRetryingNotes` so Summary shows the generating placeholder without
    /// treating a `.done` job as finished notes.
    func retryNotes(using queue: PipelineQueue) async {
        guard canRetryNotes, let jobID else { return }
        isRetryingNotes = true
        defer { isRetryingNotes = false }
        _ = await queue.retryProtocolGeneration(jobID: jobID)
        loadedNotesPath = nil
        sync(from: queue)
    }

    /// Pull transcript / notes / phase from the pipeline once a job exists.
    /// While recording this does not bind a job — an older same-title meeting
    /// must not replace the live transcript. After `finishRecording`, only jobs
    /// enqueued at or after `startedAt` (with a small clock-skew slack). A
    /// cold idle window may restore the newest completed job.
    func sync(from queue: PipelineQueue) {
        if micLabel.isEmpty, !queue.micLabel.isEmpty {
            micLabel = queue.micLabel
        }
        if shouldDeferJobBinding { return }
        guard let job = matchingJob(in: queue) else {
            // Record-only (or any finish that never enqueued) has no job to
            // wait on. Leave `.processing` only while recent pipeline work exists.
            if phase == .processing, !hasRecentPipelineWork(in: queue) {
                phase = .ready
            }
            return
        }
        jobID = job.id
        if title.isEmpty { title = job.meetingTitle }
        if appName.isEmpty { appName = job.appName }
        if startedAt == nil { startedAt = job.meetingStartTime ?? job.enqueuedAt }

        applyPhase(from: job)
        adoptThoughtsFile(for: job)

        if let path = job.transcriptPath, path != loadedTranscriptPath,
           let text = Self.readFile(path) {
            pipelineTranscript = text
            loadedTranscriptPath = path
            retireLiveRoster()
            rememberPipelineSpeakers(text)
        }
        if let path = job.protocolPath, path != loadedNotesPath,
           let text = Self.readFile(path) {
            loadedNotesPath = path
            adoptNotesMarkdown(text)
        } else if job.protocolPath == nil {
            loadedNotesPath = nil
            if notesFailure == nil {
                notesMarkdown = nil
            }
        }
        if notesMarkdown == nil, notesFailure == nil,
           let failure = ProtocolNotesFailure.detecting(warnings: job.warnings) {
            notesFailure = failure
            errorMessage = failure.userMessage
        }
        if job.state == .error {
            errorMessage = job.error
        }
    }

    /// Treat error-string "notes" as a failure so Retry appears for meetings
    /// already saved with "chat completion failed" as the protocol body.
    private func adoptNotesMarkdown(_ markdown: String) {
        if let failure = ProtocolNotesFailure.detectingSavedContent(markdown) {
            notesMarkdown = nil
            notesFailure = failure
            errorMessage = failure.userMessage
            if phase != .failed { phase = .ready }
            return
        }
        notesMarkdown = markdown
        notesFailure = nil
        if !markdown.isEmpty, phase != .failed {
            phase = .ready
            errorMessage = nil
        }
    }

    /// Recording has no pipeline job yet. Binding by title / newest job would
    /// load another meeting's transcript and notes into this session. Idle is
    /// allowed to restore the newest completed job.
    private var shouldDeferJobBinding: Bool {
        phase == .recording
    }

    private func applyPhase(from job: PipelineJob) {
        warnings = job.warnings
        switch job.state {
        case .waiting, .transcribing, .diarizing, .speakerNamingPending:
            if phase == .recording { return }
            phase = .processing

        case .generatingProtocol:
            phase = .generatingNotes

        case .done:
            // Record-only and failed protocol generation both finish `.done`
            // with no protocol file. Summary must leave the generating
            // placeholder; `.failed` is reserved for `.error`.
            phase = .ready

        case .error:
            phase = .failed
        }
    }

    private func matchingJob(in queue: PipelineQueue) -> PipelineJob? {
        let all = queue.jobs
        if let jobID, let match = all.first(where: { $0.id == jobID }) {
            return match
        }
        if phase == .idle {
            return queue.completedJobs.max { $0.enqueuedAt < $1.enqueuedAt }
        }
        let started = (startedAt ?? .distantPast).addingTimeInterval(-Self.enqueueMatchSlack)
        let recent = all.filter { $0.enqueuedAt >= started }
        guard !recent.isEmpty else { return nil }

        if !title.isEmpty {
            let titled = recent.filter { $0.meetingTitle == title }
            if let newest = titled.max(by: { $0.enqueuedAt < $1.enqueuedAt }) {
                return newest
            }
        }
        let activeIDs = Set(queue.activeJobs.map(\.id))
        if let active = recent.first(where: { activeIDs.contains($0.id) }) {
            return active
        }
        return recent.max { $0.enqueuedAt < $1.enqueuedAt }
    }

    private func hasRecentPipelineWork(in queue: PipelineQueue) -> Bool {
        let started = (startedAt ?? .distantPast).addingTimeInterval(-Self.enqueueMatchSlack)
        return queue.jobs.contains { job in
            job.enqueuedAt >= started && !job.state.isTerminal
        }
    }

    func relabelLines(ids: Set<Int>, toID: Int, label: String) {
        lines = lines.map { line in
            guard let id = line.speakerID, ids.contains(id) else { return line }
            return LiveCaptionLine(channel: line.channel, text: line.text, speaker: label, speakerID: toID)
        }
        onSpeakerRelabel?(ids, toID, label)
    }

    func registerSpeaker(_ raw: String, isYou: Bool) {
        speakerPalette.register(SpeakerAccent.identityKey(raw, micLabel: micLabel, isYou: isYou))
    }

    private func rememberPipelineSpeakers(_ transcript: String) {
        let parsed = TranscriptTurn.parsePipeline(transcript, micLabel: micLabel)
        speakerPalette = TranscriptTurn.palette(
            for: parsed,
            micLabel: micLabel,
            existing: speakerPalette,
        )
    }

    private func resetContents() {
        retireLiveRoster()
        persistTask?.cancel()
        persistTask = nil
        isLoadingThoughts = true
        lines.removeAll()
        hypothesisMic = ""
        hypothesisApp = ""
        pipelineTranscript = nil
        notesMarkdown = nil
        jobID = nil
        errorMessage = nil
        notesFailure = nil
        isRetryingNotes = false
        warnings = []
        loadedTranscriptPath = nil
        loadedNotesPath = nil
        thoughts = ""
        thoughtsURL = nil
        speakerPalette = SpeakerAccent.Palette()
        speakerRoster = LiveSpeakerRoster()
        didEnrollNamedVoices = false
        enrolledAtStop = [:]
        refreshSavedVoices()
        didAutoOpenWindow = false
        isLoadingThoughts = false
    }

    private func loadThoughtsFromCurrentURL() {
        guard let thoughtsStore, let thoughtsURL else { return }
        isLoadingThoughts = true
        thoughts = thoughtsStore.load(from: thoughtsURL) ?? ""
        isLoadingThoughts = false
    }

    private func persistThoughtsNow() {
        persistTask?.cancel()
        persistTask = nil
        guard let thoughtsStore, let thoughtsURL else { return }
        thoughtsStore.save(thoughts, to: thoughtsURL)
    }

    private func schedulePersistThoughts() {
        persistTask?.cancel()
        guard let thoughtsStore, let thoughtsURL else { return }
        let text = thoughts
        let delay = persistDelay
        persistTask = Task.detached {
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            thoughtsStore.save(text, to: thoughtsURL)
        }
    }

    private func adoptThoughtsFile(for job: PipelineJob) {
        guard let thoughtsStore else { return }
        let jobURL = thoughtsStore.url(for: job)
        persistThoughtsNow()
        if thoughtsURL != jobURL {
            if let previous = thoughtsURL, previous != jobURL {
                thoughtsStore.remove(previous)
            }
            thoughtsURL = jobURL
        }
        if thoughts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let stored = thoughtsStore.load(from: jobURL) {
            isLoadingThoughts = true
            thoughts = stored
            isLoadingThoughts = false
        } else {
            persistThoughtsNow()
        }
    }

    private static func readFile(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text
    }
}

/// Channel-default labels used only for in-flight hypothesis rows. Finals
/// carry their own speaker, captured at commit time.
private enum RemoteHypothesisLabel {
    static let mic = "Me"
    static let app = "Remote"
}
