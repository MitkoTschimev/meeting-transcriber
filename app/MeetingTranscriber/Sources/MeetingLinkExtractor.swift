import Foundation

/// Pulls a joinable meeting URL out of calendar fields (location, notes,
/// conference data, a stored URL). Pure so Apple and Google share one set of
/// Zoom / Meet / Teams / Webex patterns without a live network.
enum MeetingLinkExtractor {
    /// Ordered from more specific hosts to generic https, so a Zoom URL in
    /// the notes wins over a leftover `https://company.com` in the location.
    private static let patterns: [NSRegularExpression] = {
        let sources = [
            #"https?://[^\s<>\"]*zoom\.us/[^\s<>\"]+"#,
            #"https?://[^\s<>\"]*meet\.google\.com/[^\s<>\"]+"#,
            #"https?://[^\s<>\"]*teams\.microsoft\.com/[^\s<>\"]+"#,
            #"https?://[^\s<>\"]*teams\.live\.com/[^\s<>\"]+"#,
            #"https?://[^\s<>\"]*webex\.com/[^\s<>\"]+"#,
            #"https?://[^\s<>\"]+"#,
        ]
        return sources.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    static func url(from texts: [String?], explicit: URL? = nil) -> URL? {
        if let explicit, isJoinable(explicit) { return explicit }
        let combined = texts.compactMap(\.self).joined(separator: "\n")
        return firstURL(in: combined)
    }

    static func firstURL(in text: String) -> URL? {
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            guard let match = pattern.firstMatch(in: text, range: range),
                  let swiftRange = Range(match.range, in: text) else {
                continue
            }
            let raw = String(text[swiftRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,);]"))
            if let url = URL(string: raw), isJoinable(url) {
                return url
            }
        }
        return nil
    }

    static func isJoinable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https": return true
        default: return false
        }
    }
}
