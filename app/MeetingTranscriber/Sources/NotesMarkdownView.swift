import MarkdownUI
import SwiftUI

/// Meeting-notes GFM renderer. Remote images are disabled: protocol markdown is
/// local LLM output and must not fetch arbitrary URLs while the user reads it.
///
/// Uses MarkdownUI's `basic` theme plus a few text-style overrides so headings,
/// links, and code follow the notes window. Links go through
/// `NotesMarkdownLinkPolicy` (http(s) + mailto only).
///
/// When `mentions` is non-empty, paragraph / heading / table-cell text is
/// re-rendered with `SpeakerMentionText` so `@assignee` pills and speaker
/// colors match the Transcript tab. List bullets stay MarkdownUI's; their
/// inner paragraphs take the mention pass.
struct NotesMarkdownView: View {
    let content: MarkdownContent
    var mentions: [SpeakerMentionText.Mention] = []

    init(markdown: String, mentions: [SpeakerMentionText.Mention] = []) {
        self.init(content: MarkdownContent(markdown), mentions: mentions)
    }

    init(content: MarkdownContent, mentions: [SpeakerMentionText.Mention] = []) {
        self.content = content
        self.mentions = mentions
    }

    var body: some View {
        styled
            .environment(\.openURL, OpenURLAction(handler: NotesMarkdownLinkPolicy.open))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(A11yID.meetingNotesMarkdownPreview)
    }

    private var styled: some View {
        Markdown(content)
            .markdownTheme(.basic)
            .modifier(NotesMarkdownTextStyles())
            .modifier(NotesMentionBlocks(mentions: mentions))
            .markdownImageProvider(NotesDisabledImageProvider())
            .markdownInlineImageProvider(NotesDisabledInlineImageProvider())
            .textSelection(.enabled)
    }
}

private struct NotesMarkdownTextStyles: ViewModifier {
    func body(content: Content) -> some View {
        content
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
    }
}

/// Mention restyle is split into its own modifier so the `Markdown` chain
/// stays under the 300 ms type-check budget.
private struct NotesMentionBlocks: ViewModifier {
    let mentions: [SpeakerMentionText.Mention]

    func body(content: Content) -> some View {
        content
            .modifier(NotesMentionParagraph(mentions: mentions))
            .modifier(NotesMentionHeadings(mentions: mentions))
            .modifier(NotesMentionTableCells(mentions: mentions))
    }
}

private struct NotesMentionParagraph: ViewModifier {
    let mentions: [SpeakerMentionText.Mention]

    func body(content: Content) -> some View {
        content.markdownBlockStyle(\.paragraph) { configuration in
            NotesMentionLabel(configuration: configuration, mentions: mentions)
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: .zero, bottom: .em(1))
        }
    }
}

private struct NotesMentionHeadings: ViewModifier {
    let mentions: [SpeakerMentionText.Mention]

    func body(content: Content) -> some View {
        content
            .markdownBlockStyle(\.heading1) { configuration in
                NotesMentionHeading(configuration: configuration, mentions: mentions, style: .title)
            }
            .markdownBlockStyle(\.heading2) { configuration in
                NotesMentionHeading(configuration: configuration, mentions: mentions, style: .title2)
            }
            .markdownBlockStyle(\.heading3) { configuration in
                NotesMentionHeading(configuration: configuration, mentions: mentions, style: .title3)
            }
            .markdownBlockStyle(\.heading4) { configuration in
                NotesMentionHeading(configuration: configuration, mentions: mentions, style: .headline)
            }
    }
}

private struct NotesMentionTableCells: ViewModifier {
    let mentions: [SpeakerMentionText.Mention]

    func body(content: Content) -> some View {
        content.markdownBlockStyle(\.tableCell) { configuration in
            NotesMentionTableCell(configuration: configuration, mentions: mentions)
        }
    }
}

private struct NotesMentionLabel: View {
    let configuration: BlockConfiguration
    let mentions: [SpeakerMentionText.Mention]

    var body: some View {
        if mentions.isEmpty {
            configuration.label
        } else {
            SpeakerMentionText(
                markdown: NotesMarkdownMentionSource.inlineMarkdown(from: configuration.content),
                mentions: mentions,
            )
        }
    }
}

private struct NotesMentionHeading: View {
    let configuration: BlockConfiguration
    let mentions: [SpeakerMentionText.Mention]
    let style: Font.TextStyle

    var body: some View {
        NotesMentionLabel(configuration: configuration, mentions: mentions)
            .font(.system(style, design: .default, weight: .semibold))
            .markdownMargin(top: .rem(1.5), bottom: .rem(1))
    }
}

private struct NotesMentionTableCell: View {
    let configuration: TableCellConfiguration
    let mentions: [SpeakerMentionText.Mention]

    var body: some View {
        if mentions.isEmpty {
            configuration.label
        } else {
            SpeakerMentionText(
                markdown: NotesMarkdownMentionSource.inlineMarkdown(from: configuration.content),
                mentions: mentions,
            )
        }
    }
}

/// Strips an ATX heading prefix so a heading block's `renderMarkdown()` can be
/// fed to `SpeakerMentionText` without showing raw `##`.
enum NotesMarkdownMentionSource {
    static func inlineMarkdown(from content: MarkdownContent) -> String {
        let rendered = content.renderMarkdown()
        guard let regex = try? NSRegularExpression(pattern: #"^#{1,6}[ \t]+"#),
              let match = regex.firstMatch(
                  in: rendered,
                  range: NSRange(rendered.startIndex..., in: rendered),
              ),
              let range = Range(match.range, in: rendered)
        else { return rendered }
        return String(rendered[range.upperBound...])
    }
}

struct NotesDisabledImageProvider: ImageProvider {
    func makeImage(url _: URL?) -> some View {
        EmptyView()
    }
}

struct NotesDisabledInlineImageProvider: InlineImageProvider {
    // Protocol requires `async`; this provider never loads a file.
    // swiftlint:disable:next async_without_await
    func image(with _: URL, label _: String) async throws -> Image {
        throw NotesMarkdownImageDisabled()
    }
}

struct NotesMarkdownImageDisabled: Error {}
