import Foundation

/// RSVP for a calendar attendee. Apple EventKit and Google Calendar both map
/// into this so picker filtering does not depend on either SDK.
enum CalendarAttendeeStatus: String, Sendable {
    case accepted
    case declined
    case tentative
    case needsAction
    case unknown
}

/// One person (or resource) on a calendar event, from EventKit or Google.
///
/// `email` is kept in memory for merge/self detection only. Picker names and
/// anything written to disk (`participants`, sidecar, `_naming.json`) use
/// `pickerName`, which never contains `@`.
struct CalendarAttendee: Equatable, Identifiable, Sendable {
    let email: String?
    let displayName: String?
    let isSelf: Bool
    let isOrganizer: Bool
    let isResource: Bool
    let isGroup: Bool
    let status: CalendarAttendeeStatus

    var id: String {
        let mail = normalizedEmail ?? ""
        let name = displayName?.lowercased() ?? ""
        return "\(mail)|\(name)"
    }

    var isDeclined: Bool {
        status == .declined
    }

    var normalizedEmail: String? {
        let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Name shown in speaker-naming menus: a real display name, else a
    /// humanized email local-part (`john.smith@corp.com` → `John Smith`).
    var pickerName: String {
        if let named = Self.sanitizedDisplayName(displayName) { return named }
        return Self.humanizedLocalPart(of: email)
    }

    init(
        email: String? = nil,
        displayName: String? = nil,
        isSelf: Bool = false,
        isOrganizer: Bool = false,
        isResource: Bool = false,
        isGroup: Bool = false,
        status: CalendarAttendeeStatus = .unknown,
    ) {
        self.email = email
        self.displayName = displayName
        self.isSelf = isSelf
        self.isOrganizer = isOrganizer
        self.isResource = isResource
        self.isGroup = isGroup
        self.status = status
    }

    func isSamePerson(as other: Self) -> Bool {
        if let email = normalizedEmail, email == other.normalizedEmail { return true }
        if normalizedEmail != nil, other.normalizedEmail != nil { return false }
        let left = pickerName.lowercased()
        let right = other.pickerName.lowercased()
        return !left.isEmpty && left == right
    }

    func merging(_ other: Self) -> Self {
        let name: String? = if let mine = Self.sanitizedDisplayName(displayName) {
            mine
        } else {
            Self.sanitizedDisplayName(other.displayName)
        }
        return Self(
            email: email ?? other.email,
            displayName: name,
            // Google `self` is calendar-local. Do not absorb it from the
            // other copy — `markingSelf` restamps from known user emails.
            isSelf: isSelf,
            isOrganizer: isOrganizer || other.isOrganizer,
            isResource: isResource || other.isResource,
            isGroup: isGroup || other.isGroup,
            status: Self.combinedStatus(status, other.status),
        )
    }

    func markingSelf(ifEmailIn emails: Set<String>) -> Self {
        guard !emails.isEmpty else { return self }
        guard let mail = normalizedEmail else { return self }
        let matches = emails.contains(mail)
        if matches == isSelf { return self }
        return Self(
            email: email,
            displayName: displayName,
            isSelf: matches,
            isOrganizer: isOrganizer,
            isResource: isResource,
            isGroup: isGroup,
            status: status,
        )
    }

    static func looksLikeEmail(_ raw: String) -> Bool {
        raw.contains("@")
    }

    static let maxPickerNameLength = 40

    static func strippedQuotes(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’"))
    }

    static func sanitizedDisplayName(_ raw: String?) -> String? {
        var trimmed = strippedQuotes(raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        trimmed = strippedQuotes(trimmed)
        if trimmed.isEmpty || looksLikeEmail(trimmed) { return nil }
        if trimmed.count > maxPickerNameLength {
            trimmed = String(trimmed.prefix(maxPickerNameLength))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    static func persistableName(_ raw: String) -> String? {
        sanitizedDisplayName(raw)
    }

    static func localPart(of email: String) -> String {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let at = trimmed.firstIndex(of: "@") ?? trimmed.endIndex
        return String(trimmed[..<at])
    }

    /// `john.smith`, `john_smith`, `alice+tag@…` → `John Smith` / `Alice`.
    /// Skips automated, digits-only, and single-letter local-parts.
    static func humanizedLocalPart(of email: String?) -> String {
        let local = strippedQuotes(localPart(of: email ?? ""))
        let untagged = local.split(separator: "+").first.map(String.init) ?? local
        let compact = untagged.lowercased()
        if compact.isEmpty || Self.automatedLocalParts.contains(compact) { return "" }
        let letterCount = compact.filter(\.isLetter).count
        if letterCount < 2 { return "" }
        let words = untagged.split { $0 == "." || $0 == "_" || $0 == "-" }
            .map(String.init)
            .filter { !$0.isEmpty }
            .map { token -> String in
                let lower = token.lowercased()
                guard let first = lower.first else { return "" }
                return String(first).uppercased() + lower.dropFirst()
            }
        let joined = words.joined(separator: " ")
        if joined.count <= maxPickerNameLength { return joined }
        return String(joined.prefix(maxPickerNameLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let automatedLocalParts: Set<String> = [
        "noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "do.not.reply",
        "mailer-daemon", "mailer_daemon", "postmaster", "bounce",
        "notifications", "notification", "notify", "daemon",
        "calendar-notification", "calendar.notification", "calendar_notification",
        "automail", "auto-reply", "autoreply",
    ]

    static func email(fromMailto url: URL?) -> String? {
        guard let url else { return nil }
        if url.scheme?.caseInsensitiveCompare("mailto") == .orderedSame {
            let raw = url.absoluteString
            if let range = raw.range(of: "mailto:", options: .caseInsensitive) {
                let email = String(raw[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return email.isEmpty ? nil : email
            }
        }
        return nil
    }

    static func combinedStatus(
        _ lhs: CalendarAttendeeStatus,
        _ rhs: CalendarAttendeeStatus,
    ) -> CalendarAttendeeStatus {
        if lhs == .declined || rhs == .declined { return .declined }
        let rank: [CalendarAttendeeStatus: Int] = [
            .accepted: 0,
            .tentative: 1,
            .needsAction: 2,
            .unknown: 3,
        ]
        return (rank[lhs] ?? 3) <= (rank[rhs] ?? 3) ? lhs : rhs
    }
}

/// Builds the pickable name list from calendar attendees: skip resources,
/// groups, and the current user; put declined last; de-dupe case-insensitively.
enum CalendarAttendeePicker {
    static func names(
        from attendees: [CalendarAttendee],
        selfEmails: Set<String> = [],
        includeDeclined: Bool = true,
    ) -> [String] {
        let eligible = attendees
            .map { $0.markingSelf(ifEmailIn: selfEmails) }
            .filter { attendee in
                if attendee.isResource || attendee.isGroup || attendee.isSelf || attendee.pickerName.isEmpty {
                    return false
                }
                if !includeDeclined, attendee.isDeclined { return false }
                return true
            }
        let ordered = eligible.enumerated().sorted { lhs, rhs in
            if lhs.element.isDeclined != rhs.element.isDeclined {
                return !lhs.element.isDeclined
            }
            let nameOrder = lhs.element.pickerName.localizedCaseInsensitiveCompare(rhs.element.pickerName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.offset < rhs.offset
        }
        var seen: Set<String> = []
        var names: [String] = []
        for item in ordered {
            guard let name = CalendarAttendee.persistableName(item.element.pickerName) else { continue }
            guard seen.insert(name.lowercased()).inserted else { continue }
            names.append(name)
        }
        return names
    }

    /// Teams AX names first, then calendar picker names not already present.
    /// Names that look like emails are dropped so they never reach disk.
    static func merge(teams: [String], attendees: [CalendarAttendee]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for name in teams + names(from: attendees, includeDeclined: false) {
            guard let trimmed = CalendarAttendee.persistableName(name) else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    static func preferredSpelling(_ name: String, among known: [String]) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return known.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ?? trimmed
    }

    static func preferredSpellings(_ names: [String], among known: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for name in names {
            let displayed = preferredSpelling(name, among: known)
            guard let persistable = CalendarAttendee.persistableName(displayed) else { continue }
            guard seen.insert(persistable.lowercased()).inserted else { continue }
            result.append(persistable)
        }
        return result
    }
}

/// Maps EventKit / Google attendee fields into `CalendarAttendee` without
/// needing a live calendar store.
enum CalendarAttendeeMapping {
    // Mirrors EventKit / Google attendee fields one-for-one.
    // swiftlint:disable:next function_parameter_count
    static func apple(
        name: String?,
        url: URL?,
        isCurrentUser: Bool,
        isOrganizer: Bool,
        isResource: Bool,
        status: CalendarAttendeeStatus,
        isGroup: Bool = false,
    ) -> CalendarAttendee? {
        make(
            email: CalendarAttendee.email(fromMailto: url),
            displayName: name,
            isSelf: isCurrentUser,
            isOrganizer: isOrganizer,
            isResource: isResource,
            isGroup: isGroup,
            status: status,
        )
    }

    // swiftlint:disable:next function_parameter_count
    static func google(
        email: String?,
        displayName: String?,
        isSelf: Bool,
        isOrganizer: Bool,
        isResource: Bool,
        responseStatus: String?,
        isGroup: Bool = false,
    ) -> CalendarAttendee? {
        make(
            email: email,
            displayName: displayName,
            isSelf: isSelf,
            isOrganizer: isOrganizer,
            isResource: isResource,
            isGroup: isGroup,
            status: googleStatus(responseStatus),
        )
    }

    static func googleStatus(_ raw: String?) -> CalendarAttendeeStatus {
        switch raw?.lowercased() {
        case "accepted": .accepted
        case "declined": .declined
        case "tentative": .tentative
        case "needsaction": .needsAction
        default: .unknown
        }
    }

    static func looksLikeGroup(email: String?, displayName: String?) -> Bool {
        let name = displayName?.lowercased() ?? ""
        if name.contains("mailing list") || name.contains("undisclosed") { return true }
        let local = CalendarAttendee.localPart(of: email ?? "").lowercased()
        return local.hasPrefix("group.") || local.hasSuffix(".group") || local == "undisclosed-recipients"
    }

    // swiftlint:disable:next function_parameter_count
    private static func make(
        email: String?,
        displayName: String?,
        isSelf: Bool,
        isOrganizer: Bool,
        isResource: Bool,
        isGroup: Bool,
        status: CalendarAttendeeStatus,
    ) -> CalendarAttendee? {
        let trimmedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mail = (trimmedEmail?.isEmpty ?? true) ? nil : trimmedEmail
        let name = CalendarAttendee.sanitizedDisplayName(displayName)
        if mail == nil, name == nil { return nil }
        return CalendarAttendee(
            email: mail,
            displayName: name,
            isSelf: isSelf,
            isOrganizer: isOrganizer,
            isResource: isResource,
            isGroup: isGroup,
            status: status,
        )
    }
}
