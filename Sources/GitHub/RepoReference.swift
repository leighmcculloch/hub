import Foundation

/// Interpreting whatever the user typed or pasted into the "owner/repo" field.
///
/// The field only ever asked for `owner/repo`, but the obvious thing to do with
/// it is paste a GitHub URL from the browser. That used to be accepted as-is —
/// it contains a slash — and became a clone path of
/// `https://github.int.exe.xyz/https://github.com/owner/repo.git`, which fails.
enum RepoReference {
    /// `owner/repo`, or nil when the text isn't a repository reference.
    static func normalize(_ text: String) -> String? {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }

        // A recognisable prefix means the rest is a URL path, so trailing
        // segments — /tree/main, /pull/12 — are part of a deep link and can be
        // dropped. Without one, the text is taken literally and must already be
        // exactly owner/repo; trimming a third component there would be
        // guessing at what the user meant.
        let hadPrefix = stripPrefix(&rest)

        if rest.hasSuffix("/") { rest.removeLast() }
        if rest.hasSuffix(".git") { rest.removeLast(".git".count) }

        let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard hadPrefix || parts.count == 2 else { return nil }
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    /// True when a scheme, SSH form, or bare host was found and removed.
    private static func stripPrefix(_ text: inout String) -> Bool {
        for scheme in ["https://", "http://", "ssh://", "git://"] where text.hasPrefix(scheme) {
            text.removeFirst(scheme.count)
            // The host is now the first path component.
            if let slash = text.firstIndex(of: "/") {
                text = String(text[text.index(after: slash)...])
            } else {
                text = ""
            }
            return true
        }
        // git@github.com:owner/repo.git
        if let at = text.firstIndex(of: "@"), let colon = text.firstIndex(of: ":"),
           at < colon, !text.contains("/") || text.firstIndex(of: "/")! > colon {
            text = String(text[text.index(after: colon)...])
            return true
        }
        for host in ["github.com/", "www.github.com/"] where text.hasPrefix(host) {
            text.removeFirst(host.count)
            return true
        }
        return false
    }
}
