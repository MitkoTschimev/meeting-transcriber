import AppKit
import MarkdownUI
import SwiftUI

/// Meeting-notes GFM renderer. Remote images are disabled: protocol markdown is
/// local LLM output and must not fetch arbitrary URLs while the user reads it.
///
/// Uses MarkdownUI's `basic` theme (semantic colors, no hardcoded canvas) plus
/// a few text-style overrides so headings, links, and code follow the notes
/// window. A custom `Theme` static is avoided: `Theme` is not `Sendable` and
/// Swift 6 rejects a shared instance under this package's concurrency settings.
struct NotesMarkdownView: View {
    let markdown: String

    var body: some View {
        Markdown(markdown)
            .markdownTheme(.basic)
            .markdownTextStyle(\.text) {
                ForegroundColor(.primary)
            }
            .markdownTextStyle(\.code) {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.94))
                BackgroundColor(.primary.opacity(0.08))
            }
            .markdownTextStyle(\.link) {
                ForegroundColor(.accentColor)
            }
            .markdownImageProvider(NotesDisabledImageProvider())
            .markdownInlineImageProvider(NotesDisabledInlineImageProvider())
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction(handler: Self.openInBrowser))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(A11yID.meetingNotesMarkdownPreview)
    }

    private static func openInBrowser(_ url: URL) -> OpenURLAction.Result {
        NSWorkspace.shared.open(url)
        return .handled
    }
}

private struct NotesDisabledImageProvider: ImageProvider {
    func makeImage(url _: URL?) -> some View {
        EmptyView()
    }
}

private struct NotesDisabledInlineImageProvider: InlineImageProvider {
    // Protocol requires `async`; this provider never loads a file.
    // swiftlint:disable:next async_without_await
    func image(with _: URL, label _: String) async throws -> Image {
        throw NotesMarkdownImageDisabled()
    }
}

private struct NotesMarkdownImageDisabled: Error {}
