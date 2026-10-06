import Foundation

/// Lightweight in-meeting preview of likely action items, extracted from live
/// caption lines without an LLM call. Replaced by generated notes once the
/// protocol pipeline finishes. Conservative on purpose: a miss is preferable
/// to filling the Summary tab with every utterance.
enum ActionItemDraft {
    /// English + German commitment phrasing. Anchored on word boundaries so
    /// "I'll" / "ich werde" fire and "skill" / "sicher" do not.
    static let patterns = [
        #"\b(i['’]ll|i will|let'?s|we should|we need to|we will|action item|follow[- ]up|can you|could you|please|todo|to do|assign)\b"#,
        #"\b(ich werde|lass uns|wir sollten|wir müssen|wir werden|aufgabe|kannst du|könnt ihr|bitte)\b"#,
    ]

    static func items(from lines: [LiveCaptionLine]) -> [String] {
        lines.compactMap { line in
            guard matches(line.text) else { return nil }
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "\(line.speaker): \(text)"
        }
    }

    static func matches(_ text: String) -> Bool {
        patterns.contains { pattern in
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}
