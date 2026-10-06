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

    /// Private scratchpad for the My thoughts tab. Never written into the
    /// transcript, summary, or protocol files.
    var thoughts: String = ""

    /// Paths already loaded, so `sync` does not re-read the same file every
    /// job-state tick.
    private var loadedTranscriptPath: URL?
    private var loadedNotesPath: URL?

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
        resetContents()
        self.title = title
        self.appName = appName
        startedAt = startTime
        endedAt = nil
        phase = .recording
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
    }

    func applyGeneratedNotes(_ markdown: String) {
        notesMarkdown = markdown
        if !markdown.isEmpty {
            phase = .ready
        }
    }

    /// Pull transcript / notes / phase from the pipeline once a job exists.
    /// Matching prefers `jobID`, then the same meeting title, then the newest job.
    func sync(from queue: PipelineQueue) {
        guard let job = matchingJob(in: queue) else { return }
        jobID = job.id
        if title.isEmpty { title = job.meetingTitle }
        if appName.isEmpty { appName = job.appName }
        if startedAt == nil { startedAt = job.meetingStartTime ?? job.enqueuedAt }

        applyPhase(from: job)

        if let path = job.transcriptPath, path != loadedTranscriptPath,
           let text = Self.readFile(path) {
            pipelineTranscript = text
            loadedTranscriptPath = path
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

    private func applyPhase(from job: PipelineJob) {
        switch job.state {
        case .waiting, .transcribing, .diarizing, .speakerNamingPending:
            if phase == .recording { return }
            phase = .processing

        case .generatingProtocol:
            phase = .generatingNotes

        case .done:
            phase = notesMarkdown == nil && job.protocolPath == nil ? .processing : .ready

        case .error:
            phase = .failed
        }
    }

    private func matchingJob(in queue: PipelineQueue) -> PipelineJob? {
        let all = queue.jobs
        if let jobID, let match = all.first(where: { $0.id == jobID }) {
            return match
        }
        if !title.isEmpty {
            let titled = all.filter { $0.meetingTitle == title }
            if let newest = titled.max(by: { $0.enqueuedAt < $1.enqueuedAt }) {
                return newest
            }
        }
        if let active = queue.activeJobs.first { return active }
        return all.last
    }

    private func resetContents() {
        lines.removeAll()
        hypothesisMic = ""
        hypothesisApp = ""
        pipelineTranscript = nil
        notesMarkdown = nil
        jobID = nil
        errorMessage = nil
        loadedTranscriptPath = nil
        loadedNotesPath = nil
        thoughts = ""
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
