import Foundation

/// Private My-thoughts scratchpad on disk. Sibling of the job's transcript /
/// protocol (`{stem}.thoughts.md`) once those exist; otherwise an in-progress
/// file under `directory`. Never fed into protocol prompts.
struct MeetingThoughtsStore: Sendable {
    let directory: URL

    func inProgressURL(startedAt: Date) -> URL {
        let stamp = Int(startedAt.timeIntervalSince1970)
        return directory.appendingPathComponent("in-progress-\(stamp).thoughts.md")
    }

    /// Same stem as the transcript or protocol, with a `.thoughts.md` suffix
    /// so `{basename}.txt` / `{basename}.md` stay the pipeline artefacts.
    static func siblingURL(of job: PipelineJob) -> URL? {
        if let transcript = job.transcriptPath {
            return thoughtsSibling(of: transcript)
        }
        if let protocolPath = job.protocolPath {
            return thoughtsSibling(of: protocolPath)
        }
        if let slug = job.namingSlug, let dir = job.sidecarOutputDir {
            return dir.appendingPathComponent("\(slug).thoughts.md")
        }
        return nil
    }

    func load(from url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func save(_ text: String, to url: URL) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fm = FileManager.default
        if trimmed.isEmpty {
            try? fm.removeItem(at: url)
            return
        }
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try? text.write(to: url, atomically: true, encoding: .utf8)
        try? fm.restrictToOwner(url)
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func thoughtsSibling(of artefact: URL) -> URL {
        artefact.deletingPathExtension().appendingPathExtension("thoughts.md")
    }
}
