import Foundation

/// How generated meeting notes are shaped. Settings and the notes window share
/// this picker; the selected case is the prompt `ProtocolGenerator.loadPrompt`
/// falls back to when the user has not installed a custom prompt file.
///
/// Raw values are snake_case so the UserDefaults / RPC wire form stays stable
/// if a case is renamed in Swift.
enum ProtocolStyle: String, CaseIterable, Codable {
    case actionItems = "action_items"
    case meetingProtocol = "meeting_protocol"
    case brief

    /// Preferred default: action-item notes, not a full meeting protocol.
    static let preferred: Self = .actionItems

    var label: String {
        switch self {
        case .actionItems: "Action items"
        case .meetingProtocol: "Meeting protocol"
        case .brief: "Short write-up"
        }
    }

    /// Shown while the LLM is still writing, in the notes window banner.
    var progressCaption: String {
        switch self {
        case .actionItems: "action items"
        case .meetingProtocol: "a meeting protocol"
        case .brief: "a two-minute read"
        }
    }

    /// Built-in prompt for this style. Custom files still win in `loadPrompt`.
    var prompt: String {
        switch self {
        case .actionItems: Self.actionItemsPrompt
        case .meetingProtocol: ProtocolGenerator.protocolPrompt
        case .brief: Self.briefPrompt
        }
    }

    private static let actionItemsPrompt = """
    You are a meeting notes assistant focused on action items.
    Create concise, actionable notes in {LANGUAGE} from the following transcript.

    Return ONLY the finished Markdown document - no explanations, no introduction,
    no comments before or after.

    Use exactly this structure:

    # [Meeting Title]
    **Date:** {MEETING_DATE}
    **Time:** {MEETING_TIME}

    ---

    ## Action items
    | Action | Owner | Due | Priority |
    |--------|-------|-----|----------|
    | [Description] | [Name or Unassigned] | [Date or open] | 🔴 high / 🟡 medium / 🟢 low |

    If no action items were agreed, write "_No action items captured._" under the heading \
    instead of an empty table.

    ## Decisions
    - [Decision, or "_None._"]

    ## Follow-ups
    - [Open question or parking-lot item, or "_None._"]

    ## Snapshot
    [3-5 sentences: what the meeting was about and the outcome]

    Do NOT include the full transcript in the output.

    ---
    Transcript:
    """

    private static let briefPrompt = """
    You are a meeting notes assistant.
    Turn the following transcript into a short, readable write-up in {LANGUAGE} — \
    about a two-minute read.

    Return ONLY the finished Markdown document - no explanations, no introduction,
    no comments before or after.

    Use exactly this structure:

    # [Meeting Title]
    **Date:** {MEETING_DATE}
    **Time:** {MEETING_TIME}

    ---

    [2-4 short paragraphs covering purpose, what was discussed, and the outcome. \
    Plain prose, not a bullet dump of the transcript.]

    ## Action items
    - [Owner]: [Action] (due [date or open])

    If none, write "_No action items._"

    Do NOT include the full transcript in the output.

    ---
    Transcript:
    """
}
