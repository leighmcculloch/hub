import Foundation

/// The files a run of commits changed, with their line counts: the file list of
/// a commit scope in the diff sidebar. The worktree scope's equivalent already
/// exists as the `changes`/`stats` half of `GitRepoStatus`.
struct GitScopeFiles: Equatable {
    var changes: [GitFileChange] = []
    /// Keyed by path. Files whose counts git reports as `-` (binary) get a
    /// `GitLineStat` with nil counts.
    var stats: [String: GitLineStat] = [:]

    /// Separates the `--name-status` half from the `--numstat` half in the
    /// combined output, the same trick `GitRepoStatus.separator` plays for the
    /// worktree status.
    static let separator = "---exe-scope-numstat---"

    /// The command both the local and the remote side run for a commit range:
    /// name-status, separator, numstat. Renames are off so every reported path
    /// is one that exists — with detection on, a rename arrives as
    /// `R100\told\tnew` and the rows stop lining up with real files, the same
    /// reason the worktree status disables them.
    static func command(git: String, from: String, to: String) -> String {
        "\(git) diff --name-status \(from) \(to) 2>/dev/null;"
            + " echo '\(separator)';"
            + " \(git) diff --numstat \(from) \(to) 2>/dev/null"
    }

    /// Parses `--name-status`, the separator, then `--numstat`. Either half may
    /// be empty: a range that touches no files (or an unresolvable one, where
    /// git printed nothing) still yields a valid, empty result.
    static func parse(_ output: String) -> GitScopeFiles {
        let sections = output.components(separatedBy: separator)
        var result = GitScopeFiles()

        for line in (sections.first ?? "").split(separator: "\n", omittingEmptySubsequences: true) {
            // "<letter>\t<path>". Rename lines ("R100\told\tnew") shouldn't
            // appear with renames off; if one slips through, the score is
            // dropped and the letter read alone, so the row stays readable.
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2, let letter = fields[0].first else { continue }
            let path = GitRepoStatus.unquotePath(String(fields[1]))
            // `GitFileChange.status` is a two-character porcelain code; a
            // name-status letter occupies the index slot.
            result.changes.append(GitFileChange(status: "\(letter) ", path: path))
        }

        guard sections.count > 1 else { return result }
        for line in sections[1].split(separator: "\n", omittingEmptySubsequences: true) {
            // "<added>\t<removed>\t<path>", with "-" counts for binary files.
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            result.stats[String(fields[2])] = GitLineStat(
                added: Int(fields[0]), removed: Int(fields[1]))
        }
        return result
    }
}
