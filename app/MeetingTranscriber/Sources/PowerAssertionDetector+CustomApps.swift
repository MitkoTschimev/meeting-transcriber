import AudioTapLib
import Foundation

/// How a process-open (browser WebRTC) hit is carried: custom watch apps
/// auto-record, and Electron helpers collapse to the host app so confirmation
/// and the tap target survive helper-process hops.
extension PowerAssertionDetector {
    struct ResolvedOpenIdentity {
        let key: String
        let tapPID: pid_t
        let ownerName: String
        let requiresRecordingConsent: Bool
    }

    func recordHits(
        from assertions: [Int32: [[String: Any]]],
        ignoring ignored: Set<String> = [],
        into hitsThisRound: inout Set<String>,
        firstMatch: inout [String: (resolved: ResolvedOpenIdentity, pattern: AssertionPattern)],
    ) {
        for (pid, pidAssertions) in assertions {
            for assertion in pidAssertions {
                guard let processName = assertion["Process Name"] as? String,
                      let assertName = assertion["AssertName"] as? String else {
                    continue
                }
                let assertType = assertion["AssertType"] as? String ?? ""
                for pattern in patterns {
                    recordHitIfMatched(
                        pid: pid,
                        processName: processName,
                        assertName: assertName,
                        assertType: assertType,
                        pattern: pattern,
                        ignored: ignored,
                        hitsThisRound: &hitsThisRound,
                        firstMatch: &firstMatch,
                    )
                }
            }
        }
    }

    private func recordHitIfMatched(
        pid: pid_t,
        processName: String,
        assertName: String,
        assertType: String,
        pattern: AssertionPattern,
        ignored: Set<String>,
        hitsThisRound: inout Set<String>,
        firstMatch: inout [String: (resolved: ResolvedOpenIdentity, pattern: AssertionPattern)],
    ) {
        guard matchAssertion(
            processName: processName,
            assertName: assertName,
            assertType: assertType,
            pattern: pattern,
        ) else { return }

        // Resolve after the match: a helper's process name is a poor identity
        // for Electron (Gather Helper vs Renderer hop would reset the
        // confirmation counter), and a custom watch app must not inherit the
        // browser consent prompt.
        let resolved = resolveOpenIdentity(
            pid: pid, processName: processName, pattern: pattern,
        )
        // Deny list only gates consent-required identities. Adding a custom
        // app is an explicit opt-in and wins.
        if resolved.requiresRecordingConsent, isIdentityDenied(resolved.key) { return }
        // A parked meeting (ended early while still signalling) must not
        // accumulate hits: a permanently confirmed key would be returned every
        // poll and could shadow another app's confirmation.
        if ignored.contains(resolved.key) { return }
        if let until = cooldownUntil[resolved.key], Date() < until { return }
        guard !hitsThisRound.contains(resolved.key) else { return }

        hitsThisRound.insert(resolved.key)
        firstMatch[resolved.key] = (resolved, pattern)
        consecutiveHits[resolved.key, default: 0] += 1
    }

    func confirmedMeeting(
        from firstMatch: [String: (resolved: ResolvedOpenIdentity, pattern: AssertionPattern)],
    ) -> DetectedMeeting? {
        for (key, hits) in consecutiveHits {
            guard hits >= confirmationCount, let match = firstMatch[key] else { continue }
            let meetingPattern = Self.meetingIdentity(
                pattern: match.pattern,
                processName: match.resolved.ownerName,
                requiresRecordingConsent: match.resolved.requiresRecordingConsent,
            )
            let title = lookupWindowTitle(for: meetingPattern, pattern: match.pattern)
                ?? Self.placeholderTitle(appName: meetingPattern.appName)
            return DetectedMeeting(
                pattern: meetingPattern,
                windowTitle: title,
                ownerName: match.resolved.ownerName,
                windowPID: match.resolved.tapPID,
            )
        }
        return nil
    }

    func resolveOpenIdentity(
        pid: pid_t,
        processName: String,
        pattern: AssertionPattern,
    ) -> ResolvedOpenIdentity {
        switch pattern.identity {
        case .shared:
            return ResolvedOpenIdentity(
                key: pattern.identityKey(processName: processName),
                tapPID: pid,
                ownerName: processName,
                requiresRecordingConsent: AppMeetingPattern.forAppName(pattern.appName)?
                    .requiresRecordingConsent ?? false,
            )
        case .perProcess:
            return resolvePerProcessIdentity(pid: pid, processName: processName, pattern: pattern)
        }
    }

    private func resolvePerProcessIdentity(
        pid: pid_t,
        processName: String,
        pattern: AssertionPattern,
    ) -> ResolvedOpenIdentity {
        let bundle = processBundleProvider(pid)
        if let custom = customAppsProvider().first(where: { $0.matches(process: bundle) }) {
            return ResolvedOpenIdentity(
                key: custom.displayName,
                tapPID: mainAppPIDProvider(custom.bundleID) ?? pid,
                ownerName: custom.displayName,
                requiresRecordingConsent: false,
            )
        }

        if let url = bundle?.bundleURL {
            let outer = ProcessTreeEnumerator.outermostAppBundle(containing: url)
            if outer.resolvingSymlinksInPath().path != url.resolvingSymlinksInPath().path {
                let name = outer.deletingPathExtension().lastPathComponent
                let outerID = WatchedCustomApp.bundleIdentifier(at: outer)
                return ResolvedOpenIdentity(
                    key: name,
                    tapPID: outerID.flatMap(mainAppPIDProvider) ?? pid,
                    ownerName: name,
                    requiresRecordingConsent: true,
                )
            }
        }

        return ResolvedOpenIdentity(
            key: processName,
            tapPID: pid,
            ownerName: processName,
            requiresRecordingConsent: AppMeetingPattern.forAppName(pattern.appName)?
                .requiresRecordingConsent ?? true,
        )
    }
}
