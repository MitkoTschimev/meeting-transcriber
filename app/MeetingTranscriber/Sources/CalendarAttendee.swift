import Foundation

/// RSVP for a calendar attendee. Apple EventKit and Google Calendar both map
/// into this so picker filtering does not depend on either SDK.
enum CalendarAttendeeStatus: String, Codable, Sendable {
    case accepted
    case declined
    case tentative
    // swiftlint:disable:next raw_value_for_camel_cased_codable_enum
    case needsAction
    case unknown
}

/// One person (or resource) on a calendar event, from EventKit or Google.
struct CalendarAttendee: Equatable, Identifiable, Sendable, Codable {
    let email: String?
    let displayName: String?
    let isSelf: Bool
    let isOrganizer: Bool
    let isResource: Bool
    let status: CalendarAttendeeStatus

    var id: String {
        let mail = email?.lowercased() ?? ""
        let name = displayName?.lowercased() ?? ""
        return "\(mail)|\(name)"
    }

    var isDeclined: Bool {
        status == .declined
    }

    /// Name shown in speaker-naming menus: display name, else the email
    /// local-part (`alice@corp.com` → `alice`). Empty when neither exists.
    var pickerName: String {
        let named = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !named.isEmpty { return named }
        return Self.localPart(of: email ?? "")
    }

    init(
        email: String? = nil,
        displayName: String? = nil,
        isSelf: Bool = false,
        isOrganizer: Bool = false,
        isResource: Bool = false,
        status: CalendarAttendeeStatus = .unknown,
    ) {
        self.email = email
        self.displayName = displayName
        self.isSelf = isSelf
        self.isOrganizer = isOrganizer
        self.isResource = isResource
        self.status = status
    }

    static func localPart(of email: String) -> String {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let at = trimmed.firstIndex(of: "@") ?? trimmed.endIndex
        return String(trimmed[..<at])
    }

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
}

/// Builds the pickable name list from calendar attendees: skip resources and
/// the current user, put declined last, de-dupe case-insensitively.
enum CalendarAttendeePicker {
    static func names(from attendees: [CalendarAttendee]) -> [String] {
        let eligible = attendees.filter { attendee in
            !attendee.isResource && !attendee.isSelf && !attendee.pickerName.isEmpty
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
            let name = item.element.pickerName
            guard seen.insert(name.lowercased()).inserted else { continue }
            names.append(name)
        }
        return names
    }

    /// Teams AX names first, then calendar picker names not already present.
    static func merge(teams: [String], attendees: [CalendarAttendee]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for name in teams + names(from: attendees) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
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
    ) -> CalendarAttendee? {
        make(
            email: CalendarAttendee.email(fromMailto: url),
            displayName: name,
            isSelf: isCurrentUser,
            isOrganizer: isOrganizer,
            isResource: isResource,
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
    ) -> CalendarAttendee? {
        make(
            email: email,
            displayName: displayName,
            isSelf: isSelf,
            isOrganizer: isOrganizer,
            isResource: isResource,
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

    // swiftlint:disable:next function_parameter_count
    private static func make(
        email: String?,
        displayName: String?,
        isSelf: Bool,
        isOrganizer: Bool,
        isResource: Bool,
        status: CalendarAttendeeStatus,
    ) -> CalendarAttendee? {
        let trimmedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mail = (trimmedEmail?.isEmpty ?? true) ? nil : trimmedEmail
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (trimmedName?.isEmpty ?? true) ? nil : trimmedName
        if mail == nil, name == nil { return nil }
        return CalendarAttendee(
            email: mail,
            displayName: name,
            isSelf: isSelf,
            isOrganizer: isOrganizer,
            isResource: isResource,
            status: status,
        )
    }
}
