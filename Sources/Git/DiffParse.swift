import Foundation

struct DiffRow: Identifiable {
    enum Kind { case file, hunk, addition, deletion, context, meta }

    let id: Int
    let kind: Kind
    /// The line's number in the new file (additions, context) or the old file
    /// (deletions). A single column leaves room for code in a narrow sidebar.
    let number: Int?
    let text: String
    /// The function/context suffix git puts after a hunk header, if any.
    let detail: String?
}

/// A unified diff broken into displayable rows, plus the totals the pane header
/// shows. Parsed once per distinct diff text rather than on every redraw.
struct ParsedDiff {
    var rows: [DiffRow] = []
    var additions = 0
    var deletions = 0
    /// Gutter width sized to the widest line number in this diff.
    var gutterWidth: CGFloat = 18

    static func parse(_ diff: String, includeFileHeaders: Bool) -> ParsedDiff {
        var parsed = ParsedDiff()
        var lines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last?.isEmpty == true { lines.removeLast() } // trailing newline

        var oldNumber = 0
        var newNumber = 0
        var widest = 0
        // Once a hunk starts, every line is content and is classified by its
        // first character alone. Outside a hunk the same text is a header.
        // Without this, deleting a line that begins with "-- " — a SQL comment,
        // a signature delimiter — arrives as "--- …", gets taken for a file
        // header, and vanishes from both the pane and the deletion count.
        var inHunk = false

        for line in lines {
            let id = parsed.rows.count
            if line.hasPrefix("diff --git ") {
                oldNumber = 0
                newNumber = 0
                inHunk = false
                // For a single-file diff the pane header already names the file.
                if includeFileHeaders {
                    parsed.rows.append(DiffRow(
                        id: id, kind: .file, number: nil, text: path(fromHeader: line), detail: nil))
                }
            } else if line.hasPrefix("@@") {
                // Always a real header: content lines always carry a "+", "-"
                // or " " prefix, so a bare "@@" can only start a hunk.
                inHunk = true
                let header = splitHunkHeader(line)
                if let starts = hunkStarts(header.range) {
                    oldNumber = starts.old
                    newNumber = starts.new
                }
                parsed.rows.append(DiffRow(
                    id: id, kind: .hunk, number: nil, text: header.range, detail: header.context))
            } else if !inHunk,
                      line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                continue // Blob hashes and a/ b/ paths add nothing to read.
            } else if line.hasPrefix("+") {
                parsed.rows.append(DiffRow(
                    id: id, kind: .addition, number: newNumber, text: display(line.dropFirst()), detail: nil))
                parsed.additions += 1
                widest = max(widest, newNumber)
                newNumber += 1
            } else if line.hasPrefix("-") {
                parsed.rows.append(DiffRow(
                    id: id, kind: .deletion, number: oldNumber, text: display(line.dropFirst()), detail: nil))
                parsed.deletions += 1
                widest = max(widest, oldNumber)
                oldNumber += 1
            } else if line.hasPrefix(" ") || line.isEmpty {
                parsed.rows.append(DiffRow(
                    id: id, kind: .context, number: newNumber, text: display(line.dropFirst()), detail: nil))
                widest = max(widest, newNumber)
                oldNumber += 1
                newNumber += 1
            } else {
                // "new file mode", "Binary files … differ", "\ No newline …".
                parsed.rows.append(DiffRow(id: id, kind: .meta, number: nil, text: line, detail: nil))
            }
        }

        // Monospaced digits are ~6pt wide at 10pt; pad so the column isn't tight.
        parsed.gutterWidth = CGFloat(max(2, String(widest).count)) * 6.5 + 4
        return parsed
    }

    /// "diff --git a/x b/x" → "x" (the post-rename path).
    private static func path(fromHeader line: String) -> String {
        if let separator = line.range(of: " b/") {
            return String(line[separator.upperBound...])
        }
        return String(line.dropFirst("diff --git ".count))
    }

    /// Splits "@@ -1,7 +1,9 @@ func foo()" into the range and its trailing
    /// context, which is usually the enclosing function — worth showing.
    private static func splitHunkHeader(_ line: String) -> (range: String, context: String?) {
        let afterMarker = line.index(line.startIndex, offsetBy: 2)
        guard let close = line.range(of: "@@", options: [], range: afterMarker..<line.endIndex) else {
            return (line, nil)
        }
        let range = String(line[line.startIndex..<close.upperBound])
        let context = line[close.upperBound...].trimmingCharacters(in: .whitespaces)
        return (range, context.isEmpty ? nil : context)
    }

    /// First line number on each side of "@@ -12,7 +14,9 @@".
    private static func hunkStarts(_ range: String) -> (old: Int, new: Int)? {
        let tokens = range.split(separator: " ")
        guard tokens.count >= 3,
              let old = start(ofToken: tokens[1]),
              let new = start(ofToken: tokens[2])
        else { return nil }
        return (old, new)
    }

    /// "-12,7" → 12.
    private static func start(ofToken token: Substring) -> Int? {
        guard let digits = token.dropFirst().split(separator: ",").first else { return nil }
        return Int(digits)
    }

    /// Tabs render at unpredictable widths in `Text`, so expand them to keep the
    /// monospaced grid honest; CRs from Windows files would show as boxes.
    private static func display(_ text: Substring) -> String {
        String(text)
            .replacingOccurrences(of: "\t", with: "    ")
            .replacingOccurrences(of: "\r", with: "")
    }
}
