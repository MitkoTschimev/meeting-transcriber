import SwiftUI

/// Stable per-speaker accent colors and display names for the meeting-notes
/// window. Identity is derived from the same labels the pipeline already
/// writes (`Me` / `micName`, `Remote`, `SPEAKER_N`, `R_`/`M_`-prefixed
/// `SpeakerKey` encodings) so Transcript and Summary stay in sync without a
/// second naming system.
enum SpeakerAccent {
    static let youKey = "__you__"

    /// Orange, reserved for the local microphone talker.
    static let youColor = Color(red: 0.86, green: 0.45, blue: 0.16)

    private static let others: [Color] = [
        Color(red: 0.45, green: 0.28, blue: 0.72),
        Color(red: 0.12, green: 0.52, blue: 0.52),
        Color(red: 0.75, green: 0.22, blue: 0.38),
        Color(red: 0.18, green: 0.42, blue: 0.78),
        Color(red: 0.38, green: 0.58, blue: 0.18),
        Color(red: 0.62, green: 0.32, blue: 0.55),
    ]

    static func isYou(_ raw: String, micLabel: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.compare("Me", options: .caseInsensitive) == .orderedSame { return true }
        if !micLabel.isEmpty, trimmed.compare(micLabel, options: .caseInsensitive) == .orderedSame {
            return true
        }
        return SpeakerKey(encoded: trimmed).track == .mic
    }

    static func identityKey(_ raw: String, micLabel: String) -> String {
        identityKey(raw, micLabel: micLabel, isYou: isYou(raw, micLabel: micLabel))
    }

    static func identityKey(_ raw: String, micLabel _: String, isYou: Bool) -> String {
        if isYou { return youKey }
        let key = SpeakerKey(encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if let number = speakerNumber(key.id) {
            return "\(key.track.rawValue):speaker:\(number)"
        }
        return key.id.lowercased()
    }

    static func displayName(_ raw: String, micLabel: String, isYou: Bool) -> String {
        if isYou {
            return "\(youBase(raw, micLabel: micLabel)) (You)"
        }
        return pretty(raw)
    }

    static func color(isYou: Bool, othersIndex: Int) -> Color {
        if isYou { return youColor }
        let idx = ((othersIndex % others.count) + others.count) % others.count
        return others[idx]
    }

    /// First-seen order of non-you speakers; `youKey` is tracked but skipped
    /// when assigning the others palette so the local user always stays orange.
    struct Palette: Equatable {
        private(set) var order: [String] = []

        mutating func register(_ key: String) {
            if !order.contains(key) { order.append(key) }
        }

        func othersIndex(for key: String) -> Int {
            order.filter { $0 != SpeakerAccent.youKey }.firstIndex(of: key) ?? 0
        }

        var speakerCount: Int {
            order.count
        }

        func color(forKey key: String, isYou: Bool) -> Color {
            SpeakerAccent.color(isYou: isYou, othersIndex: othersIndex(for: key))
        }
    }

    static func pretty(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Speaker" }
        let key = SpeakerKey(encoded: trimmed)
        if let number = speakerNumber(key.id) {
            return "Speaker \(number + 1)"
        }
        return key.id
    }

    private static func youBase(_ raw: String, micLabel: String) -> String {
        let fallback = micLabel.isEmpty ? "Me" : micLabel
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || isGeneric(trimmed) { return fallback }
        let shown = pretty(trimmed)
        if isGeneric(shown) { return fallback }
        return shown
    }

    private static func isGeneric(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.compare("Me", options: .caseInsensitive) == .orderedSame { return true }
        if trimmed.compare("Remote", options: .caseInsensitive) == .orderedSame { return true }
        return speakerNumber(SpeakerKey(encoded: trimmed).id) != nil
    }

    /// FluidAudio / `SpeakerKey` ids (`SPEAKER_0`, `SPEAKER_00`) → 0.
    /// Does not match the display form "Speaker 1".
    static func speakerNumber(_ id: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"^SPEAKER_0*(\d+)$"#, options: .caseInsensitive),
              let match = regex.firstMatch(
                  in: id,
                  range: NSRange(id.startIndex..., in: id),
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: id) else { return nil }
        return Int(id[range])
    }
}
