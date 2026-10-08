import Foundation

extension SpeakerMatcher {
    /// Undo one `updateDB` confirmation: drop this meeting's sample from the
    /// recent-samples FIFO and reverse the running-mean centroid when the
    /// sample had been folded in. Never deletes the profile.
    @discardableResult
    func withdrawConfirmation(name: String, embedding: [Float], duration: TimeInterval) -> Bool {
        mutateDB { stored in
            guard let idx = stored.firstIndex(where: { $0.name == name }) else { return false }
            stored[idx] = Self.withdrawConfirmation(
                from: stored[idx],
                embedding: embedding,
                duration: duration,
            )
            return true
        }
    }

    /// Pure helper: reverse `applyConfirmation` for one sample.
    static func withdrawConfirmation(
        from speaker: StoredSpeaker, embedding: [Float], duration: TimeInterval,
    ) -> StoredSpeaker {
        var samples = speaker.embeddings
        if let idx = samples.lastIndex(of: embedding) {
            samples.remove(at: idx)
        }

        var nextCentroid = speaker.centroid
        var nextCount = speaker.centroidSampleCount
        if duration >= minSpeakingTimeForCentroid,
           let current = speaker.centroid,
           let withdrawn = removeFromCentroid(
               current: current,
               count: speaker.centroidSampleCount,
               sample: embedding,
           ) {
            nextCentroid = withdrawn.centroid.isEmpty ? nil : withdrawn.centroid
            nextCount = withdrawn.count
        }

        return StoredSpeaker(
            name: speaker.name,
            embeddings: samples,
            centroid: nextCentroid,
            centroidSampleCount: nextCount,
            lastUsed: speaker.lastUsed,
            useCount: max(0, speaker.useCount - 1),
            isSynthetic: speaker.isSynthetic,
        )
    }

    /// Inverse of `updateCentroid`. `count == 1` returns an empty centroid.
    static func removeFromCentroid(
        current: [Float], count: Int, sample: [Float],
    ) -> (centroid: [Float], count: Int)? {
        guard count > 0, current.count == sample.count else { return nil }
        if count == 1 { return ([], 0) }
        let n = Float(count)
        var previous = [Float](repeating: 0, count: current.count)
        for i in 0 ..< current.count {
            previous[i] = (current[i] * n - sample[i]) / (n - 1)
        }
        return (previous, count - 1)
    }
}
