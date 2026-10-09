import AppKit
import Foundation
import SwiftUI

/// Which destinations a generated-notes link may open.
///
/// Protocol markdown is LLM output (and GFM autolinks bare URLs). Opening
/// `file:`, `smb:`, `ssh:`, `vnc:`, `zoommtg:`, or `x-apple.systempreferences:`
/// would let one click launch a local app or file. Only http(s) with a host
/// and `mailto:` with an address are allowed.
enum NotesMarkdownLinkPolicy {
    enum Decision: Equatable {
        case allow
        case refuse
    }

    static func decision(for url: URL) -> Decision {
        switch scheme(of: url) {
        case "https", "http":
            hostIsPresent(url) ? .allow : .refuse

        case "mailto":
            mailtoAddressIsPresent(url) ? .allow : .refuse

        default:
            .refuse
        }
    }

    static func open(_ url: URL) -> OpenURLAction.Result {
        switch decision(for: url) {
        case .allow:
            NSWorkspace.shared.open(url)
            return .handled

        case .refuse:
            return .discarded
        }
    }

    private static func scheme(of url: URL) -> String {
        url.scheme?.lowercased() ?? ""
    }

    private static func hostIsPresent(_ url: URL) -> Bool {
        let host = url.host ?? ""
        return !host.isEmpty
    }

    /// `mailto:user@host` stores the mailbox in the path / resource, not `host`.
    private static func mailtoAddressIsPresent(_ url: URL) -> Bool {
        let spec = url.absoluteString
        guard spec.lowercased().hasPrefix("mailto:") else { return false }
        let rest = spec.dropFirst("mailto:".count)
        let mailbox = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return mailbox.contains("@")
    }
}
