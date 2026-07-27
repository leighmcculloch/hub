import Foundation

/// Turning a server response body into something that fits in a UI label.
///
/// Both API clients need this: bodies arrive as multi-line JSON or, when an
/// intermediary fails, a whole HTML error page, and the result is held in view
/// state and shown in an alert or a one-line banner.
enum MessageText {
    static let defaultLimit = 200

    /// One line, trimmed, and no longer than `limit`.
    static func condense(_ text: String, limit: Int = defaultLimit) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return "(empty response)" }
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }

    /// Bodies are usually UTF-8, but a failing intermediary can return anything;
    /// a lossy decode still says more than nothing.
    static func condense(_ body: Data, limit: Int = defaultLimit) -> String {
        condense(String(data: body, encoding: .utf8) ?? String(decoding: body, as: UTF8.self),
                 limit: limit)
    }

    /// Names the one thing a user can do about an auth failure. A bad token
    /// otherwise surfaces as a bare API string with no hint where to fix it.
    static func tokenHint(for status: Int, setting: String) -> String {
        (status == 401 || status == 403) ? " — check \(setting)." : ""
    }
}
