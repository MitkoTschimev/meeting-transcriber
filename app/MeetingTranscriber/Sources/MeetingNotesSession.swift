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

    /// Private scratchpad for the My thoughts tab. Never written into the
    /// transcript, summary, or protocol files.
    var thoughts: String = "" {
        didSet {
            guard !isLoadingThoughts, thoughts != oldValue else { return }
            persistThoughts()
        }
    }

    /// Paths already loaded, so `sync` does not re-read the same file every
    /// job-state tick.
    private var loadedTranscriptPath: URL?
    private var loadedNotesPath: URL?
    private let thoughtsStore: MeetingThoughtsStore?
    private var thoughtsURL: URL?
    private var isLoadingThoughts = false

    init(thoughtsStore: MeetingThoughtsStore? = nil) {
        self.thoughtsStore = thoughtsStore
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
        persistThoughts()
        resetContents()
        self.title = title
        self.appName = appName
        startedAt = startTime
        endedAt = nil
        phase = .recording
        thoughtsURL = thoughtsStore?.inProgressURL(startedAt: startTime)
        loadThoughtsFromCurrentURL()
    }

    func finishRecording() {
        guard phase == .recording else { return }
        endedAt = Date()
        hypothesisMic = ""
        hypothesisApp = ""
        phase = .processing
    }

    func applyPartial(_ text: String, channel: LiveCaptionChannel) {
        if phase == .idle { begin(title: "Meeting", appName: "") }
        switch channel {
        case .mic: hypothesisMic = text
        case .app: hypothesisApp = text
        }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            registerSpeaker(channel == .mic ? "Me" : "Remote", isYou: channel == .mic)
        }
    }

    func applyFinalized(_ text: String, channel: LiveCaptionChannel, speaker: String) {
        if phase == .idle { begin(title: "Meeting", appName: "") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch channel {
        case .mic: hypothesisMic = ""
        case .app: hypothesisApp = ""
        }
        lines.append(LiveCaptionLine(channel: channel, text: trimmed, speaker: speaker))
        registerSpeaker(speaker, isYou: channel == .mic)
    }

    func applyGeneratedNotes(_ markdown: String) {
        notesMarkdown = markdown
        if !markdown.isEmpty {
            phase = .ready
        }
    }

    /// Pull transcript / notes / phase from the pipeline once a job exists.
    /// While recording (or before the session has ended) this does not bind a
    /// job — an older same-title meeting must not replace the live transcript.
    /// After `finishRecording`, only jobs enqueued at or after `startedAt`.
    func sync(from queue: PipelineQueue) {
        if shouldDeferJobBinding { return }
        guard let job = matchingJob(in: queue) else { return }
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
            rememberPipelineSpeakers(text)
        }
        if let path = job.protocolPath, path != loadedNotesPath,
           let text = Self.readFile(path) {
            notesMarkdown = text
            loadedNotesPath = path
            if phase != .failed { phase = .ready }
        }
        if job.state == .error {
            errorMessage = job.error
        }
    }

    /// Recording has no pipeline job yet. Binding by title / newest job would
    /// load another meeting's transcript and notes into this session.
    private var shouldDeferJobBinding: Bool {
        phase == .recording || (jobID == nil && endedAt == nil)
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
        let started = startedAt ?? .distantPast
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

    private func registerSpeaker(_ raw: String, isYou: Bool) {
        speakerPalette.register(SpeakerAccent.identityKey(raw, micLabel: "", isYou: isYou))
    }

    private func rememberPipelineSpeakers(_ transcript: String) {
        let parsed = TranscriptTurn.parsePipeline(transcript, micLabel: "")
        speakerPalette = TranscriptTurn.palette(for: parsed, micLabel: "", existing: speakerPalette)
    }

    private func resetContents() {
        isLoadingThoughts = true
        lines.removeAll()
        hypothesisMic = ""
        hypothesisApp = ""
        pipelineTranscript = nil
        notesMarkdown = nil
        jobID = nil
        errorMessage = nil
        warnings = []
        loadedTranscriptPath = nil
        loadedNotesPath = nil
        thoughts = ""
        thoughtsURL = nil
        speakerPalette = SpeakerAccent.Palette()
        isLoadingThoughts = false
    }

    private func loadThoughtsFromCurrentURL() {
        guard let thoughtsStore, let thoughtsURL else { return }
        isLoadingThoughts = true
        thoughts = thoughtsStore.load(from: thoughtsURL) ?? ""
        isLoadingThoughts = false
    }

    private func persistThoughts() {
        guard let thoughtsStore, let thoughtsURL else { return }
        thoughtsStore.save(thoughts, to: thoughtsURL)
    }

    private func adoptThoughtsFile(for job: PipelineJob) {
        guard let thoughtsStore, let sibling = MeetingThoughtsStore.siblingURL(of: job) else {
            return
        }
        if thoughtsURL != sibling {
            if let previous = thoughtsURL, previous != sibling {
                thoughtsStore.remove(previous)
            }
            thoughtsURL = sibling
        }
        if thoughts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let stored = thoughtsStore.load(from: sibling) {
            isLoadingThoughts = true
            thoughts = stored
            isLoadingThoughts = false
        } else {
            persistThoughts()
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
