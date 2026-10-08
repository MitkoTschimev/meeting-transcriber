import Foundation

/// Splits a long transcript so protocol generation can retry in pieces when
/// a single prompt exceeds the model's context (a 70-minute meeting is tens
/// of thousands of tokens; many local OpenAI-compatible servers are 8–32k).
///
/// Limits are character counts, not tokens — a conservative stand-in so this
/// stays a pure function with no tokenizer dependency. 4 characters ≈ 1 token
/// for English, so 12_000 characters is roughly a 3k-token chunk plus the
/// system prompt, which fits an 8k window with room for output.
enum ProtocolTranscriptChunker {
    /// Above this, a failed generate is retried as chunks. Below it, the
    /// original error is surfaced — chunking a short transcript cannot help.
    static let directCharacterLimit = 24000

    /// Target size of each chunk. A single oversized line is hard-split.
    static let chunkCharacterLimit = 12000

    static func needsChunking(_ transcript: String) -> Bool {
        transcript.count > directCharacterLimit
    }

    static func chunks(
        _ transcript: String,
        maxCharacters: Int = chunkCharacterLimit,
    ) -> [String] {
        precondition(maxCharacters > 0, "chunk size must be positive")
        if transcript.count <= maxCharacters { return [transcript] }

        var result: [String] = []
        var current = ""
        let lines = transcript.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for line in lines {
            let piece = String(line)
            if piece.count > maxCharacters {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
                result.append(contentsOf: hardSplit(piece, maxCharacters: maxCharacters))
                continue
            }
            let candidate = current.isEmpty ? piece : current + "\n" + piece
            if candidate.count > maxCharacters {
                result.append(current)
                current = piece
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func hardSplit(_ text: String, maxCharacters: Int) -> [String] {
        var parts: [String] = []
        var remainder = text
        while remainder.count > maxCharacters {
            let index = remainder.index(remainder.startIndex, offsetBy: maxCharacters)
            parts.append(String(remainder[..<index]))
            remainder = String(remainder[index...])
        }
        if !remainder.isEmpty { parts.append(remainder) }
        return parts
    }
}
