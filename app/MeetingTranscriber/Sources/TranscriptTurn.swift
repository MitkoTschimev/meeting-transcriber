import Foundation

/// One continuous speaker turn in the meeting-notes Transcript tab. Consecutive
/// lines from the same speaker collapse so the name is shown once above the
/// block, not on every line.
struct TranscriptTurn: Equatable, Identifiable {
    let id: Int
    let speakerRaw: String
    /// Session voice behind a live turn (`LiveSpeakerRoster`), nil for
    /// pipeline turns and hypotheses. What the naming menu renames.
    var speakerID: Int?
    let isYou: Bool
    let paragraphs: [String]
    let isHypothesis: Bool

    /// Build turns from live captions, or from the pipeline transcript once
    /// that file exists (diarized names then win).
    static func build(
        liveLines: [LiveCaptionLine],
        hypothesisMic: String,
        hypothesisApp: String,
        pipelineTranscript: String?,
        micLabel: String,
        notYouSpeakerIDs: Set<Int> = [],
    ) -> [Self] {
        if let pipelineTranscript {
            let trimmed = pipelineTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return parsePipeline(trimmed, micLabel: micLabel)
            }
        }
        return parseLive(
            lines: liveLines,
            hypothesisMic: hypothesisMic,
            hypothesisApp: hypothesisApp,
            micLabel: micLabel,
            notYouSpeakerIDs: notYouSpeakerIDs,
        )
    }

    static func chrome(speakerCount: Int, duration: TimeInterval) -> String {
        let speakers = speakerCount == 1 ? "1 SPEAKER" : "\(max(speakerCount, 0)) SPEAKERS"
        guard duration >= 1 else { return speakers }
        return "\(speakers) · \(formattedClockDuration(duration))"
    }

    /// Append-only: `existing` keeps first-seen identityKeys so a live→diarized
    /// handoff does not reshuffle accent colors when speaker order changes.
    static func palette(
        for turns: [Self],
        micLabel: String,
        existing: SpeakerAccent.Palette = SpeakerAccent.Palette(),
    ) -> SpeakerAccent.Palette {
        var palette = existing
        for turn in turns {
            let key = SpeakerAccent.identityKey(turn.speakerRaw, micLabel: micLabel, isYou: turn.isYou)
            palette.register(key)
        }
        return palette
    }

    private static func parseLive(
        lines: [LiveCaptionLine],
        hypothesisMic: String,
        hypothesisApp: String,
        micLabel: String,
        notYouSpeakerIDs: Set<Int>,
    ) -> [Self] {
        var turns: [Self] = []
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // A mic voice the user named as someone else (a colleague in the
            // room) is not "You", whatever channel it came in on.
            let namedAsOther = line.speakerID.map { notYouSpeakerIDs.contains($0) } ?? false
            let isYou = (line.channel == .mic && !namedAsOther) || SpeakerAccent.isYou(line.speaker, micLabel: micLabel)
            append(
                speakerRaw: line.speaker,
                isYou: isYou,
                text: text,
                isHypothesis: false,
                onto: &turns,
                speakerID: line.speakerID,
            )
        }
        let remote = hypothesisApp.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remote.isEmpty {
            append(
                speakerRaw: "Remote",
                isYou: false,
                text: remote,
                isHypothesis: true,
                onto: &turns,
            )
        }
        let local = hypothesisMic.trimmingCharacters(in: .whitespacesAndNewlines)
        if !local.isEmpty {
            append(
                speakerRaw: micLabel.isEmpty ? "Me" : micLabel,
                isYou: true,
                text: local,
                isHypothesis: true,
                onto: &turns,
            )
        }
        return turns
    }

    /// Pipeline files are `[MM:SS] Speaker: text` (see `TimestampedSegment.formattedLine`).
    static func parsePipeline(_ text: String, micLabel: String) -> [Self] {
        let regex = try? NSRegularExpression(
            pattern: #"^\[(?:\d+:)?\d{1,2}:\d{2}\]\s+(?:([^:\n]{1,80}):\s+)?(.*)$"#,
        )
        var turns: [Self] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let regex,
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
            else {
                let leftover = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if leftover.isEmpty { continue }
                append(speakerRaw: "", isYou: false, text: leftover, isHypothesis: false, onto: &turns)
                continue
            }
            let speaker = substring(in: line, match: match, at: 1)
            let body = substring(in: line, match: match, at: 2)
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedBody.isEmpty else { continue }
            let trimmedSpeaker = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            append(
                speakerRaw: trimmedSpeaker,
                isYou: SpeakerAccent.isYou(trimmedSpeaker, micLabel: micLabel),
                text: trimmedBody,
                isHypothesis: false,
                onto: &turns,
            )
        }
        return turns
    }

    private static func substring(in line: String, match: NSTextCheckingResult, at index: Int) -> String {
        guard index < match.numberOfRanges else { return "" }
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: line) else { return "" }
        return String(line[swiftRange])
    }

    private static func append(
        speakerRaw: String,
        isYou: Bool,
        text: String,
        isHypothesis: Bool,
        onto turns: inout [Self],
        speakerID: Int? = nil,
    ) {
        if let last = turns.last,
           !last.speakerRaw.isEmpty,
           !last.isHypothesis, !isHypothesis,
           last.speakerRaw == speakerRaw, last.isYou == isYou,
           last.speakerID == speakerID {
            let merged = Self(
                id: last.id,
                speakerRaw: last.speakerRaw,
                speakerID: last.speakerID,
                isYou: last.isYou,
                paragraphs: last.paragraphs + [text],
                isHypothesis: false,
            )
            turns[turns.count - 1] = merged
            return
        }
        turns.append(Self(
            id: turns.count,
            speakerRaw: speakerRaw,
            speakerID: speakerID,
            isYou: isYou,
            paragraphs: [text],
            isHypothesis: isHypothesis,
        ))
    }
}

func formattedClockDuration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.towardZero)))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
}
