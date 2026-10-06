import SwiftUI

/// Summary/notes text with speaker names tinted to match the Transcript tab.
/// `@Name` and `(Name)` assignees get a pill background; other mentions of a
/// known speaker keep the accent color without a fill.
struct SpeakerMentionText: View {
    struct Mention: Equatable {
        let names: [String]
        let color: Color
    }

    let markdown: String
    let mentions: [Mention]

    var body: some View {
        Text(colored)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var colored: AttributedString {
        var attributed: AttributedString = if let parsed = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace),
        ) {
            parsed
        } else {
            AttributedString(markdown)
        }
        Self.applyMentions(&attributed, mentions: mentions)
        return attributed
    }

    static func applyMentions(_ attributed: inout AttributedString, mentions: [Mention]) {
        let plain = String(attributed.characters)
        guard !plain.isEmpty else { return }
        var claimed = IndexSet()
        for mention in mentions {
            for name in mention.names.sorted(by: { $0.count > $1.count }) {
                applyPills(name, color: mention.color, in: plain, onto: &attributed, claimed: &claimed)
            }
        }
        for mention in mentions {
            for name in mention.names.sorted(by: { $0.count > $1.count }) {
                applyInline(name, color: mention.color, in: plain, onto: &attributed, claimed: &claimed)
            }
        }
    }

    /// `@Name` and `(Name)` — pill.
    private static func applyPills(
        _ name: String,
        color: Color,
        in plain: String,
        onto attributed: inout AttributedString,
        claimed: inout IndexSet,
    ) {
        guard !name.isEmpty else { return }
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let patterns = ["@" + escaped, "\\(" + escaped + "\\)"]
        let fullRange = NSRange(plain.startIndex..., in: plain)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            for match in regex.matches(in: plain, range: fullRange) {
                let range = match.range
                guard range.location != NSNotFound, !overlaps(range, claimed: claimed) else { continue }
                guard let swiftRange = Range(range, in: plain),
                      let attrRange = Range(swiftRange, in: attributed) else { continue }
                attributed[attrRange].foregroundColor = color
                attributed[attrRange].backgroundColor = color.opacity(0.16)
                claimed.insert(integersIn: range.location ..< (range.location + range.length))
            }
        }
    }

    /// Bare name — accent only.
    private static func applyInline(
        _ name: String,
        color: Color,
        in plain: String,
        onto attributed: inout AttributedString,
        claimed: inout IndexSet,
    ) {
        guard !name.isEmpty, name.count >= 3 else { return }
        if name.compare("Me", options: .caseInsensitive) == .orderedSame { return }
        if name.compare("Remote", options: .caseInsensitive) == .orderedSame { return }
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let regex = try? NSRegularExpression(pattern: escaped, options: .caseInsensitive) else { return }
        let fullRange = NSRange(plain.startIndex..., in: plain)
        for match in regex.matches(in: plain, range: fullRange) {
            let range = match.range
            guard range.location != NSNotFound, !overlaps(range, claimed: claimed) else { continue }
            guard let swiftRange = Range(range, in: plain),
                  let attrRange = Range(swiftRange, in: attributed) else { continue }
            attributed[attrRange].foregroundColor = color
            claimed.insert(integersIn: range.location ..< (range.location + range.length))
        }
    }

    private static func overlaps(_ range: NSRange, claimed: IndexSet) -> Bool {
        guard range.location != NSNotFound, range.length > 0 else { return true }
        for idx in range.location ..< (range.location + range.length) where claimed.contains(idx) {
            return true
        }
        return false
    }
}

extension SpeakerMentionText {
    static func mentions(
        from turns: [TranscriptTurn],
        palette: SpeakerAccent.Palette,
        micLabel: String,
    ) -> [Mention] {
        var seen = Set<String>()
        var result: [Mention] = []
        for turn in turns where !turn.speakerRaw.isEmpty {
            let key = SpeakerAccent.identityKey(turn.speakerRaw, micLabel: micLabel, isYou: turn.isYou)
            guard seen.insert(key).inserted else { continue }
            let display = SpeakerAccent.displayName(turn.speakerRaw, micLabel: micLabel, isYou: turn.isYou)
            let base = display.replacingOccurrences(of: " (You)", with: "")
            var names = [base, SpeakerAccent.pretty(turn.speakerRaw), turn.speakerRaw]
            if turn.isYou {
                names.append(contentsOf: ["Me", micLabel])
            }
            let unique = names
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != SpeakerAccent.youKey }
            result.append(Mention(
                names: Array(Set(unique)),
                color: palette.color(forKey: key, isYou: turn.isYou),
            ))
        }
        return result
    }
}
