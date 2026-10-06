import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "MeetingThoughts")

/// Private My-thoughts scratchpad. Always under `directory` (`AppPaths.thoughtsDir`
/// in production) — never beside shareable transcript/protocol files.
/// In-progress files use a UUID; job-bound files are keyed by naming slug
/// (or job id). Never fed into protocol prompts.
struct MeetingThoughtsStore: Sendable {
    let directory: URL

    func inProgressURL() -> URL {
        directory.appendingPathComponent("in-progress-\(UUID().uuidString).thoughts.md")
    }

    func url(for job: PipelineJob) -> URL {
        let key = job.namingSlug ?? job.id.uuidString
        return directory.appendingPathComponent("\(key).thoughts.md")
    }

    /// Drop leftover in-progress files from previous sessions. Call on launch
    /// and when a session starts, keeping only the current in-progress URL.
    func pruneInProgress(keeping current: URL? = nil) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
        ) else { return }
        let keep = current?.lastPathComponent
        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix("in-progress-"), name.hasSuffix(".thoughts.md") else { continue }
            if name == keep { continue }
            do {
                try fm.removeItem(at: file)
            } catch {
                logger.error("Thoughts prune failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func load(from url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            logger.error("Thoughts load failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func save(_ text: String, to url: URL) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fm = FileManager.default
        do {
            if trimmed.isEmpty {
                if fm.fileExists(atPath: url.path) {
                    try fm.removeItem(at: url)
                }
                return
            }
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
            try fm.restrictToOwner(url)
        } catch {
            logger.error("Thoughts save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func remove(_ url: URL) {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            logger.error("Thoughts remove failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
