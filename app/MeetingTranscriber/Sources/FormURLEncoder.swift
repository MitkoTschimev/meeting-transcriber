import Foundation

/// `application/x-www-form-urlencoded` encoding for OAuth token requests.
///
/// `CharacterSet.urlQueryAllowed` leaves `+`, `&`, and `=` unescaped, which
/// splits fields and turns `+` into a space on the server. RFC 3986 unreserved
/// characters are the safe set here.
enum FormURLEncoder {
    static func encode(_ fields: [String: String]) -> Data {
        Data(encodeString(fields).utf8)
    }

    static func encodeString(_ fields: [String: String]) -> String {
        fields.keys.sorted().map { key in
            "\(escape(key))=\(escape(fields[key] ?? ""))"
        }
        .joined(separator: "&")
    }

    static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
